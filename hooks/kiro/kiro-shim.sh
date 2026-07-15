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
configure_windows_native_tools() {
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      case "${BASH:-}" in /*) ;; *) return 1 ;; esac
      # Keep bound raw and native anchor identities byte-exact in native Node
      # while retaining normal MSYS argv conversion for untrusted child paths.
      local raw_name
      if [ "${MSYS2_ENV_CONV_EXCL:-}" != "*" ]; then
        for raw_name in ZENSU_KIRO_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_NATIVE ZENSU_KIRO_WORKSPACE_ANCHOR_RAW ZENSU_KIRO_WORKSPACE_ANCHOR_NATIVE ZENSU_KIRO_TEST_ANCHOR_RAW ZENSU_KIRO_TEST_ANCHOR_NATIVE ZENSU_KIRO_ROOT ZENSU_KIRO_RENDER_HOME_RAW; do
          case ";${MSYS2_ENV_CONV_EXCL:-};" in
            *";$raw_name;"*) ;;
            *) MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+${MSYS2_ENV_CONV_EXCL};}$raw_name" ;;
          esac
        done
      fi
      export MSYS2_ENV_CONV_EXCL
      local cygpath_posix="${BASH%/*}/cygpath.exe"
      local bash_posix="$BASH"
      case "$bash_posix" in *.exe) ;; *) [ -x "${bash_posix}.exe" ] && bash_posix="${bash_posix}.exe" ;; esac
      [ -x "$cygpath_posix" ] || return 1
      ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE="$("$cygpath_posix" -m "$cygpath_posix" 2>/dev/null)" || return 1
      ZENSU_KIRO_TRUSTED_BASH_NATIVE="$("$cygpath_posix" -m "$bash_posix" 2>/dev/null)" || return 1
      case "$ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE$ZENSU_KIRO_TRUSTED_BASH_NATIVE" in *[$'\r\n\t']*|'') return 1 ;; esac
      export ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE ZENSU_KIRO_TRUSTED_BASH_NATIVE
      ;;
  esac
}
configure_windows_native_tools || runtime_unavailable
NATIVE_ANCHOR_HELPER="$ROOT/hooks/lib/resolve-native-anchor.js"
[ -f "$NATIVE_ANCHOR_HELPER" ] || runtime_unavailable
NATIVE_PID_HELPER="$ROOT/hooks/lib/capture-native-shell-pid.sh"
[ -f "$NATIVE_PID_HELPER" ] || runtime_unavailable
. "$NATIVE_PID_HELPER"
ZENSU_KIRO_HOME_ANCHOR_RAW="${HOME:-}"
# Avoid MSYS argv path-list conversion when the fixed runtime lives below a
# valid HOME containing a semicolon. The helper consumes no command arguments.
ZENSU_KIRO_HOME_ANCHOR_NATIVE="$(ZENSU_KIRO_ANCHOR_RAW="$ZENSU_KIRO_HOME_ANCHOR_RAW" node < "$NATIVE_ANCHOR_HELPER" 2>/dev/null)" || runtime_unavailable
export ZENSU_KIRO_HOME_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_NATIVE
LOCK_HELPER="$ROOT/hooks/lib/kiro-runtime-lock.js"
LOCK_PATH="$HOME/.zensu-kiro-install.lock"
LOCK_PID_FILE="$(mktemp 2>/dev/null)" || runtime_unavailable
if ! zensu_capture_native_shell_pid "$LOCK_PID_FILE"; then
  rm -f "$LOCK_PID_FILE" 2>/dev/null || true
  runtime_unavailable
fi
IFS= read -r LOCK_OWNER_PID < "$LOCK_PID_FILE" || LOCK_OWNER_PID=""
rm -f "$LOCK_PID_FILE" 2>/dev/null || true
case "$LOCK_OWNER_PID" in ''|*[!0-9]*) runtime_unavailable ;; esac
LOCK_TOKEN=""
[ -f "$LOCK_HELPER" ] || runtime_unavailable
# The installed lock helper has the same hostile-HOME argv hazard as the
# native-anchor helper. Keep its CommonJS `require.main` CLI semantics by
# binding the script path to the already-verified native HOME, then suppress
# MSYS conversion for this one native Node command and its raw lock arguments.
LOCK_HELPER_NATIVE="$LOCK_HELPER"
case "${OSTYPE:-}" in
  msys*|cygwin*) LOCK_HELPER_NATIVE="${ZENSU_KIRO_HOME_ANCHOR_NATIVE%[\\/]}/.kiro/zensu/hooks/lib/kiro-runtime-lock.js" ;;
esac
run_runtime_lock() {
  case "${OSTYPE:-}" in
    msys*|cygwin*) MSYS2_ARG_CONV_EXCL='*' node "$LOCK_HELPER_NATIVE" "$@" ;;
    *) node "$LOCK_HELPER" "$@" ;;
  esac
}
LOCK_ATTEMPT=0
while [ "$LOCK_ATTEMPT" -lt 100 ]; do
  LOCK_RESULT="$(run_runtime_lock acquire "$HOME" "$LOCK_PATH" "$LOCK_OWNER_PID" 2>/dev/null)"; LOCK_RC=$?
  if [ "$LOCK_RC" -eq 0 ]; then LOCK_TOKEN="$LOCK_RESULT"; break; fi
  [ "$LOCK_RC" -eq 75 ] || runtime_unavailable
  LOCK_ATTEMPT=$((LOCK_ATTEMPT + 1))
  sleep 0.02
done
[ -n "$LOCK_TOKEN" ] || runtime_unavailable
release_runtime_lock() {
  [ -n "$LOCK_TOKEN" ] || return 0
  run_runtime_lock release "$HOME" "$LOCK_PATH" "$LOCK_OWNER_PID" "$LOCK_TOKEN" >/dev/null 2>&1 || return 1
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
