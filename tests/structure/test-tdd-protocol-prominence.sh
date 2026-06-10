#!/usr/bin/env bash
# F14 — the TDD command protocol (arm with --tdd-begin; declare every phase
# with --phase <P> --step <id>) must be carried by the PLUGIN, never by eval
# prompts. Live evidence (kiro-cli 2.6.1, B5): run 1 skipped arming entirely
# and run 2 omitted --step on the markers until the eval prompt spelled the
# exact commands out — i.e. the skill body documented the contract but too
# diffusely for headless protocol adherence. Pin three plugin-side carriers
# (a compact mandatory block at the TOP of the zensu-tdd skill, the agentSpawn
# primer, the steering cheat sheet) AND pin the B5 eval prompt NEUTRAL so the
# live eval keeps proving plugin-embedded guidance alone drives compliance.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

SKILL="$ROOT/skills/zensu-tdd/SKILL.md"
PRIMER="$ROOT/hooks/session-start-primer.sh"
STEER="$ROOT/steering/zensu-tdd-protocol.md"
PFOO="$ROOT/tests/promptfoo/promptfooconfig.yaml"

# ── 1) zensu-tdd skill: mandatory command block ABOVE "## When to Use" ──────
TOP="$(awk '/^## When to Use/{exit} {print}' "$SKILL")"

printf '%s' "$TOP" | grep -qi "command protocol" \
  && ok "skill top: command-protocol heading present" \
  || bad "skill top: no command-protocol heading before '## When to Use'"

printf '%s' "$TOP" | grep -q -- "--tdd-begin" \
  && ok "skill top: arming command (--tdd-begin) present" \
  || bad "skill top: --tdd-begin missing"

for M in RED_WRITE RED_RUN RED_FAIL IMPL GREEN_RUN GREEN_PASS; do
  printf '%s' "$TOP" | grep -q -- "--phase $M --step" \
    && ok "skill top: marker $M carries --step" \
    || bad "skill top: --phase $M --step missing"
done

printf '%s' "$TOP" | grep -qi "REQUIRED on every marker" \
  && ok "skill top: --step REQUIRED-on-every-marker rule stated" \
  || bad "skill top: per-marker --step requirement not stated"

printf '%s' "$TOP" | grep -qi "per step" \
  && ok "skill top: IMPL-matches-RED_FAIL-per-step rule stated" \
  || bad "skill top: per-step gate matching not stated"

# ── 2) agentSpawn primer: arming + per-step contract reach EVERY session ────
grep -q -- "--tdd-begin" "$PRIMER" \
  && ok "primer: names the --tdd-begin arming command" \
  || bad "primer: --tdd-begin missing"

grep -q -- "--step" "$PRIMER" \
  && ok "primer: names the per-marker --step requirement" \
  || bad "primer: --step missing"

# ── 3) steering cheat sheet: the per-step rule is explicit, not a comment ──
grep -qi "REQUIRED on every marker" "$STEER" \
  && ok "steering: explicit --step REQUIRED rule present" \
  || bad "steering: per-step rule still implicit"

# ── 4) B5 eval prompt NEUTRAL: plugin carries the protocol, not the eval ───
grep -q "TDD protocol STRICTLY" "$PFOO" \
  && ok "B5 prompt: still demands strict TDD protocol" \
  || bad "B5 prompt: strict-protocol demand missing"

for TOKEN in -- "--tdd-begin" "--phase" "--step" "zensu-log.sh"; do
  [ "$TOKEN" = "--" ] && continue
  grep -q -- "$TOKEN" "$PFOO" \
    && bad "B5 prompt: still hand-holds the protocol ($TOKEN found)" \
    || ok "B5 prompt: neutral ($TOKEN absent)"
done

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
