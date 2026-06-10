#!/usr/bin/env bash
# S17 — English-only repository guard (org convention): no German text in any
# tracked file. Checks umlauts/sharp-s and a high-signal German word list.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

cd "$ROOT"
# Exemptions: this guard itself (its detection word list IS German), and the
# TDD reminder hook, which mirrors upstream's multilingual user-preference
# detection tokens ('mit tdd', 'kein tdd', 'tdd bitte', ...) verbatim.
FILES="$(git ls-files --cached --others --exclude-standard 2>/dev/null | grep -v -e '^tests/structure/test-english-only\.sh$' -e '^hooks/user-prompt-tdd-reminder\.sh$')"
[ -n "$FILES" ] || { echo "not a git repo / no tracked files"; exit 1; }

UML="$(printf '%s\n' "$FILES" | xargs grep -ln $'\xc3\xa4\|\xc3\xb6\|\xc3\xbc\|\xc3\x84\|\xc3\x96\|\xc3\x9c\|\xc3\x9f' 2>/dev/null || true)"
[ -z "$UML" ] && ok "no umlauts/sharp-s in tracked files" || { bad "umlauts found in:"; printf '%s\n' "$UML" | head -5; }

WORDS='\b(und|oder|nicht|eine[mnr]?|zuerst|bitte|danke|wird|werden|sollte|funktioniert|Fehler|Datei|Verzeichnis)\b'
HITS="$(printf '%s\n' "$FILES" | xargs grep -lnE "$WORDS" 2>/dev/null || true)"
[ -z "$HITS" ] && ok "no German word-list hits in tracked files" || { bad "German words found in:"; printf '%s\n' "$HITS" | head -5; }

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
