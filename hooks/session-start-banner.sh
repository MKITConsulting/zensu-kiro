#!/bin/bash
# agentSpawn hook — user-facing "Zensu is active" banner + usage hints.
# Plain stdout. Fires on agent activation; Kiro payloads carry no source field,
# so resume/compact suppression only applies on hosts that send one. Gated by
# hooks.sessionBanner (default on). Companion: session-start-primer.sh
# (model-facing orientation via additionalContext).
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"
source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-config.sh"
zensu_hook_enabled sessionBanner || exit 0

# Only on fresh starts. Skip resume/compact. Missing source -> treat as startup.
SOURCE=""
if command -v node >/dev/null 2>&1; then
  SOURCE="$(node -e '
    let s=""; process.stdin.on("data",c=>s+=c);
    process.stdin.on("end",()=>{ try { const j=JSON.parse(s||"{}");
      process.stdout.write(typeof j.source==="string"?j.source:""); } catch(_){ process.stdout.write(""); } });
  ' 2>/dev/null)"
fi
case "$SOURCE" in
  resume|compact) exit 0 ;;
esac

VERSION="?"
V="$(cat "${CLAUDE_PLUGIN_ROOT}/VERSION" 2>/dev/null | tr -d '[:space:]')"
[ -n "$V" ] && VERSION="$V"

echo "zensu: Zensu PLM v${VERSION} active — features as first-class citizens."
echo "zensu: Flow — track features → implement (strict RED→GREEN TDD) → review chain → dashboard."
echo "zensu: Tip — plan code changes first; before implementing, ask whether to run the /zensu-tdd workflow (RED→GREEN + review chain). Run it and edits are TDD-gate-enforced; decline and you implement directly."
echo "zensu: Skills — /zensu-bootstrap · /zensu-ghost-scan · /zensu-implement · /zensu-tdd · /zensu-security-review · /zensu-pulse · /zensu-help (Q&A)."
echo "zensu: Hide this banner: set hooks.sessionBanner=false in ~/.zensu/config.json."
exit 0
