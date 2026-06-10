#!/usr/bin/env bash
# S06 — context-injecting hooks through the shim. Kiro userPromptSubmit hooks
# add their STDOUT to the agent context on exit 0; the upstream hooks emit the
# Claude additionalContext JSON envelope, so kiro-shim.sh must unwrap it to
# plain text. The ported texts must not instruct Claude-only tools.
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
SHIM="$ROOT/hooks/kiro/kiro-shim.sh"
LOG="$ROOT/hooks/lib/zensu-log.sh"

mk_prompt() { # $1=session $2=prompt text
  printf '{"prompt":"%s","session_id":"%s","cwd":"%s"}' "$2" "$1" "$TMP"
}
run_shim() { # $1=script $2=payload
  printf '%s' "$2" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" "$1" 2>/dev/null
}

# 1) tdd-reminder fires on an implementation prompt (no active TDD session)
OUT="$(run_shim user-prompt-tdd-reminder.sh "$(mk_prompt s06-fresh 'add a slugify function to utils')")"
printf '%s' "$OUT" | grep -q "TDD" && ok "tdd-reminder emits TDD context" || bad "tdd-reminder silent: '$OUT'"
printf '%s' "$OUT" | grep -q "/zensu-tdd" && ok "tdd-reminder names /zensu-tdd" || bad "tdd-reminder lacks /zensu-tdd"
printf '%s' "$OUT" | grep -q "hookSpecificOutput" && bad "tdd-reminder output still JSON-wrapped" || ok "tdd-reminder output unwrapped (plain text)"
printf '%s' "$OUT" | grep -qE "AskUserQuestion|MultiEdit|Skill tool" && bad "tdd-reminder text instructs Claude-only tools" || ok "tdd-reminder text is Kiro-native"

# 2) tdd-reminder is silent while a TDD session is active
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-begin --session s06-active >/dev/null 2>&1
OUT="$(run_shim user-prompt-tdd-reminder.sh "$(mk_prompt s06-active 'add a function')")"
[ -z "$OUT" ] && ok "tdd-reminder silent during active TDD session" || bad "tdd-reminder fired during active session: '$OUT'"

# 3) tdd-reminder is silent without a prompt field
OUT="$(printf '{"session_id":"s06-noprompt","cwd":"%s"}' "$TMP" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" user-prompt-tdd-reminder.sh 2>/dev/null)"
[ -z "$OUT" ] && ok "tdd-reminder silent without prompt field" || bad "tdd-reminder fired without prompt"

# 4) intent-router fires on product-planning keywords, silent otherwise
OUT="$(run_shim user-prompt-intent-router.sh "$(mk_prompt s06-route 'I want to track features for my new product')")"
printf '%s' "$OUT" | grep -q "zensu-plm" && ok "intent-router routes to zensu-plm" || bad "intent-router silent on planning prompt: '$OUT'"
printf '%s' "$OUT" | grep -q "hookSpecificOutput" && bad "intent-router output still JSON-wrapped" || ok "intent-router output unwrapped"
OUT="$(run_shim user-prompt-intent-router.sh "$(mk_prompt s06-route 'what time is it')")"
[ -z "$OUT" ] && ok "intent-router silent on unrelated prompt" || bad "intent-router fired on unrelated prompt"

# 5) context-nudge (wired but inert on Kiro payloads) must stay silent, rc 0
printf '%s' "$(mk_prompt s06-nudge 'anything')" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" user-prompt-context-nudge.sh >"$TMP/o" 2>"$TMP/e"
RC=$?
[ "$RC" -eq 0 ] && ok "context-nudge exits 0 (fail-safe)" || bad "context-nudge rc $RC"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
