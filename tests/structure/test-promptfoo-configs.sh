#!/usr/bin/env bash
# S16 — the promptfoo live-eval layer must be wired without spending credits
# (no kiro-cli, no network; the toy-app smoke runs plain `node --test`):
# both suites exist, every file:// reference they make resolves, the custom
# provider module loads and identifies itself, the file-side-effect asserts
# are valid ESM, the runner is syntax-clean, and the toy-app fixture is a
# runnable node project (src/ + test/).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PF="$ROOT/tests/promptfoo"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

for f in "$PF/diagnostics.yaml" "$PF/promptfooconfig.yaml"; do
  [ -f "$f" ] && ok "$(basename "$f") exists" || { bad "$(basename "$f") missing"; continue; }
  for key in prompts: providers: tests:; do
    grep -q "^$key" "$f" && ok "$(basename "$f") has top-level $key" || bad "$(basename "$f") missing top-level $key"
  done
  # every file:// reference must resolve relative to tests/promptfoo/
  while IFS= read -r ref; do
    rel="${ref#file://}"
    [ -e "$PF/$rel" ] && ok "$(basename "$f"): $rel resolves" || bad "$(basename "$f"): $rel MISSING"
  done < <(grep -oE 'file://[A-Za-z0-9_./-]+' "$f" | sed 's|file://\./|file://|' | sort -u)
done

# provider loads and identifies itself (no kiro-cli needed for module load)
if [ -f "$PF/providers/kiro-cli.mjs" ]; then
  ID="$(node -e '
    const { pathToFileURL } = require("url");
    import(pathToFileURL(process.argv[1]).href).then(m => {
      const P = m.default;
      const p = new P({ id: "kiro-cli", config: {} });
      console.log(p.id());
    }).catch(e => { console.error(e.message); process.exit(1); });
  ' "$PF/providers/kiro-cli.mjs" 2>/dev/null)"
  [ "$ID" = "kiro-cli" ] && ok "provider loads, id()=kiro-cli" || bad "provider id wrong: '$ID'"
else
  bad "providers/kiro-cli.mjs missing"
fi

FOUND=0
for a in "$PF"/asserts/*.mjs; do
  [ -f "$a" ] || continue
  FOUND=1
  node --check "$a" 2>/dev/null && ok "assert $(basename "$a") parses" || bad "assert $(basename "$a") syntax error"
done
[ "$FOUND" -eq 1 ] || bad "no asserts/*.mjs present"

for s in "$PF"/scenarios/*/setup.sh; do
  [ -f "$s" ] || continue
  bash -n "$s" 2>/dev/null && ok "scenario $(basename "$(dirname "$s")")/setup.sh parses" || bad "scenario $s syntax error"
done

[ -f "$ROOT/tests/run-promptfoo.sh" ] && bash -n "$ROOT/tests/run-promptfoo.sh" && ok "run-promptfoo.sh parses" || bad "run-promptfoo.sh missing/broken"

# toy-app fixture: minimal node project with a runnable test
T="$PF/scenarios/fixtures/toy-app"
[ -f "$T/src/calc.js" ] && ok "toy-app src present" || bad "toy-app src missing"
[ -f "$T/test/calc.test.js" ] && ok "toy-app test present" || bad "toy-app test missing"
if [ -f "$T/package.json" ]; then
  ( cd "$T" && npm test --silent >/dev/null 2>&1 ) && ok "toy-app npm test runs green" || bad "toy-app npm test fails"
else
  bad "toy-app package.json missing"
fi

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
