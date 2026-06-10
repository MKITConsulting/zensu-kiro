#!/usr/bin/env bash
# S08 — Bash witness with Kiro shell payloads. The witness must record every
# shell command run during an active TDD session to .zensu/logs/witness-<sid>.log
# with cmd= / exit= / tail= / interrupted= fields, for both the canonical Kiro
# tool name (shell) and its alias (execute_bash), and stay silent for inactive
# sessions. Runs through kiro-shim.sh exactly as wired in zensu.json.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TDD_STATE_DIR="$TMP/state"
unset CLAUDE_PROJECT_DIR 2>/dev/null || true
mkdir -p "$TMP/home" "$TDD_STATE_DIR"
export HOME="$TMP/home"
SID="s08-witness"
SHIM="$ROOT/hooks/kiro/kiro-shim.sh"
LOG="$ROOT/hooks/lib/zensu-log.sh"
WITNESS="$TMP/.zensu/logs/witness-${SID}.log"

mk_shell() { # $1=tool_name $2=session $3=cmd $4=exit $5=stdout
  printf '{"tool_name":"%s","session_id":"%s","cwd":"%s","tool_input":{"command":"%s"},"tool_response":{"exit_code":%s,"stdout":"%s"}}' "$1" "$2" "$TMP" "$3" "$4" "$5"
}
run_witness() { printf '%s' "$1" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" post-bash-witness.sh >/dev/null 2>&1; }

# 0) inactive session -> no witness file
run_witness "$(mk_shell execute_bash "$SID" "npm test" 0 "all green")"
[ -f "$WITNESS" ] && bad "witness written for inactive session" || ok "inactive session: no witness file"

# 1) active session: execute_bash payload recorded with cmd= and tail=
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
run_witness "$(mk_shell execute_bash "$SID" "npm test" 0 "12 passed, 0 failed")"
[ -f "$WITNESS" ] && ok "witness file created" || bad "witness file missing: $WITNESS"
grep -q 'cmd="npm test"' "$WITNESS" 2>/dev/null && ok "cmd recorded verbatim" || bad "cmd field wrong: $(cat "$WITNESS" 2>/dev/null)"
grep -q 'exit=0' "$WITNESS" 2>/dev/null && ok "exit code recorded" || bad "exit field wrong"
grep -q '12 passed, 0 failed' "$WITNESS" 2>/dev/null && ok "stdout tail recorded" || bad "tail missing"
grep -q 'interrupted=false' "$WITNESS" 2>/dev/null && ok "interrupted flag recorded" || bad "interrupted missing"

# 2) canonical name (shell) also recorded
run_witness "$(mk_shell shell "$SID" "make build" 2 "error: boom")"
grep -q 'cmd="make build"' "$WITNESS" 2>/dev/null && ok "shell alias recorded" || bad "shell alias not recorded"
grep -q 'exit=2' "$WITNESS" 2>/dev/null && ok "non-zero exit recorded" || bad "non-zero exit missing"

# 2b) LIVE-VERIFIED Kiro response shape: tool_response = {success, result}
#     (no exit_code/stdout keys) — the tail must come from `result`.
printf '{"tool_name":"shell","session_id":"%s","cwd":"%s","tool_input":{"command":"node --test"},"tool_response":{"success":true,"result":"tests 7 pass 7 fail 0"}}' "$SID" "$TMP" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" post-bash-witness.sh >/dev/null 2>&1
grep -q 'tests 7 pass 7 fail 0' "$WITNESS" 2>/dev/null && ok "Kiro result-key tail recorded" || bad "Kiro result-key tail missing"

# 2c) interrupted flag + 200-char tail truncation
LONG="$(printf 'A%.0s' $(seq 1 300))"
printf '{"tool_name":"shell","session_id":"%s","cwd":"%s","tool_input":{"command":"long run"},"tool_response":{"exit_code":1,"stdout":"%s","interrupted":true}}' "$SID" "$TMP" "$LONG" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" post-bash-witness.sh >/dev/null 2>&1
grep -q 'interrupted=true' "$WITNESS" 2>/dev/null && ok "interrupted=true recorded" || bad "interrupted=true missing"
TAIL_LEN="$(grep 'cmd="long run"' "$WITNESS" | sed -n 's/.*tail="\([^"]*\)".*/\1/p' | head -1 | wc -c | tr -d '[:space:]')"
[ "${TAIL_LEN:-999}" -le 210 ] && ok "tail truncated to <=200 chars (len=$TAIL_LEN)" || bad "tail not truncated (len=$TAIL_LEN)"

# 2d) symlinked logs dir must be refused (no witness write through symlinks —
#     same guard class as the rounds counter and stop budget)
SLY="$TMP/sly"; REALDIR="$TMP/elsewhere"
mkdir -p "$SLY" "$REALDIR"
mkdir -p "$SLY/.zensu"
ln -s "$REALDIR" "$SLY/.zensu/logs"
printf '{"tool_name":"shell","session_id":"%s","cwd":"%s","tool_input":{"command":"sneaky"},"tool_response":{"exit_code":0,"stdout":"x"}}' "$SID" "$SLY" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" post-bash-witness.sh >/dev/null 2>&1
grep -rq 'sneaky' "$REALDIR" 2>/dev/null && bad "witness wrote through symlinked logs dir" || ok "witness refuses symlinked logs dir"

# 3) ZENSU_TEST_WITNESS=off silences
LINES_BEFORE="$(wc -l < "$WITNESS" | tr -d '[:space:]')"
printf '%s' "$(mk_shell shell "$SID" "echo skip" 0 "skip")" | env -u ZENSU_PLUGIN_ROOT ZENSU_TEST_WITNESS=off bash "$SHIM" post-bash-witness.sh >/dev/null 2>&1
LINES_AFTER="$(wc -l < "$WITNESS" | tr -d '[:space:]')"
[ "$LINES_BEFORE" = "$LINES_AFTER" ] && ok "ZENSU_TEST_WITNESS=off silences" || bad "witness wrote despite off"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
