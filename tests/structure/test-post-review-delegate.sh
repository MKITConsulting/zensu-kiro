#!/usr/bin/env bash
# S10 — post-review auto-fix delegate on Kiro. The hook fires on postToolUse for
# the `subagent` tool; Kiro's payload names the spawned agent inside tool_input
# (exact field unguaranteed), so the filter must tolerantly scan tool_input
# strings for "zensu-code-reviewer" instead of Claude's tool_input.subagent_type.
# It must keep the round counter and emit Kiro-native directives (subagent tool,
# /zensu-tdd, /zensu-self-review) via additionalContext (shim -> plain stdout).
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
SID="s10-delegate"
SHIM="$ROOT/hooks/kiro/kiro-shim.sh"

mk_subagent() { # $1=agent name
  printf '{"tool_name":"subagent","session_id":"%s","cwd":"%s","tool_input":{"agent":"%s","prompt":"PRE-MERGED FINDINGS (fan-out): 1. src/x.js:3 bug"},"tool_response":{"output":"report done"}}' "$SID" "$TMP" "$1"
}
run_hook() { printf '%s' "$1" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" post-review-tdd-delegate.sh 2>/dev/null; }

# 1) fires when the spawned agent is zensu-code-reviewer (tolerant tool_input scan)
OUT="$(run_hook "$(mk_subagent zensu-code-reviewer)")"
printf '%s' "$OUT" | grep -q "code-reviewer" && ok "delegate fires on reviewer completion" || bad "delegate silent: '$OUT'"
printf '%s' "$OUT" | grep -q "hookSpecificOutput" && bad "output still JSON-wrapped" || ok "output unwrapped"
printf '%s' "$OUT" | grep -q "/zensu-tdd" && ok "directive names /zensu-tdd" || bad "directive lacks /zensu-tdd"
printf '%s' "$OUT" | grep -qE "subagent_type|Agent tool|Skill tool|/zensu:" && bad "directive still Claude-flavored" || ok "directive is Kiro-native"

# 2) round counter persisted under <cwd>/.zensu/state
COUNTER="$TMP/.zensu/state/rounds-${SID}.json"
[ -f "$COUNTER" ] && ok "round counter created" || bad "round counter missing"
run_hook "$(mk_subagent zensu-code-reviewer)" >/dev/null
C="$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).count)}catch(_){console.log("?")}' "$COUNTER" 2>/dev/null)"
[ "$C" = "2" ] && ok "round counter increments (count=2)" || bad "round counter: got '$C', expected 2"

# 3) silent for other subagents
OUT="$(run_hook "$(mk_subagent explorer)")"
[ -z "$OUT" ] && ok "silent for non-reviewer subagent" || bad "fired for non-reviewer: '$OUT'"

# 4) max-rounds convergence hands off to /zensu-self-review (selfReview default on)
for i in 3 4 5 6; do OUT="$(run_hook "$(mk_subagent zensu-code-reviewer)")"; done
printf '%s' "$OUT" | grep -qi "convergence" && ok "max-rounds convergence reached" || bad "no convergence message: '$OUT'"
printf '%s' "$OUT" | grep -q "/zensu-self-review" && ok "convergence routes to /zensu-self-review" || bad "convergence lacks /zensu-self-review"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
