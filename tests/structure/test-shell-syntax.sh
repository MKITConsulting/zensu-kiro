#!/usr/bin/env bash
# S17 — every shell script must parse (bash -n) and every ESM module must pass
# node --check; executables must carry the +x bit.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  if bash -n "$f" 2>/dev/null; then ok "bash -n $rel"; else bad "bash -n $rel"; fi
done < <(find "$ROOT/hooks" "$ROOT/tests" -name '*.sh' -type f 2>/dev/null; printf '%s\n' "$ROOT/install.sh")

while IFS= read -r f; do
  rel="${f#"$ROOT"/}"
  if node --check "$f" 2>/dev/null; then ok "node --check $rel"; else bad "node --check $rel"; fi
done < <(find "$ROOT/tests/promptfoo" -name '*.mjs' -type f 2>/dev/null; find "$ROOT/hooks" -name '*.js' -type f 2>/dev/null)

for f in "$ROOT/install.sh" "$ROOT/hooks/kiro/kiro-shim.sh" "$ROOT/tests/run-all.sh" "$ROOT/tests/run-promptfoo.sh"; do
  rel="${f#"$ROOT"/}"
  [ -x "$f" ] && ok "executable: $rel" || bad "not executable: $rel"
done

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
