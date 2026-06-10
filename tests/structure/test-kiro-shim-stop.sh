#!/usr/bin/env bash
# S07 — Stop chain-enforcer through the shim. Kiro Stop hooks natively accept
# {"decision":"block","reason":...} on stdout (same schema as Claude Code), so
# the shim passes it through verbatim with exit 0 — FULL parity (the Codex port
# could only advise). The directives must speak Kiro language (subagent tool,
# /zensu-self-review slash skill), and the anti-deadlock .stopblocks budget must
# eventually release a stalled chain.
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
SID="s07-stop"
SHIM="$ROOT/hooks/kiro/kiro-shim.sh"
LOG="$ROOT/hooks/lib/zensu-log.sh"

payload() { printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$TMP"; }
run_stop() { printf '%s' "$(payload)" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" stop-chain-enforcer.sh 2>/dev/null; }

# 0) inactive session -> silent allow
OUT="$(run_stop)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "inactive session: silent exit 0" || bad "inactive: rc=$RC out='$OUT'"

# 1) implComplete && !chainDone -> block JSON passthrough on stdout
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-complete --session "$SID" >/dev/null 2>&1
OUT="$(run_stop)"; RC=$?
[ "$RC" -eq 0 ] && ok "block exit 0" || bad "block rc=$RC, expected 0"
printf '%s' "$OUT" | grep -q '"decision":"block"' && ok "stop emits decision:block" || bad "no block decision: '$OUT'"
printf '%s' "$OUT" | grep -q "zensu-code-reviewer" && ok "reason names zensu-code-reviewer" || bad "reason lacks reviewer"
printf '%s' "$OUT" | grep -q "subagent" && ok "reason speaks Kiro (subagent tool)" || bad "reason lacks 'subagent' wording"
printf '%s' "$OUT" | grep -qE '\$zensu-|Codex' && bad "reason still Codex-flavored" || ok "reason free of Codex-isms"

# 2) two-stage terminus: codeReviewDone -> directive must route to /zensu-self-review
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --code-review-done --session "$SID" >/dev/null 2>&1
OUT="$(run_stop)"
printf '%s' "$OUT" | grep -q '"decision":"block"' && ok "post-review stop still blocks" || bad "post-review stop did not block"
printf '%s' "$OUT" | grep -q "/zensu-self-review" && ok "directive names /zensu-self-review" || bad "directive lacks /zensu-self-review: '$OUT'"

# 3) chainDone -> silent allow
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --chain-done --session "$SID" >/dev/null 2>&1
OUT="$(run_stop)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "chainDone: silent exit 0" || bad "chainDone: rc=$RC out='$OUT'"

# 3b) a SECOND chain in the same session must be enforced again: --tdd-begin
#     has to clear implComplete/chainDone/codeReviewDone and the .stopblocks
#     budget left over from chain 1, or the backstop is a silent no-op for
#     every later chain.
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
OUT="$(run_stop)"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "chain 2 armed: stop allowed before implComplete" || bad "chain 2 pre-complete stop wrong: rc=$RC out present"
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-complete --session "$SID" >/dev/null 2>&1
OUT="$(run_stop)"
printf '%s' "$OUT" | grep -q '"decision":"block"' && ok "chain 2: stop blocks again after re-begin" || bad "chain 2 unenforced (stale chainDone survived --tdd-begin)"
printf '%s' "$OUT" | grep -q "/zensu-self-review" && bad "chain 2 wrongly resumed at self-review stage (stale codeReviewDone)" || ok "chain 2 starts at reviewer stage (codeReviewDone cleared)"
[ -f "$(ls "$TDD_STATE_DIR"/tdd-phase-${SID}.json.stopblocks 2>/dev/null | head -1)" ] && B2="$(wc -c < "$TDD_STATE_DIR/tdd-phase-${SID}.json.stopblocks" | tr -d '[:space:]')" || B2=0
[ "${B2:-0}" -le 2 ] && ok "stopblocks budget reset by --tdd-begin (now $B2)" || bad "stopblocks budget carried over: $B2"

# 3c) --tdd-begin must ALSO reset the auto-fix rounds counter (chain 2 starts
#     at round 1; a carried-over counter would converge the chain prematurely)
mkdir -p "$TMP/.zensu/state"
printf '{"count":4}\n' > "$TMP/.zensu/state/rounds-${SID}.json"
( cd "$TMP" && CLAUDE_PROJECT_DIR="$TMP" ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1 )
[ -f "$TMP/.zensu/state/rounds-${SID}.json" ] && bad "rounds counter survived --tdd-begin" || ok "rounds counter reset by --tdd-begin"
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-complete --session "$SID" >/dev/null 2>&1
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --chain-done --session "$SID" >/dev/null 2>&1

# 3c2) the rounds-counter path must come from ONE shared helper
#      (zensu_rounds_counter_file in the FSM lib), consumed by BOTH the
#      delegate and zensu-log --tdd-begin — duplicated expressions drift.
grep -q "zensu_rounds_counter_file" "$ROOT/hooks/lib/zensu-tdd-phase.sh" && ok "shared rounds-path helper exists in lib" || bad "no zensu_rounds_counter_file helper in zensu-tdd-phase.sh"
grep -q "zensu_rounds_counter_file" "$ROOT/hooks/lib/zensu-log.sh" && ok "zensu-log consumes the shared helper" || bad "zensu-log still inlines the rounds path"
grep -q "zensu_rounds_counter_file" "$ROOT/hooks/post-review-tdd-delegate.sh" && ok "delegate consumes the shared helper" || bad "delegate still inlines the rounds path"
HGOT="$(source "$ROOT/hooks/lib/zensu-tdd-phase.sh" 2>/dev/null; CLAUDE_PROJECT_DIR="$TMP" zensu_rounds_counter_file demo-sid 2>/dev/null)"
[ "$HGOT" = "$TMP/.zensu/state/rounds-demo-sid.json" ] && ok "helper resolves the canonical path" || bad "helper path wrong: '$HGOT'"

# 3d) a truncated zensu-log option call (value missing) must FAIL FAST, never
#     hang the model's shell tool in an arg-loop
if command -v timeout >/dev/null 2>&1; then
  timeout 3 bash "$LOG" --phase IMPL --step >/dev/null 2>&1
  RC=$?
  [ "$RC" -ne 124 ] && ok "truncated --step call exits (rc=$RC, no hang)" || bad "zensu-log hangs on missing option value"
  timeout 3 bash "$LOG" --tdd-begin --session >/dev/null 2>&1
  RC=$?
  [ "$RC" -ne 124 ] && ok "truncated --session call exits (rc=$RC, no hang)" || bad "zensu-log hangs on missing --session value"
else
  ok "skipped: no timeout(1) on this platform (no-hang guard covered on CI)"
fi

# 4) anti-deadlock budget: a stalled chain stops blocking after the cap
SID="s07-budget"
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-complete --session "$SID" >/dev/null 2>&1
BLOCKED=0; RELEASED=0
for i in $(seq 1 12); do
  OUT="$(run_stop)"
  if printf '%s' "$OUT" | grep -q '"decision":"block"'; then BLOCKED=$((BLOCKED+1)); else RELEASED=1; break; fi
done
[ "$BLOCKED" -ge 1 ] && ok "budget: blocked at least once ($BLOCKED times)" || bad "budget: never blocked"
[ "$RELEASED" -eq 1 ] && ok "budget: released after cap" || bad "budget: still blocking after 12 stops"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
