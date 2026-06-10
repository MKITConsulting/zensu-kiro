#!/bin/bash
set -u

: "${CLAUDE_PLUGIN_ROOT:=${ZENSU_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}}}"

if [ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh" ]; then
  source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-session.sh"
else
  exit 0
fi

PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "$PAYLOAD" ] && exit 0

command -v node >/dev/null 2>&1 || exit 0

source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/zensu-runtime.sh" 2>/dev/null || true
zensu_runtime_apply_project_dir "$PAYLOAD" 2>/dev/null || true

SID="$(PAYLOAD="$PAYLOAD" node -e '
  try {
    const j = JSON.parse(process.env.PAYLOAD || "{}");
    process.stdout.write((typeof j.session_id === "string" && j.session_id) ? j.session_id : "");
  } catch (_) {}
' 2>/dev/null)"

# Kiro hook payloads carry NO session_id (live-verified: agentSpawn keys are
# hook_event_name/cwd/prompt). Synthesize a stable per-spawn id so the
# current-session file still anchors hooks and model-shell zensu-log calls to
# one state file for this session.
if [ -z "$SID" ]; then
  SID="kiro-$(date +%s)-$$"
fi

CACHE_DIR="${CLAUDE_PROJECT_DIR:-.}/.zensu/state"
mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0
KEY="$(zensu_session_key)"
TARGET="$CACHE_DIR/session-id-${KEY}.txt"
TMP="$(mktemp "$CACHE_DIR/session-id-${KEY}.XXXXXX" 2>/dev/null)" || exit 0
if printf '%s\n' "$SID" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$TARGET" 2>/dev/null || rm -f "$TMP" 2>/dev/null
else
  rm -f "$TMP" 2>/dev/null
fi

# Kiro: shell-tool processes carry no session env and a different ancestry
# than this hook, so the keyed cache above never matches a model-run
# `zensu-log.sh` call. Persist the id additionally as the project-scoped
# "current session" file, which zensu_resolve_session_id consults as its
# last step before the PPID fallback.
CUR="$CACHE_DIR/session-id-current.txt"
TMP="$(mktemp "$CACHE_DIR/session-id-current.XXXXXX" 2>/dev/null)" || exit 0
if printf '%s\n' "$SID" > "$TMP" 2>/dev/null; then
  mv "$TMP" "$CUR" 2>/dev/null || rm -f "$TMP" 2>/dev/null
else
  rm -f "$TMP" 2>/dev/null
fi
exit 0
