#!/usr/bin/env bash
# S21a — session-id resolution for model-shell zensu-log calls on Kiro.
# Live finding (diagnostics D2/D3): hooks receive the real session_id in their
# payload, but `zensu-log.sh --tdd-begin` run from the model's shell tool has
# no session source on Kiro (no CLAUDE_SESSION_ID env, no Claude transcript for
# the helper, different process ancestry than the agentSpawn hook that wrote
# the keyed cache) — it fell back to fallback_<ppid> and armed the WRONG state
# file, so the gate/stop hooks saw an inactive session.
# Contract (implemented order): explicit id > project-scoped
# `.zensu/state/session-id-current.txt` (written by capture-sid) > Claude
# transcript helper > PPID-keyed cache > fallback. The current file outranks
# the keyed cache on purpose: on Kiro the keyed cache is written under the
# HOOK's ancestry key and can never match a model-shell caller anyway.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; TMP2=""; trap 'rm -rf "$TMP" "$TMP2"' EXIT
unset CLAUDE_PROJECT_DIR CLAUDE_SESSION_ID 2>/dev/null || true
mkdir -p "$TMP/home"
export HOME="$TMP/home"
SID="kiro-real-session-uuid-1234"
SHIM="$ROOT/hooks/kiro/kiro-shim.sh"

# 1) agentSpawn capture-sid writes the project-scoped current-session file
printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$TMP" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" session-start-capture-sid.sh >/dev/null 2>&1
[ -f "$TMP/.zensu/state/session-id-current.txt" ] && ok "session-id-current.txt written" || bad "session-id-current.txt missing"
[ "$(cat "$TMP/.zensu/state/session-id-current.txt" 2>/dev/null | tr -d '[:space:]')" = "$SID" ] && ok "current file carries the payload sid" || bad "current file content wrong"

