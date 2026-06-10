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

# install.ps1 correctness is not executable on this runner; pin the two
# Windows-specific fixes literally: the ProgramFiles(x86) env var needs the
# brace form, and WSL's System32 bash must be excluded from candidates.
if grep -q 'env:ProgramFiles(x86)}' "$ROOT/install.ps1"; then
  ok "install.ps1 uses \${env:ProgramFiles(x86)} brace form"
else
  bad "install.ps1 ProgramFiles(x86) interpolation broken (expands as \$env:ProgramFiles + literal)"
fi
if grep -q "notmatch '..Windows..(System32|Sysnative)" "$ROOT/install.ps1"; then
  ok "install.ps1 functionally excludes WSL System32/Sysnative bash (-notmatch filter present)"
else
  bad "install.ps1 lacks the functional -notmatch System32/Sysnative filter (comments do not count)"
fi

# bash 3.2 (stock macOS): expanding an EMPTY array under set -u aborts with
# "unbound variable" — every array expansion in entry scripts must use the
# ${arr[@]+"${arr[@]}"} guard form.
if grep -q 'FILTER_ARGS\[@\]+' "$ROOT/tests/run-promptfoo.sh"; then
  ok "run-promptfoo.sh guards empty-array expansion (bash 3.2 safe)"
else
  bad "run-promptfoo.sh expands FILTER_ARGS unguarded (aborts on macOS bash 3.2 when no filters apply)"
fi

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
