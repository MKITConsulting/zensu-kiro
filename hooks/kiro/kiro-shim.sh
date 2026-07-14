#!/bin/bash
# kiro-shim.sh — the single engine-translation layer between Kiro CLI hooks and
# the engine-neutral zensu hook scripts. Kiro agent configs register every hook
# as `bash <ZENSU_HOME>/hooks/kiro/kiro-shim.sh <protocol> <script>.sh`; the wrapped script
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
#   - anything else -> passthrough stdout/stderr + exit 0 (fail-open; exit 2
#     is reserved exclusively for the explicit deny classification)
#
# Lifecycle/post hooks remain fail-open when the runtime is unavailable.
# Security/TDD preToolUse gates fail closed so a corrupt or mid-upgrade runtime
# cannot silently disable enforcement.
set -u

SHIM_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SHIM_DIR/../.." && pwd)"
export ZENSU_PLUGIN_ROOT="$ROOT"
export CLAUDE_PLUGIN_ROOT="$ROOT"

SCRIPT_NAME="${1:-}"
EXPECTED_PROTOCOL="$SCRIPT_NAME"
SCRIPT_NAME="${2:-}"
if [ -z "$EXPECTED_PROTOCOL" ] || [ -z "$SCRIPT_NAME" ]; then exit 0; fi

runtime_unavailable() {
  case "$SCRIPT_NAME" in
    pre-edit-tdd-reminder.sh|pre-bash-zensu-gate.sh)
      printf '%s\n' 'Zensu blocked this tool call because the Kiro runtime is unavailable, invalid, or being upgraded.' >&2
      exit 2
      ;;
    *) exit 0 ;;
  esac
}

command -v node >/dev/null 2>&1 || runtime_unavailable
LOCK_HELPER="$ROOT/hooks/lib/kiro-runtime-lock.js"
LOCK_PATH="$HOME/.zensu-kiro-install.lock"
LOCK_OWNER_PID="$$"
case "$(uname -s 2>/dev/null || true)" in
  MINGW*|MSYS*|CYGWIN*)
    NATIVE_PID="$(ps -p "$$" -o winpid= 2>/dev/null | tr -d '[:space:]')"
    [ -n "$NATIVE_PID" ] && LOCK_OWNER_PID="$NATIVE_PID"
    ;;
esac
LOCK_TOKEN=""
[ -f "$LOCK_HELPER" ] || runtime_unavailable
LOCK_ATTEMPT=0
while [ "$LOCK_ATTEMPT" -lt 100 ]; do
  LOCK_RESULT="$(node "$LOCK_HELPER" acquire "$HOME" "$LOCK_PATH" "$LOCK_OWNER_PID" 2>/dev/null)"; LOCK_RC=$?
  if [ "$LOCK_RC" -eq 0 ]; then LOCK_TOKEN="$LOCK_RESULT"; break; fi
  [ "$LOCK_RC" -eq 75 ] || runtime_unavailable
  LOCK_ATTEMPT=$((LOCK_ATTEMPT + 1))
  sleep 0.02
done
[ -n "$LOCK_TOKEN" ] || runtime_unavailable
release_runtime_lock() {
  [ -n "$LOCK_TOKEN" ] || return 0
  node "$LOCK_HELPER" release "$HOME" "$LOCK_PATH" "$LOCK_OWNER_PID" "$LOCK_TOKEN" >/dev/null 2>&1 || return 1
  LOCK_TOKEN=""
}
trap 'release_runtime_lock >/dev/null 2>&1 || true' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Deterministic structure-test barrier: it pauses only after this dispatcher
# owns the real runtime lock and never bypasses lock or integrity validation.
if [ "${NODE_ENV:-}" = "test" ] && [ -n "${ZENSU_KIRO_SHIM_TEST_BARRIER_DIR:-}" ]; then
  SHIM_BARRIER="$ZENSU_KIRO_SHIM_TEST_BARRIER_DIR"
  [ -d "$SHIM_BARRIER" ] && [ ! -L "$SHIM_BARRIER" ] || runtime_unavailable
  ( set -C; printf 'reached\n' > "$SHIM_BARRIER/runtime-lock.reached" ) 2>/dev/null || runtime_unavailable
  SHIM_BARRIER_WAIT=0
  while [ ! -e "$SHIM_BARRIER/runtime-lock.release" ] && [ "$SHIM_BARRIER_WAIT" -lt 750 ]; do
    sleep 0.02
    SHIM_BARRIER_WAIT=$((SHIM_BARRIER_WAIT + 1))
  done
  [ -e "$SHIM_BARRIER/runtime-lock.release" ] || runtime_unavailable
fi

# Automatic hooks use the same complete integrity closure as model-issued
# commands. During an install/upgrade the old manifest and changing files no
# longer agree, so dispatch pauses fail-open instead of mixing runtime bytes.
VALIDATED_ROOT="$(ZENSU_KIRO_LOCK_OWNER_PID="$LOCK_OWNER_PID" ZENSU_KIRO_LOCK_TOKEN="$LOCK_TOKEN" \
  bash "$ROOT/hooks/lib/resolve-plugin-root.sh" "$EXPECTED_PROTOCOL" 2>/dev/null)" || runtime_unavailable
[ "$VALIDATED_ROOT" = "$ROOT" ] || runtime_unavailable
SCRIPT="$VALIDATED_ROOT/hooks/$SCRIPT_NAME"
[ -f "$SCRIPT" ] || runtime_unavailable

PAYLOAD="$(cat 2>/dev/null || true)"

# Private capture dir (no predictable /tmp names, no symlink-followable
# pre-planted siblings — the shim runs on every tool call).
CAP_DIR="$(mktemp -d 2>/dev/null)" || exit 0
OUT_FILE="$CAP_DIR/out"
ERR_FILE="$CAP_DIR/err"
printf '%s' "$PAYLOAD" | bash "$SCRIPT" >"$OUT_FILE" 2>"$ERR_FILE" || true

OUT="$(cat "$OUT_FILE" 2>/dev/null || true)"
ERR="$(cat "$ERR_FILE" 2>/dev/null || true)"
rm -rf "$CAP_DIR" 2>/dev/null || true
release_runtime_lock || runtime_unavailable
trap - EXIT HUP INT TERM

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
    # Fail-open raw branch: pass output through but NEVER surface the wrapped
    # script's own exit code — a crashed/corrupted hook (rc 2 from a bash
    # syntax error!) must not turn into an accidental preToolUse deny. Exit 2
    # is reserved exclusively for the explicit deny classification above.
    [ -n "$OUT" ] && printf '%s\n' "$OUT"
    [ -n "$ERR" ] && printf '%s\n' "$ERR" >&2
    exit 0
    ;;
esac
