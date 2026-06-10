#!/usr/bin/env bash
# S05 — the Zensu MCP write-gate must recognize Kiro CLI MCP tool-name formats.
# Kiro exposes MCP tools as @server/tool (matcher form); hook payloads may carry
# "@zensu/create_feature", "zensu___create_feature", or the legacy Claude name
# "mcp__plugin_zensu_zensu__create_feature". After prefix-stripping, the gate
# reuses hooks/lib/zensu-mcp-tools.sh verbatim: read tools pass, mutation tools
# are denied unless a skill opened a workflow window (--workflow-begin --tools).
# Through kiro-shim.sh a deny becomes exit 2 + stderr.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TDD_STATE_DIR="$TMP/state"
unset CLAUDE_PROJECT_DIR 2>/dev/null || true
mkdir -p "$TMP/home/.zensu" "$TDD_STATE_DIR"
export HOME="$TMP/home"   # isolate ~/.zensu/config.json lookups
SID="s05-mcp-gate"
LOG="$ROOT/hooks/lib/zensu-log.sh"
GATE="$ROOT/hooks/pre-mcp-zensu-gate.sh"

mk_mcp() { # $1=tool_name
  printf '{"tool_name":"%s","session_id":"%s","cwd":"%s","tool_input":{"name":"X"}}' "$1" "$SID" "$TMP"
}
run_gate() { local out; out="$(printf '%s' "$(mk_mcp "$1")" | ZENSU_PLUGIN_ROOT="$ROOT" bash "$GATE" 2>/dev/null)"; case "$out" in *'permissionDecision":"deny"'*) echo DENY ;; *) echo ALLOW ;; esac; }
expect() { if [ "$2" = "$3" ]; then ok "$1 -> $3"; else bad "$1 -> got $3, expected $2"; fi; }

# 1) mutation tool denied in every Kiro/legacy name form (no workflow window)
expect "@zensu/create_feature"                      DENY  "$(run_gate "@zensu/create_feature")"
expect "zensu___create_feature"                     DENY  "$(run_gate "zensu___create_feature")"
expect "mcp__plugin_zensu_zensu__create_feature"    DENY  "$(run_gate "mcp__plugin_zensu_zensu__create_feature")"

# 2) read tools always pass
expect "@zensu/get_feature"                         ALLOW "$(run_gate "@zensu/get_feature")"
expect "@zensu/list_features"                       ALLOW "$(run_gate "@zensu/list_features")"
expect "@zensu/suggest_workflow"                    ALLOW "$(run_gate "@zensu/suggest_workflow")"

# 3) non-zensu tools are not the gate's business
expect "@git/status"                                ALLOW "$(run_gate "@git/status")"

# 4) workflow window: skill marker opens a scoped bypass, --workflow-end closes it
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --workflow-begin --tools "create_feature,update_feature" --session "$SID" >/dev/null 2>&1
expect "workflow open: @zensu/create_feature"       ALLOW "$(run_gate "@zensu/create_feature")"
expect "workflow open: @zensu/delete_roadmap (unlisted)" DENY "$(run_gate "@zensu/delete_roadmap")"
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --workflow-end --session "$SID" >/dev/null 2>&1
expect "workflow closed: @zensu/create_feature"     DENY  "$(run_gate "@zensu/create_feature")"

# 5) env escape hatch
out="$(printf '%s' "$(mk_mcp "@zensu/create_feature")" | ZENSU_PLUGIN_ROOT="$ROOT" ZENSU_MCP_GATE=off bash "$GATE" 2>/dev/null)"
case "$out" in *'permissionDecision":"deny"'*) bad "ZENSU_MCP_GATE=off -> DENY" ;; *) ok "ZENSU_MCP_GATE=off -> ALLOW" ;; esac

# 6) through the shim: deny -> exit 2 + stderr
printf '%s' "$(mk_mcp "@zensu/create_feature")" | env -u ZENSU_PLUGIN_ROOT bash "$ROOT/hooks/kiro/kiro-shim.sh" pre-mcp-zensu-gate.sh >"$TMP/o" 2>"$TMP/e"
RC=$?
[ "$RC" -eq 2 ] && ok "shim deny exit 2" || bad "shim deny: got rc $RC, expected 2"
grep -qi "zensu" "$TMP/e" && ok "shim deny reason on stderr" || bad "shim stderr empty"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
