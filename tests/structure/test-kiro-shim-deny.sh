#!/usr/bin/env bash
# S04 — kiro-shim.sh must translate the engine-neutral deny JSON emitted by the
# wrapped hook (hookSpecificOutput.permissionDecision="deny") into Kiro CLI
# preToolUse blocking semantics: exit code 2 with the human-readable reason on
# STDERR (Kiro returns stderr to the LLM). Allowed calls pass through silently
# with exit 0. The shim self-resolves the plugin root from its own path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TDD_STATE_DIR="$TMP/state"
unset CLAUDE_PROJECT_DIR 2>/dev/null || true
mkdir -p "$TDD_STATE_DIR"
SID="s04-shim-deny"
LOG="$ROOT/hooks/lib/zensu-log.sh"
SHIM="$ROOT/hooks/kiro/kiro-shim.sh"

mk_kiro_write() { # $1=path
  printf '{"tool_name":"fs_write","session_id":"%s","cwd":"%s","tool_input":{"command":"create","path":"%s","file_text":"x"}}' "$SID" "$TMP" "$1"
}

# Seed: armed session in RED_FAIL for step s1 (prod edits must be denied).
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --phase RED_WRITE --step s1 --session "$SID" >/dev/null 2>&1
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --phase RED_FAIL --step s1 --session "$SID" >/dev/null 2>&1

# 1) deny -> exit 2, reason on stderr (plain text, not JSON), stdout empty
OUT="$TMP/out"; ERR="$TMP/err"
printf '%s' "$(mk_kiro_write src/app.js)" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" pre-edit-tdd-reminder.sh >"$OUT" 2>"$ERR"
RC=$?
[ "$RC" -eq 2 ] && ok "deny exit code 2" || bad "deny exit code: got $RC, expected 2"
grep -q "TDD-Phase-Gate" "$ERR" && ok "deny reason on stderr" || bad "stderr lacks deny reason: $(cat "$ERR")"
grep -q "permissionDecision" "$ERR" && bad "stderr still contains raw JSON schema" || ok "stderr is plain text (no permissionDecision)"
[ -s "$OUT" ] && bad "stdout not empty on deny: $(cat "$OUT")" || ok "stdout empty on deny"

# 2) allowed (test path) -> exit 0, silent
printf '%s' "$(mk_kiro_write src/app.test.js)" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" pre-edit-tdd-reminder.sh >"$OUT" 2>"$ERR"
RC=$?
[ "$RC" -eq 0 ] && ok "allow exit code 0" || bad "allow exit code: got $RC, expected 0"
[ -s "$ERR" ] && bad "stderr not empty on allow: $(cat "$ERR")" || ok "stderr empty on allow"

# 3) ZENSU_TDD_GATE=off bypass -> exit 0
printf '%s' "$(mk_kiro_write src/app.js)" | env -u ZENSU_PLUGIN_ROOT ZENSU_TDD_GATE=off bash "$SHIM" pre-edit-tdd-reminder.sh >"$OUT" 2>"$ERR"
RC=$?
[ "$RC" -eq 0 ] && ok "gate-off bypass exit 0" || bad "gate-off bypass: got $RC, expected 0"

# 4) unknown wrapped script -> fail-open exit 0 (never break the host session)
printf '%s' "$(mk_kiro_write src/app.js)" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" no-such-hook.sh >"$OUT" 2>"$ERR"
RC=$?
[ "$RC" -eq 0 ] && ok "unknown script fail-open exit 0" || bad "unknown script: got $RC, expected 0"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
