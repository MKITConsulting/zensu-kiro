#!/bin/bash
# PreToolUse hook — the TDD phase-gate. Deterministically allows/denies file
# edits based on the per-session TDD FSM phase (RED_WRITE → RED_FAIL → IMPL →
# GREEN_PASS → REFACTOR) so production code cannot be written before a failing
# test exists. Emits the host's deny schema (hookSpecificOutput.permissionDecision
# = "deny") — identical on Codex and Claude Code. Two mode-independent layers
# run before the FSM rules: edit-tool writes touching the session-state files
# (.zensu/state/, normalized + realpath-resolved) are denied in BOTH modes, and
# a session frozen into vanilla mode (state-file `vanilla` flag, set at
# --tdd-begin) passes through the FSM entirely.
#
# Engine portability: matches the Kiro CLI write tool (`write` and its aliases
# `fs_write`/`fsWrite`, whose target is `tool_input.path`), the Codex edit tool
# (`apply_patch`, a freeform tool whose patch envelope names target files on
# `*** Update/Add/Delete File:` lines — a single patch may touch several files,
# and the gate denies the whole patch if ANY touched file violates the current
# phase) AND the Claude Code edit tools (`Edit`/`Write`/`MultiEdit`, whose
# target is `tool_input.file_path`). On Kiro the deny JSON is translated to
# exit 2 + stderr by hooks/kiro/kiro-shim.sh.
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"

PAYLOAD="$(cat)"

# The user-facing kill switch bypasses the gate BEFORE any node work — the
# documented total bypass must hold independent of node health.
if [ "${ZENSU_TDD_GATE:-}" = "off" ]; then
  exit 0
fi

if ! command -v node >/dev/null 2>&1; then
  exit 0
fi

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$PAYLOAD" 2>/dev/null || true

# Extract tool name, session id, and the list of edited file paths in one pass.
# - Edit/Write/MultiEdit: tool_input.file_path
# - apply_patch (freeform): scan every string in tool_input for the patch
#   envelope and pull each `*** Update/Add/Delete File:` (+ `*** Move to:`) path.
EXTRACT="$(printf '%s' "$PAYLOAD" | node -e '
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => { run(s); });
  function run(body) {
  try {
    const j = JSON.parse(body || "{}");
    const toolName = typeof j.tool_name === "string" ? j.tool_name : "";
    const sid = typeof j.session_id === "string" ? j.session_id : "";
    const ti = j.tool_input;
    const files = [];
    if (ti && typeof ti === "object" && typeof ti.file_path === "string" && ti.file_path) {
      files.push(ti.file_path);
    }
    if (ti && typeof ti === "object" && typeof ti.path === "string" && ti.path) {
      files.push(ti.path);
    }
    // The patch-envelope scan exists for the Codex apply_patch tool, whose
    // target files only appear inside the envelope text. Run it ONLY when the
    // tool is apply_patch or when no explicit path field was found — write
    // payloads may legitimately CONTAIN envelope-looking text in file_text
    // (fixtures, docs), and that content must not inject phantom paths.
    if (toolName === "apply_patch" || files.length === 0) {
      const strs = [];
      (function walk(v){
        if (typeof v === "string") strs.push(v);
        else if (Array.isArray(v)) v.forEach(walk);
        else if (v && typeof v === "object") Object.values(v).forEach(walk);
      })(ti);
      const patch = strs.find(s => s.indexOf("*** Begin Patch") !== -1) || strs.join("\n");
      let m;
      const reFile = /^\*\*\*\s+(?:Update|Add|Delete) File:\s+(.+?)\s*$/gm;
      while ((m = reFile.exec(patch)) !== null) files.push(m[1]);
      const reMove = /^\*\*\*\s+Move to:\s+(.+?)\s*$/gm;
      while ((m = reMove.exec(patch)) !== null) files.push(m[1]);
    }
    const uniq = [...new Set(files.filter(Boolean))];
    process.stdout.write(toolName + "\n" + sid + "\n" + uniq.join("\n"));
  } catch (_) { process.stdout.write("\n\n"); }
  }
