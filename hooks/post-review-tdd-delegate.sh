#!/bin/bash
# postToolUse hook fired when the `subagent` tool completes (Kiro). Filters by
# tolerantly scanning tool_input strings for "zensu-code-reviewer" (Kiro names
# the spawned agent inside tool_input; the exact field is host-version specific,
# unlike Claude's tool_input.subagent_type) and routes findings back to the MAIN
# agent (which runs the /zensu-tdd workflow in-thread) via additionalContext
# (kiro-shim.sh unwraps it to plain stdout). On PASS / suggestions-only the main
# agent closes the chain with `zensu-log.sh --chain-done`; on max-rounds this
# hook sets chainDone itself so the Stop-hook backstop releases.
#
# Behavior is configurable via ~/.zensu/config.json (resolution order: env,
# project-local, global):
#   hooks.autoFixIncludeSuggestions=true  -> route ALL severities
#   hooks.autoFixIncludeSuggestions=false -> route Critical+Important only (default, backward-compat)
#   hooks.autoFixMaxRounds=<int 1..99>    -> loop guard (default 5)
#
# Counter state lives at ${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}/rounds-<session_id>.json. claude-code's auto-set CLAUDE_PLUGIN_DATA is intentionally IGNORED (use CLAUDE_PLUGIN_DATA_OVERRIDE to relocate).

set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled autoFix || exit 0

INPUT="$(cat)"

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$INPUT" 2>/dev/null || true

# Tolerant reviewer match: walk every string in tool_input and look for the
# reviewer agent name in either naming scheme (Kiro "zensu-code-reviewer",
# Claude "zensu:code-reviewer"). Prints "yes"/"no".
IS_REVIEWER="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const strs = [];
      (function walk(v){
        if (typeof v === "string") strs.push(v);
        else if (Array.isArray(v)) v.forEach(walk);
        else if (v && typeof v === "object") Object.values(v).forEach(walk);
      })(j.tool_input);
      const hit = strs.some(x => /zensu[-:]code[-_]?reviewer/i.test(x));
      console.log(hit ? "yes" : "no");
    } catch (_) { console.log("no"); }
  });
' <<<"$INPUT" 2>/dev/null)"

if [ "$IS_REVIEWER" != "yes" ]; then
  exit 0
fi

SESSION_ID="$(node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    try {
      const j = JSON.parse(s);
      const id = j.session_id;
      console.log((typeof id === "string" && id) ? id : "");
    } catch (_) { console.log(""); }
  });
' <<<"$INPUT" 2>/dev/null)"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"

MAX_ROUNDS="$(zensu_autofix_max_rounds)"
STATE_DIR="${CLAUDE_PLUGIN_DATA_OVERRIDE:-${CLAUDE_PROJECT_DIR:-.}/.zensu/state}"
mkdir -p "$STATE_DIR" 2>/dev/null || true
COUNTER_FILE="$STATE_DIR/rounds-${SESSION_ID}.json"
if [ -L "$COUNTER_FILE" ]; then
  echo "zensu post-review hook: refusing to write through symlink at $COUNTER_FILE — counter NOT updated" >&2
  exit 0
fi
if [ -L "$STATE_DIR" ]; then
  echo "zensu post-review hook: refusing to write under symlinked state dir $STATE_DIR — counter NOT updated" >&2
  exit 0
fi

CURRENT="$(node -e '
  try {
    const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    const n = j && j.count;
    console.log(Number.isInteger(n) && n >= 0 ? String(n) : "0");
  } catch (_) { console.log("0"); }
' "$COUNTER_FILE" 2>/dev/null)"
case "$CURRENT" in
  ''|*[!0-9]*) CURRENT=0 ;;
esac
NEXT=$((CURRENT + 1))

if [ "$(_zensu_log_style)" = "none" ]; then
  PAYLOAD="$(printf '{"count":%d}' "$NEXT")"
else
  PAYLOAD="$(printf '{"count":%d,"ts":"%s"}' "$NEXT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
fi
if TMP_FILE="$(mktemp "${STATE_DIR}/rounds-${SESSION_ID}.XXXXXX" 2>/dev/null)"; then
  if printf '%s\n' "$PAYLOAD" > "$TMP_FILE" \
     && mv "$TMP_FILE" "$COUNTER_FILE" 2>/dev/null; then
    :
  else
    rm -f "$TMP_FILE" 2>/dev/null
    echo "zensu post-review hook: failed to persist counter for session ${SESSION_ID} (write/mv)" >&2
    if ! printf '%s\n' "$PAYLOAD" > "$COUNTER_FILE" 2>/dev/null; then
      echo "zensu post-review hook: fallback direct write also failed; counter NOT updated" >&2
    fi
  fi
