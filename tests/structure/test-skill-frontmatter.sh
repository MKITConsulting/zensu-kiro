#!/usr/bin/env bash
# S11 — Agent Skills standard compliance for all zensu skills.
# Kiro loads .kiro/skills/<name>/SKILL.md where frontmatter `name` MUST equal
# the folder name (lowercase letters, digits, hyphens; max 64 chars) and
# `description` (max 1024 chars) drives auto-activation. Skills surface as
# /<name> slash commands, so no skill body may reference the Claude Code
# `/zensu:x` invocation syntax.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

EXPECTED="zensu-bootstrap zensu-ghost-scan zensu-implement zensu-tdd zensu-plan-review zensu-pr-team-review zensu-security-review zensu-self-review zensu-reset-review-limit zensu-pulse zensu-help"

for name in $EXPECTED; do
  F="$ROOT/skills/$name/SKILL.md"
  if [ ! -f "$F" ]; then bad "$name: SKILL.md missing"; continue; fi

  FM_NAME="$(awk '/^---$/{c++; next} c==1 && /^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$F")"
  [ "$FM_NAME" = "$name" ] && ok "$name: frontmatter name matches folder" || bad "$name: frontmatter name '$FM_NAME' != folder"

  printf '%s' "$FM_NAME" | grep -qE '^[a-z0-9-]{1,64}$' && ok "$name: name charset/length valid" || bad "$name: name violates ^[a-z0-9-]{1,64}\$"

  DESC="$(awk '/^---$/{c++; next} c==1 && /^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$F")"
  [ -n "$DESC" ] && ok "$name: description present" || bad "$name: description missing"
  [ "${#DESC}" -le 1024 ] && ok "$name: description <= 1024 chars (${#DESC})" || bad "$name: description too long (${#DESC})"
done

# No Claude Code invocation syntax anywhere in skill bodies.
if [ -d "$ROOT/skills" ]; then
  HITS="$(grep -rn "/zensu:" "$ROOT/skills" 2>/dev/null || true)"
  [ -z "$HITS" ] && ok "no /zensu: Claude-isms in skills/" || { bad "Claude-isms found:"; printf '%s\n' "$HITS" | head -5; }
else
  bad "skills/ directory missing"
fi

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