' 2>/dev/null)"

TOOL_NAME="$(printf '%s' "$EXTRACT" | sed -n '1p')"
case "$TOOL_NAME" in
  Edit|Write|MultiEdit|apply_patch|write|fs_write|fsWrite) ;;
  *) exit 0 ;;
esac

SESSION_ID="$(printf '%s' "$EXTRACT" | sed -n '2p')"
source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-session.sh"
SESSION_ID="$(zensu_resolve_session_id "$SESSION_ID")"

# The edited paths are everything after line 2.
FILES="$(printf '%s' "$EXTRACT" | sed -n '3,$p')"

source "$CLAUDE_PLUGIN_ROOT/hooks/lib/zensu-tdd-phase.sh"

STATE_FILE=$(tdd_state_file "$SESSION_ID")

# Activation: the gate enforces only while a main-thread TDD session is active
# for THIS session (chain-state flag set by `zensu-log.sh --tdd-begin`). When no
# active chain-state exists the hook is a silent pass-through — normal editing,
# other subagents, and plain CLI are never gated.
if [ "$(tdd_session_active "$STATE_FILE")" != "true" ]; then
  exit 0
fi

if [ -z "$FILES" ]; then
  # No file could be determined (e.g. an apply_patch envelope we could not parse).
  # Cannot reason about the phase rule safely, so do not block.
  exit 0
fi

# Path classification on the NORMALIZED form (dot-segments, duplicate slashes,
# case folding, traversal, MSYS vs native Windows drive spellings, and the
# resolved TDD_STATE_DIR / rounds-counter overrides all collapse to the same
# class) so the state deny below cannot be evaded by an alternate spelling that
# the broader .zensu/ exemption would then allow. One node pass for ALL touched
# files, list streamed via stdin (execve-safe for large apply_patch envelopes);
# one class per line, same order as $FILES. The zensu (exempt) class is
# realpath-validated too — a symlink planted under .zensu/ that resolves
# outside loses the exemption.
SD="$(dirname "$STATE_FILE")"
SD2="$(dirname "$(zensu_rounds_counter_file "$SESSION_ID")")"
PD="${CLAUDE_PROJECT_DIR:-.}"
# MSYS/Git-Bash host (Windows): the shell auto-converts SOME POSIX-form paths
# (env values) to native form when spawning native node, while stdin content
# passes through untouched — the two sides of the prefix comparison would then
# never collapse to one spelling. Convert ALL inputs to mixed Windows form
# explicitly; on POSIX hosts cygpath does not exist and this is a no-op.
if command -v cygpath >/dev/null 2>&1; then
  FILES_CONV="$(printf '%s\n' "$FILES" | cygpath -m -f - 2>/dev/null)"
  [ -n "$FILES_CONV" ] && FILES="$FILES_CONV"
  SD="$(cygpath -m "$SD" 2>/dev/null || printf '%s' "$SD")"
  SD2="$(cygpath -m "$SD2" 2>/dev/null || printf '%s' "$SD2")"
  PD="$(cygpath -m "$PD" 2>/dev/null || printf '%s' "$PD")"
