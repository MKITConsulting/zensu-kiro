#!/usr/bin/env bash
# S13 — every JSON artifact must parse: CLI agent templates (after substituting
# the __ZENSU_HOME__ placeholder) and config.example.json.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

for f in "$ROOT/config.example.json"; do
  if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$f" 2>/dev/null; then
    ok "$(basename "$f") parses"
  else
    bad "$(basename "$f") invalid JSON"
  fi
done

FOUND=0
for f in "$ROOT"/agents/cli/*.json; do
  [ -f "$f" ] || continue
  FOUND=1
  if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8").replace(/__ZENSU_HOME__/g,"/tmp/zensu-home"))' "$f" 2>/dev/null; then
    ok "agents/cli/$(basename "$f") parses (substituted)"
  else
    bad "agents/cli/$(basename "$f") invalid JSON"
  fi
done
[ "$FOUND" -eq 1 ] || bad "no agents/cli/*.json present"

# mcp.json is retired (CLI re-home) — assert it is gone, not present.
[ ! -f "$ROOT/mcp.json" ] && ok "mcp.json retired (CLI re-home)" || bad "mcp.json still present after CLI re-home"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