else
  echo "zensu post-review hook: mktemp failed under ${STATE_DIR} for session ${SESSION_ID}" >&2
  if ! printf '%s\n' "$PAYLOAD" > "$COUNTER_FILE" 2>/dev/null; then
    echo "zensu post-review hook: fallback direct write also failed; counter NOT updated" >&2
  fi
fi

COMBINED_SUMMARY_DIRECTIVE=""
if zensu_combined_summary_enabled; then
  COMBINED_SUMMARY_DIRECTIVE=$'\n\nAfter your status line, produce a CHAIN-END SUMMARY in narrative form with these sections IN THIS ORDER (pull data from your own main-thread TDD execution and the prior zensu-code-reviewer Agent results in your context, do NOT re-spawn agents). The TL;DR comes LAST:\n\n## Problem\nIn plain words: the feature, bug, or need this session addressed — why the work happened.\n\n## What I built\nNumbered deliverables. For each: what it does in plain words, its status (done / merged / built-tested), and a PR link if one exists. Carry the audit facts here: feature title, files modified, tests created, build status (passed / skipped / failed), mtime audit verdict, coverage status. Cite the plan + log file paths.\n\n## How I built it\nThe method and the review trail. State the TDD discipline followed, then the final zensu-code-reviewer verdict (PASS / PASS with suggestions / max-rounds reached) with findings count by severity and files reviewed. Then the auto-fix history: list EVERY review round 1..N — including rounds that fixed nothing. For each round give the round number and either the findings fixed in-thread (what changed, what remains), OR — for a verification round with no findings — mark it explicitly as PASS — 0 findings, nothing to fix. Always include the final clean verification round so the reader sees the chain converged with every finding addressed. At least one review round always ran.\n\n## Open\nWhat is left: any deferred suggestions (the buffered ### Suggestions block) or max-rounds findings requiring manual fix, plus the next step. If nothing is open, say so in one line.\n\n## TL;DR\nExactly ONE sentence, and it MUST be the last section: what shipped and the test verdict.'
fi

# When the self-review terminal stage is enabled, the code-reviewer chain hands
# off to /zensu-self-review (a main-thread Skill) instead of closing here:
# self-review owns the chain terminus (--chain-done) and renders the report.
SELF_REVIEW_ON=0
if zensu_hook_enabled selfReview; then SELF_REVIEW_ON=1; fi

if [ "$SELF_REVIEW_ON" = "1" ]; then
  CLOSE_PASS="run 'bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --code-review-done' (PLUGIN_ROOT = contents of ~/.zensu/plugin-root, the value you resolved in Phase 0), then your VERY NEXT action must be to invoke the /zensu-self-review skill — the terminal self-review stage that owns the chain terminus and renders the final CHAIN-END SUMMARY. Do NOT close the chain yourself, do NOT render the summary here, and do NOT end your turn — self-review finalizes the chain."
  TAIL_DIRECTIVE=""
else
  CLOSE_PASS="close the review chain by running 'bash {PLUGIN_ROOT}/hooks/lib/zensu-log.sh --chain-done' (PLUGIN_ROOT = contents of ~/.zensu/plugin-root, the value you resolved in Phase 0), then stop."
  TAIL_DIRECTIVE="${COMBINED_SUMMARY_DIRECTIVE}"
fi

