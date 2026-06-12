#!/bin/bash
# NOT WIRED ON KIRO — kept for upstream comparison only. Kiro has no
# plan-approval event (Claude Code's ExitPlanMode PostToolUse does not exist
# here), so this hook is not registered in agents/cli/zensu.json and install.sh
# deliberately does not ship it to the runtime home. Its job — asking the user
# whether to run the strict TDD flow when a plan turns into code — is covered
# on Kiro by the per-turn userPromptSubmit reminder (user-prompt-tdd-reminder.sh)
# plus steering/zensu-conventions.md (see README fidelity matrix: DEGRADED by
# design). The body below is the upstream Claude Code implementation, with the
# German user-utterance match literals stripped (this repo's English-only guard
# exempts only user-prompt-tdd-reminder.sh) — both mode branches mirror that.

set -u

: "${CLAUDE_PLUGIN_ROOT:=$(cd "$(dirname "$0")/.." && pwd)}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled autoTdd || exit 0

if zensu_hook_enabled tddImplementation; then
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The plan above was just approved by the user. Do NOT implement anything yet — first determine whether to run the strict TDD flow for this plan, and in most cases ASK the user. Fast-paths that need NO question: (A) the plan only modifies non-executable text — Markdown docs (README, CHANGELOG, *.md), code comments, plain prose, or static config files with no runtime logic — proceed directly without TDD and begin your next message with 'Skipping TDD: docs only'. README/CHANGELOG edits are ALWAYS in this category, even when adding markers, sections, or restructuring. (B) the user's approval message already states an EXPLICIT TDD preference — either a negation matching 'no tdd', 'skip tdd', 'no tdd-manager', \"don't use tdd\", 'direct edit' (then skip TDD, implement directly, begin with 'Skipping TDD: user opted out'), or an affirmation matching 'use tdd', 'with tdd', 'tdd please' (then run TDD without asking). (C) you are running non-interactively with no human to answer (Auto Mode / headless) — default to running TDD and do NOT ask. In EVERY OTHER case — the plan adds or modifies executable code (functions, classes, methods, types, conditionals, loops, exports, imports, JSX/TSX components, React hooks, styles that affect rendered output, schema/config files that drive runtime behavior) and the user stated no preference — your VERY NEXT TOOL CALL must be the AskUserQuestion tool: ask a single question such as 'Run the strict TDD flow (RED→GREEN + review chain) for this plan?' with options 'Yes — TDD flow' and 'No — implement directly'. Do NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that AskUserQuestion call. Then act on the answer YOURSELF in THIS main thread (never a subagent): if the user chooses Yes (or fast-path B-affirmation, or fast-path C) → your next tool call is the Skill tool with skill='zensu:tdd', passing the approved plan content (the markdown that appeared in the ExitPlanMode tool_input) as the feature specification — you execute strict RED→IMPL→GREEN TDD under the PreToolUse phase-gate and the auto-review chain — and you begin that message with the status line 'Executing via /zensu:tdd'. If the user chooses No → implement the plan directly in this main thread; the TDD phase-gate stays inactive (never run --tdd-begin) so your edits flow freely; begin that message with 'Skipping TDD: user declined'. Generic action phrases ('go ahead', 'start now', 'implement', 'immediately', 'go') are NOT a TDD preference — ask anyway. If uncertain whether the plan adds executable code, ask."
  }
}
JSON
else
cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "STOP. The plan above was just approved by the user. Vanilla implementation mode is configured (hooks.tddImplementation=false): the /zensu:tdd workflow implements WITHOUT the RED→GREEN ceremony (tests at your discretion) but keeps the full evidence discipline and review chain (Phase 5/6 audits, 5-aspect fan-out, code-reviewer, self-review, Stop-hook guarantee). Do NOT implement anything yet — first determine whether to run the Zensu workflow for this plan, and in most cases ASK the user. Fast-paths that need NO question: (A) the plan only modifies non-executable text — Markdown docs (README, CHANGELOG, *.md), code comments, plain prose, or static config files with no runtime logic — proceed directly without the workflow and begin your next message with 'Skipping TDD: docs only'. README/CHANGELOG edits are ALWAYS in this category, even when adding markers, sections, or restructuring. (B) the user's approval message already states an EXPLICIT preference — either a negation matching 'no tdd', 'skip tdd', 'no tdd-manager', \"don't use tdd\", 'direct edit' (then skip the workflow, implement directly, begin with 'Skipping TDD: user opted out'), or an affirmation matching 'use tdd', 'with tdd', 'tdd please' (then run the workflow without asking). (C) you are running non-interactively with no human to answer (Auto Mode / headless) — default to running the workflow and do NOT ask. In EVERY OTHER case — the plan adds or modifies executable code (functions, classes, methods, types, conditionals, loops, exports, imports, JSX/TSX components, React hooks, styles that affect rendered output, schema/config files that drive runtime behavior) and the user stated no preference — your VERY NEXT TOOL CALL must be the AskUserQuestion tool: ask a single question such as 'Run the Zensu workflow (vanilla implementation + review chain) for this plan?' with options 'Yes — Zensu workflow' and 'No — implement directly'. Do NOT call Read, Edit, Write, Bash, MultiEdit, NotebookEdit, Glob, or Grep before that AskUserQuestion call. Then act on the answer YOURSELF in THIS main thread (never a subagent): if the user chooses Yes (or fast-path B-affirmation, or fast-path C) → your next tool call is the Skill tool with skill='zensu:tdd', passing the approved plan content (the markdown that appeared in the ExitPlanMode tool_input) as the feature specification — the skill detects vanilla mode itself at --tdd-begin and implements directly under the Phase 5/6 evidence discipline and the auto-review chain — and you begin that message with the status line 'Executing via /zensu:tdd (vanilla mode)'. If the user chooses No → implement the plan directly in this main thread; the phase-gate stays inactive (never run --tdd-begin) so your edits flow freely; begin that message with 'Skipping TDD: user declined'. Generic action phrases ('go ahead', 'start now', 'implement', 'immediately', 'go') are NOT a workflow preference — ask anyway. If uncertain whether the plan adds executable code, ask."
  }
}
JSON
fi
