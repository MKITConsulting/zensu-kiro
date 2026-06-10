#!/bin/bash
# kiro-shim.sh — the single engine-translation layer between Kiro CLI hooks and
# the engine-neutral zensu hook scripts. Kiro agent configs register every hook
# as `bash <ZENSU_HOME>/hooks/kiro/kiro-shim.sh <script>.sh`; the wrapped script
# stays byte-comparable to its Claude Code / Codex counterpart.
#
# Translation rules (wrapped script's stdout -> Kiro semantics):
#   - {"hookSpecificOutput":{"permissionDecision":"deny", ...}}
#       -> reason on STDERR + exit 2 (Kiro preToolUse: exit 2 blocks the tool,
#          stderr is returned to the LLM)
#   - {"decision":"block", ...}
#       -> passthrough on STDOUT + exit 0 (Kiro Stop hooks speak this schema
#          natively — full parity with Claude Code)
#   - {"hookSpecificOutput":{"additionalContext": "..."}}
#       -> plain context text on STDOUT + exit 0 (Kiro adds hook stdout to the
#          agent context on exit 0)
#   - anything else -> passthrough stdout/stderr + the script's own exit code
#
# Fail-open: a missing/broken wrapped script or missing node must never break
# the host session — the shim exits 0 silently in those cases.
set -u

SHIM_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SHIM_DIR/../.." && pwd)"
export ZENSU_PLUGIN_ROOT="$ROOT"
export CLAUDE_PLUGIN_ROOT="$ROOT"

SCRIPT_NAME="${1:-}"
[ -z "$SCRIPT_NAME" ] && exit 0
SCRIPT="$ROOT/hooks/$SCRIPT_NAME"
[ -f "$SCRIPT" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

PAYLOAD="$(cat 2>/dev/null || true)"

OUT_FILE="$(mktemp 2>/dev/null || printf '/tmp/zensu-shim-%s' "$$")"
ERR_FILE="${OUT_FILE}.err"
printf '%s' "$PAYLOAD" | bash "$SCRIPT" >"$OUT_FILE" 2>"$ERR_FILE"
SCRIPT_RC=$?

OUT="$(cat "$OUT_FILE" 2>/dev/null || true)"
ERR="$(cat "$ERR_FILE" 2>/dev/null || true)"
rm -f "$OUT_FILE" "$ERR_FILE" 2>/dev/null || true

# Classify the wrapped script's stdout: DENY / CONTEXT / other.
# Prints "deny\n<reason>" or "context\n<text>" or "raw".
VERDICT="$(SHIM_OUT="$OUT" node -e '
  const raw = process.env.SHIM_OUT || "";
  const trimmed = raw.trim();
  let kind = "raw", text = "";
  if (trimmed.startsWith("{")) {
    try {
      const j = JSON.parse(trimmed);
      const hso = j && j.hookSpecificOutput;
      if (hso && hso.permissionDecision === "deny") {
        kind = "deny";
        text = typeof hso.permissionDecisionReason === "string" && hso.permissionDecisionReason
          ? hso.permissionDecisionReason
          : "zensu hook denied this tool call.";
      } else if (hso && typeof hso.additionalContext === "string" && hso.additionalContext) {
        kind = "context";
        text = hso.additionalContext;
      }
    } catch (_) { /* not JSON -> raw */ }
  }
  process.stdout.write(kind + "\n" + text);
' 2>/dev/null || printf 'raw\n')"

KIND="$(printf '%s' "$VERDICT" | sed -n '1p')"
TEXT="$(printf '%s' "$VERDICT" | sed -n '2,$p')"

case "$KIND" in
  deny)
    printf '%s\n' "$TEXT" >&2
    exit 2
    ;;
  context)
    printf '%s\n' "$TEXT"
    exit 0
    ;;
  *)
    [ -n "$OUT" ] && printf '%s\n' "$OUT"
    [ -n "$ERR" ] && printf '%s\n' "$ERR" >&2
    exit "$SCRIPT_RC"
    ;;
esac