# 2) a model-shell zensu-log call (no --session, no env, different ancestry)
#    must arm the REAL session's state file via the current-file lookup
( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/hooks/lib/zensu-log.sh" --tdd-begin >/dev/null 2>&1 )
[ -f "$TMP/.zensu/state/tdd-phase-${SID}.json" ] && ok "zensu-log armed the real session state file" || { bad "real-session state file missing"; ls "$TMP/.zensu/state" 2>/dev/null | sed 's/^/      /'; }

# 3) and the gate (payload-sid resolution) must now see the armed session:
#    RED_FAIL seeded via the same path -> fs_write on prod denied
( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/hooks/lib/zensu-log.sh" --phase RED_WRITE --step s1 >/dev/null 2>&1 )
( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" bash "$ROOT/hooks/lib/zensu-log.sh" --phase RED_FAIL --step s1 --reason seeded >/dev/null 2>&1 )
printf '{"tool_name":"fs_write","session_id":"%s","cwd":"%s","tool_input":{"command":"append","path":"src/app.js"}}' "$SID" "$TMP" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" pre-edit-tdd-reminder.sh >"$TMP/o" 2>"$TMP/e"
RC=$?
[ "$RC" -eq 2 ] && ok "gate denies with shell-seeded state (end-to-end session match)" || bad "gate rc=$RC, expected 2 (session still mismatched)"

# 4) precedence: an explicit id still wins over the current file
GOT="$(source "$ROOT/hooks/lib/zensu-session.sh"; CLAUDE_PROJECT_DIR="$TMP" zensu_resolve_session_id "explicit-id")"
[ "$GOT" = "explicit-id" ] && ok "explicit id wins over current file" || bad "explicit id lost: got '$GOT'"

# 4b) mixed-machine reality: a Claude Code transcript for the SAME project must
#     NOT outrank the Kiro current-session file — otherwise a concurrently (or
#     previously) used Claude session detaches the armed Kiro state mid-TDD.
#     The transcript helper derives its dir from the cwd; plant one for $TMP.
SAN="$(printf '%s' "$TMP" | sed 's|[^A-Za-z0-9_-]|-|g')"
mkdir -p "$HOME/.claude/projects/$SAN"
printf '{"sessionId":"claude-transcript-id"}\n' > "$HOME/.claude/projects/$SAN/claude-transcript-id.jsonl"
GOT="$(source "$ROOT/hooks/lib/zensu-session.sh"; cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" ZENSU_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$ROOT" zensu_resolve_session_id "")"
[ "$GOT" = "$SID" ] && ok "current-session file outranks Claude transcript helper" || bad "transcript helper won: got '$GOT', expected '$SID'"

# 4c) precedence pin: current file beats the PPID-keyed cache
KEY="$(source "$ROOT/hooks/lib/zensu-session.sh"; zensu_session_key)"
printf 'keyed-cache-id\n' > "$TMP/.zensu/state/session-id-${KEY}.txt"
GOT="$(source "$ROOT/hooks/lib/zensu-session.sh"; CLAUDE_PROJECT_DIR="$TMP" zensu_resolve_session_id "")"
[ "$GOT" = "$SID" ] && ok "current file outranks keyed cache" || bad "keyed cache won: got '$GOT'"
rm -f "$TMP/.zensu/state/session-id-${KEY}.txt"

# 4d) transcript-helper precondition: prove the planted transcript IS
#     resolvable by the helper alone (otherwise 4b is vacuous, e.g. on
#     Windows runners with path-sanitization mismatches)
mv "$TMP/.zensu/state/session-id-current.txt" "$TMP/.zensu/state/session-id-current.txt.bak"
GOT="$(source "$ROOT/hooks/lib/zensu-session.sh"; cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" ZENSU_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_ROOT="$ROOT" zensu_resolve_session_id "")"
if [ "$GOT" = "claude-transcript-id" ]; then
  ok "transcript helper resolves the planted fixture (4b is a real test)"
else
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ok "skipped: transcript fixture unresolvable on Windows path semantics (4b vacuous here, real on ubuntu)" ;;
    *) bad "transcript helper cannot resolve planted fixture (4b vacuous): got '$GOT'" ;;
  esac
fi
mv "$TMP/.zensu/state/session-id-current.txt.bak" "$TMP/.zensu/state/session-id-current.txt"

# 5) LIVE-VERIFIED Kiro reality: hook payloads carry NO session_id at all
#    (observed keys: hook_event_name, cwd, prompt). capture-sid must then
#    SYNTHESIZE a session id and still write the current file, so hooks and
#    model-shell zensu-log calls converge on one state file.
TMP2="$(mktemp -d)"  # cleaned by the EXIT trap
printf '{"hook_event_name":"agentSpawn","cwd":"%s","prompt":"hi"}' "$TMP2" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" session-start-capture-sid.sh >/dev/null 2>&1
CUR="$TMP2/.zensu/state/session-id-current.txt"
[ -f "$CUR" ] && ok "no-sid payload: current file still written (synthesized)" || bad "no-sid payload: current file missing"
SYN="$(cat "$CUR" 2>/dev/null | tr -d '[:space:]')"
printf '%s' "$SYN" | grep -qE '^[A-Za-z0-9_-]{8,}$' && ok "synthesized id is sane ('$SYN')" || bad "synthesized id malformed: '$SYN'"
( cd "$TMP2" && CLAUDE_PROJECT_DIR="$TMP2" bash "$ROOT/hooks/lib/zensu-log.sh" --tdd-begin >/dev/null 2>&1 )
( cd "$TMP2" && CLAUDE_PROJECT_DIR="$TMP2" bash "$ROOT/hooks/lib/zensu-log.sh" --phase RED_WRITE --step s1 >/dev/null 2>&1 )
( cd "$TMP2" && CLAUDE_PROJECT_DIR="$TMP2" bash "$ROOT/hooks/lib/zensu-log.sh" --phase RED_FAIL --step s1 --reason seeded >/dev/null 2>&1 )
printf '{"hook_event_name":"preToolUse","tool_name":"fs_write","cwd":"%s","tool_input":{"command":"append","path":"src/app.js"}}' "$TMP2" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" pre-edit-tdd-reminder.sh >/dev/null 2>"$TMP2/e"
RC=$?
[ "$RC" -eq 2 ] && ok "no-sid end-to-end: gate denies via synthesized session" || bad "no-sid gate rc=$RC, expected 2"


printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