fi
CLASSES="$(printf '%s' "$FILES" | SD="$SD" SD2="$SD2" PD="$PD" node -e '
  const path = require("path");
  const fs = require("fs");
  const lownorm = p => path.posix.normalize(String(p).replace(/\\/g, "/").replace(/^\/([a-zA-Z])(\/|$)/, "$1:$2")).toLowerCase();
  const realdir = p => { try { return fs.realpathSync(p); } catch (_) { return path.resolve(p); } };
  const realfile = p => {
    try { return fs.realpathSync(p); }
    catch (_) { return path.join(realdir(path.dirname(p)), path.basename(p)); }
  };
  // Relative payload paths resolve against the PROJECT DIR (the base the edit
  // tools use), not the hook process cwd — a host may invoke hooks elsewhere.
  const base = process.env.PD || ".";
  let s = "";
  process.stdin.on("data", c => s += c);
  process.stdin.on("end", () => {
    const stateDirs = [process.env.SD, process.env.SD2].filter(Boolean)
      .map(d => lownorm(realdir(path.resolve(base, d))) + "/");
    const out = s.split("\n").filter(Boolean).map(fpRaw => {
      const f = lownorm(fpRaw);
      const fAbs = lownorm(realfile(path.resolve(base, fpRaw)));
      if (f.indexOf("/.zensu/state/") >= 0 || f.indexOf(".zensu/state/") === 0
          || stateDirs.some(d => fAbs.indexOf(d) === 0 || f.indexOf(d) === 0)) return "state";
      if ((f.indexOf("/.zensu/") >= 0 || f.indexOf(".zensu/") === 0)
          && fAbs.indexOf("/.zensu/") >= 0) return "zensu";
      return "other";
    });
    process.stdout.write(out.join("\n"));
  });
' 2>/dev/null)"

# Degraded-classification guard: if the node pass died or truncated (its stderr
# is discarded), the state deny would silently fail OPEN while the .zensu/
# exemption failed CLOSED. Refuse to guess: deny the whole call with an explicit
# reason instead of mis-classifying.
FILES_N="$(printf '%s\n' "$FILES" | grep -c .)"
CLASSES_N="$(printf '%s\n' "$CLASSES" | grep -c .)"
if [ "$FILES_N" -ne "$CLASSES_N" ]; then
  # Static literal on purpose: this branch fires when the node pass died, so
  # the deny must not depend on node itself (kiro-shim fails open on non-JSON).
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision": "deny","permissionDecisionReason":"TDD-Phase-Gate: path classification unavailable (internal node pass failed) — refusing to evaluate this edit against the session-state protection. Retry the edit; if this persists, set ZENSU_TDD_GATE=off with user approval."}}'
  exit 0
fi

# Session-state hardening: while a session is active, EDIT-TOOL writes touching
# the session-state files are denied in BOTH modes — flipping `vanilla`/`active`
# there would silently un-gate the session for this tool class. State writes go
# through zensu-log.sh via the shell tool, which this hook never mediates (the
# documented in-moment trust boundary). Checked BEFORE the vanilla bypass and
# the .zensu/ exemption on purpose; a multi-file patch is denied as a whole if
# ANY touched file is state-class.
if printf '%s\n' "$CLASSES" | grep -qx "state"; then
  # Static literal on purpose (like the classification guard above): this deny
  # is a hardening control and must not depend on a node spawn succeeding.
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision": "deny","permissionDecisionReason":"TDD-Phase-Gate: edit-tool writes to the session-state files (.zensu/state/) are blocked while a session is active — state flags change only through bash \"$(cat ~/.zensu/plugin-root)\"/hooks/lib/zensu-log.sh (e.g. --tdd-begin, --tdd-reset, --phase)."}}'
  exit 0
fi

# Vanilla implementation mode: the per-session `vanilla` flag was frozen into
# the state file by `--tdd-begin` (hooks.tddImplementation=false at begin time).
# The gate reads ONLY the state flag — never live config — so a mid-session
# config flip can neither un-gate a strict session nor wedge a vanilla one.
if [ "$(tdd_vanilla_mode "$STATE_FILE")" = "true" ]; then
  exit 0
fi

PHASE=$(tdd_phase "$STATE_FILE")
STEP=$(tdd_step "$STATE_FILE")
RED_FAIL_FOR_STEP=$(tdd_has_red_fail "$STATE_FILE" "$STEP")

