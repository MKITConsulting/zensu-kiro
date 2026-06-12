#!/usr/bin/env bash
# F13 — the core conventions are mirrored on three surfaces (canonical:
# steering/zensu-conventions.md; mirrors: agents/prompts/zensu-orchestrator.md
# and POWER.md's steering section, per AGENTS.md). Pin the load-bearing phrases
# on ALL three so semantic drift between the IDE's advisory tier and the CLI's
# enforced tier fails the gate instead of going unnoticed.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

SURFACES="steering/zensu-conventions.md agents/prompts/zensu-orchestrator.md POWER.md"

# Load-bearing phrase 1: ask-about-TDD before code edits
for f in $SURFACES; do
  grep -qi "ask" "$ROOT/$f" && grep -q "/zensu-tdd" "$ROOT/$f" \
    && ok "$f: ask-about-TDD rule present (/zensu-tdd named)" \
    || bad "$f: ask-about-TDD rule missing or /zensu-tdd not named"
done

# Load-bearing phrase 2: KEY-N commit references
for f in $SURFACES; do
  grep -q "KEY-N" "$ROOT/$f" \
    && ok "$f: KEY-N commit-reference rule present" \
    || bad "$f: KEY-N commit-reference rule missing"
done

# Load-bearing phrase 3: route Zensu MCP work through zensu-plm / skills
for f in $SURFACES; do
  grep -q "zensu-plm" "$ROOT/$f" \
    && ok "$f: zensu-plm routing rule present" \
    || bad "$f: zensu-plm routing rule missing"
done

# Load-bearing phrase 4: review chain must run to completion
for f in $SURFACES; do
  grep -qiE "review chain|zensu-code-reviewer" "$ROOT/$f" \
    && ok "$f: review-chain rule present" \
    || bad "$f: review-chain rule missing"
done

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
