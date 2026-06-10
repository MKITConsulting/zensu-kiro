#!/usr/bin/env bash
# S17 — the version invariant (lesson from upstream's marketplace.json drift):
# VERSION == POWER.md metadata.version == README badge == newest CHANGELOG
# heading, all in the same commit. Machine-enforced here, used by release.yml.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

V="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null)"
printf '%s' "$V" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' && ok "VERSION is semver ($V)" || bad "VERSION malformed: '$V'"

PV="$(awk '/^---$/{c++; next} c==1 && /^  version:/{sub(/^  version:[[:space:]]*/,""); print; exit}' "$ROOT/POWER.md" 2>/dev/null)"
[ "$PV" = "$V" ] && ok "POWER.md metadata.version == VERSION" || bad "POWER.md version '$PV' != '$V'"

if [ -f "$ROOT/README.md" ]; then
  grep -qE "badge/version-$V-" "$ROOT/README.md" && ok "README badge carries $V" || bad "README badge does not carry $V"
else
  bad "README.md missing"
fi

if [ -f "$ROOT/CHANGELOG.md" ]; then
  CL="$(grep -m1 -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' "$ROOT/CHANGELOG.md" | tr -d '#[] ')"
  [ "$CL" = "$V" ] && ok "newest CHANGELOG heading == $V" || bad "CHANGELOG newest '$CL' != '$V'"
else
  bad "CHANGELOG.md missing"
fi

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