decide_allow_file() {
  local is_test="$1"
  case "$PHASE" in
    RED_WRITE) return 0 ;;
    RED_FAIL)
      [ "$is_test" = "true" ] && return 0
      return 1
      ;;
    IMPL)
      [ "$RED_FAIL_FOR_STEP" = "true" ] && return 0
      return 1
      ;;
    GREEN_PASS)
      [ "$is_test" = "true" ] && return 0
      return 1
      ;;
    REFACTOR) return 0 ;;
    UNINITIALIZED) return 1 ;;
    *) return 1 ;;
  esac
}

# Evaluate every touched file. zensu-class paths (normalized .zensu/, minus the
# state dir denied above) are exempt; traversal spellings were normalized away
# by the classification, so '.zensu/../prod.c' classifies "other" and gates.
# Deny the whole patch if ANY file fails its phase rule (name the first such file).
DENIED_FILE=""
FILE_IDX=0
while IFS= read -r FILE_PATH; do
  [ -z "$FILE_PATH" ] && continue
  FILE_IDX=$((FILE_IDX + 1))
  CLASS="$(printf '%s\n' "$CLASSES" | sed -n "${FILE_IDX}p")"
  [ "$CLASS" = "zensu" ] && continue
  IS_TEST_PATH=$(tdd_is_test_path "$FILE_PATH")
  if ! decide_allow_file "$IS_TEST_PATH"; then
    DENIED_FILE="$FILE_PATH"
    break
  fi
done <<EOF
$FILES
EOF

if [ -z "$DENIED_FILE" ]; then
  exit 0
fi

# Node-built on purpose (unlike the two static hardening denies above): this
# deny's whole value is the phase/step/file interpolation, node proved alive
# twice in this run (extract + classification), and a node death here fails
# open only the discipline rule — the hardening denies stay static.
PAYLOAD_PHASE="$PHASE" PAYLOAD_STEP="$STEP" PAYLOAD_FILE="$DENIED_FILE" PAYLOAD_TOOL="$TOOL_NAME" PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT" node -e '
  const phase = process.env.PAYLOAD_PHASE || "UNINITIALIZED";
  const step  = process.env.PAYLOAD_STEP || "(none)";
  const file  = process.env.PAYLOAD_FILE || "(unknown)";
  const tool  = process.env.PAYLOAD_TOOL || "apply_patch";
  const root  = process.env.PLUGIN_ROOT || "";
  const header =
    "TDD-Phase-Gate: " + tool + " on " + file + " blocked.\n" +
    "Current phase: " + phase + ", step: " + step + ".\n" +
    "Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step " + step + ") | (GREEN_PASS only on test paths).\n";
  const reason = header +
    "Action:\n" +
    "  1. New test file: bash " + root + "/hooks/lib/zensu-log.sh --phase RED_WRITE --step <id>\n" +
    "  2. IMPL: first run the test, set RED_FAIL:\n" +
    "     bash " + root + "/hooks/lib/zensu-log.sh --phase RED_RUN --step <id>\n" +
    "     (run the test command)\n" +
    "     bash " + root + "/hooks/lib/zensu-log.sh --phase RED_FAIL --step <id> --reason \"...\"\n" +
    "     bash " + root + "/hooks/lib/zensu-log.sh --phase IMPL --step <id>\n" +
    "  3. Refactor: bash " + root + "/hooks/lib/zensu-log.sh --phase REFACTOR --step <id>\n" +
    "  4. Legitimate non-TDD edit: set ZENSU_TDD_GATE=off";
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason
    }
  }));
'
echo

if [ -n "${ZENSU_HOOK_LOG:-}" ]; then
  {
    echo "[hook: PreToolUse] TDD-Phase-Gate: $TOOL_NAME on $DENIED_FILE blocked."
    echo "[hook: PreToolUse] Current phase: $PHASE, step: $STEP."
    echo "[hook: PreToolUse] Expected: RED_WRITE | REFACTOR | (IMPL after RED_FAIL for step $STEP) | (GREEN_PASS only on test paths)."
    echo "[hook: PreToolUse] permissionDecision=deny"
  } >> "$ZENSU_HOOK_LOG" 2>/dev/null || true
fi

exit 0
