#!/usr/bin/env bash
# S13 — agent bodies are deduplicated: agents/prompts/*.md is canonical, the IDE
# subagent files (agents/ide/*.md, YAML frontmatter + body) must carry an
# IDENTICAL body, and every CLI agent JSON prompt must reference an existing
# prompts file via file://__ZENSU_HOME__/prompts/<name>.md.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

for n in zensu-plm zensu-code-reviewer zensu-review-aspect; do
  IDE="$ROOT/agents/ide/$n.md"
  PR="$ROOT/agents/prompts/$n.md"
  [ -f "$PR" ] || { bad "$n: prompts file missing"; continue; }
  [ -f "$IDE" ] || { bad "$n: ide file missing"; continue; }
  BODY_IDE="$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2 {print}' "$IDE")"
  BODY_PR="$(cat "$PR")"
  if [ "$(printf '%s' "$BODY_IDE" | shasum | cut -d' ' -f1)" = "$(printf '%s' "$BODY_PR" | shasum | cut -d' ' -f1)" ]; then
    ok "$n: ide body == prompts body"
  else
    bad "$n: ide body diverges from prompts body"
  fi
  head -1 "$IDE" | grep -q '^---$' && ok "$n: ide frontmatter present" || bad "$n: ide frontmatter missing"
  awk 'BEGIN{c=0} /^---$/{c++; next} c==1{print}' "$IDE" | grep -q "^name: $n$" && ok "$n: ide frontmatter name" || bad "$n: ide frontmatter name wrong"
done

for f in "$ROOT"/agents/cli/*.json; do
  [ -f "$f" ] || { bad "no CLI agent JSONs"; break; }
  P="$(grep -o 'file://__ZENSU_HOME__/prompts/[a-z-]*\.md' "$f" | head -1)"
  if [ -n "$P" ]; then
    REL="${P#file://__ZENSU_HOME__/}"
    [ -f "$ROOT/agents/$REL" ] && ok "$(basename "$f"): prompt target exists (agents/$REL)" || bad "$(basename "$f"): prompt target missing (agents/$REL)"
  else
    bad "$(basename "$f"): no file://__ZENSU_HOME__/prompts/ reference"
  fi
done

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