if [ "$NEXT" -gt "$MAX_ROUNDS" ]; then
  # Max rounds reached. With self-review enabled the chain does NOT terminate
  # here: mark the code-reviewer chain converged (codeReviewDone) and hand off to
  # the terminal self-review stage, which owns --chain-done. With self-review
  # disabled, terminate as before (chainDone) so the Stop-hook backstop releases.
  if [ "$SELF_REVIEW_ON" = "1" ]; then
    bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --code-review-done --session "$SESSION_ID" >/dev/null 2>&1 || true
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The code-reviewer chain is marked converged (codeReviewDone). Do NOT spawn zensu-code-reviewer again and do NOT keep fixing its findings. Your VERY NEXT action MUST be to invoke the /zensu-self-review skill — the terminal self-review stage. Carry the remaining reviewer findings forward for it under '### Findings (max rounds reached, manual fix required)' so they land in the final report. /zensu-self-review owns the chain terminus and renders the final summary — do NOT close the chain yourself. To grant another reviewer budget instead of finalizing, the user can invoke the /zensu-reset-review-limit skill."
  else
    bash "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-log.sh" --chain-done --session "$SESSION_ID" >/dev/null 2>&1 || true
    CONV_MSG="Auto-fix convergence: max ${MAX_ROUNDS} rounds reached. The review chain is now marked complete (chainDone) so you MAY end your turn. Do NOT spawn zensu-code-reviewer again and do NOT keep fixing. Reply with the remaining findings under '### Findings (max rounds reached, manual fix required)' and stop. To grant another budget and resume the review/fix cycle in this same session, the user can invoke the /zensu-reset-review-limit skill — surface this hint at the end of your reply so the user knows the escape hatch exists.${COMBINED_SUMMARY_DIRECTIVE}"
  fi
  node -e '
    const msg = process.argv[1];
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: msg
      }
    }));
  ' "$CONV_MSG"
  echo
  exit 0
fi

if zensu_autofix_include_suggestions; then
  MSG="STOP. The zensu-code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ANY findings present (any of Critical, Important, Suggestion, Minor, Nit) — fix them YOURSELF IN THIS MAIN THREAD under strict TDD discipline by re-entering the /zensu-tdd workflow (for each finding: write or adjust a RED test, then IMPL, then GREEN; the preToolUse phase-gate is still active in this session). Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nInclude EVERY finding the reviewer raised — Critical, Important, Suggestion, Minor, Nit — without filtering. After the fixes are GREEN, your VERY NEXT action must be the subagent tool with agent 'zensu-code-reviewer' to re-verify — the Stop-hook backstop enforces this, so do NOT end your turn first. Do NOT mark the chain done in case B. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing all findings in-thread, then re-reviewing (round ${NEXT}/${MAX_ROUNDS})' (case B) | 'No fixes needed: review passed' (case A).${TAIL_DIRECTIVE}"
else
  MSG="STOP. The zensu-code-reviewer subagent above just finished. Classify its findings by severity, then act:\n\n(A) Verdict PASS / zero findings — reply 'No fixes needed: review passed', then ${CLOSE_PASS}\n\n(B) ONLY Suggestions / Minor / Nits (no Critical AND no Important) — do NOT fix. Reply with a status line 'No critical/important findings — suggestions only' followed by the bullet list of Suggestions verbatim under the heading '### Suggestions (not auto-fixed)' so they land in the final report, then ${CLOSE_PASS}\n\n(C) ANY Critical OR Important findings present — fix them YOURSELF IN THIS MAIN THREAD under strict TDD discipline by re-entering the /zensu-tdd workflow (for each finding: RED test, then IMPL, then GREEN; the preToolUse phase-gate is still active in this session). Treat the findings as a feature spec shaped exactly like:\n\nFix the following findings from code review:\n1. <file:line> — <issue description>\n   Fix: <reviewer's fix suggestion>\n2. <file:line> — ...\n   Fix: ...\n\nList ONLY Critical and Important findings. EXCLUDE all Suggestions / Minor / Nits — those are NOT auto-fixed; buffer them in your response under '### Suggestions (deferred, not auto-fixed)' below the status line so the user sees them at the end of the chain. After the fixes are GREEN, your VERY NEXT action must be the subagent tool with agent 'zensu-code-reviewer' to re-verify — the Stop-hook backstop enforces this, so do NOT end your turn first. Do NOT mark the chain done in case C. Do NOT spawn a tdd subagent — TDD now runs in this main thread.\n\nBegin your next message with one of these status lines: 'Fixing critical+important findings in-thread, then re-reviewing' (case C) | 'No critical/important findings — suggestions only' (case B) | 'No fixes needed: review passed' (case A).${TAIL_DIRECTIVE}"
fi

EXPANDED_MSG="${MSG//\$\{NEXT\}/$NEXT}"
EXPANDED_MSG="${EXPANDED_MSG//\$\{MAX_ROUNDS\}/$MAX_ROUNDS}"

node -e '
  const msg = process.argv[1];
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: msg
    }
  }));
' "$EXPANDED_MSG"
echo
