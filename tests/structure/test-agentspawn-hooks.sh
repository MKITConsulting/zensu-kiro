#!/usr/bin/env bash
# S09 — agentSpawn hooks through the shim (Kiro fires them on agent activation).
# banner: user-facing, must report the version from the repo VERSION file and
#         advertise /zensu-x slash skills (no Codex $zensu-x syntax).
# primer: model-facing additionalContext -> plain stdout via shim, /zensu-x names.
# pulse:  must persist the plugin root to ~/.zensu/plugin-root (skills depend on it).
# capture-sid: must cache the payload session_id under <cwd>/.zensu/state/.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
unset CLAUDE_PROJECT_DIR 2>/dev/null || true
mkdir -p "$TMP/home"
export HOME="$TMP/home"
SHIM="$ROOT/hooks/kiro/kiro-shim.sh"
VERSION="$(cat "$ROOT/VERSION")"
SID="s09-spawn"

payload() { printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$TMP"; }
run_hook() { printf '%s' "$(payload)" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" "$1" 2>/dev/null; }

# 1) banner
OUT="$(run_hook session-start-banner.sh)"
printf '%s' "$OUT" | grep -q "Zensu PLM v${VERSION}" && ok "banner reports v${VERSION} from VERSION file" || bad "banner version wrong: '$(printf '%s' "$OUT" | head -1)'"
printf '%s' "$OUT" | grep -q "/zensu-tdd" && ok "banner advertises /zensu-tdd" || bad "banner lacks /zensu-tdd"
printf '%s' "$OUT" | grep -q '\$zensu-' && bad "banner still uses Codex \$zensu- syntax" || ok "banner free of \$zensu- syntax"

# 2) primer (additionalContext unwrapped by shim)
OUT="$(run_hook session-start-primer.sh)"
printf '%s' "$OUT" | grep -q "Zensu PLM plugin is active" && ok "primer emits orientation" || bad "primer silent"
printf '%s' "$OUT" | grep -q "hookSpecificOutput" && bad "primer output still JSON-wrapped" || ok "primer output unwrapped"
printf '%s' "$OUT" | grep -q "/zensu-tdd" && ok "primer names /zensu-tdd" || bad "primer lacks /zensu-tdd"
printf '%s' "$OUT" | grep -q '\$zensu-' && bad "primer still uses Codex \$zensu- syntax" || ok "primer free of \$zensu- syntax"

# 3) pulse persists plugin-root
run_hook session-start-pulse.sh >/dev/null
[ -f "$HOME/.zensu/plugin-root" ] && ok "plugin-root written" || bad "plugin-root missing"
[ "$(cat "$HOME/.zensu/plugin-root" 2>/dev/null)" = "$ROOT" ] && ok "plugin-root points at repo root" || bad "plugin-root content: $(cat "$HOME/.zensu/plugin-root" 2>/dev/null)"

# 4) capture-sid caches the session id under <cwd>/.zensu/state/
run_hook session-start-capture-sid.sh >/dev/null
grep -rq "$SID" "$TMP/.zensu/state" 2>/dev/null && ok "session id cached" || bad "session id cache missing"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
