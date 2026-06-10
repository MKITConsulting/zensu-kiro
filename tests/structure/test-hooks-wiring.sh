#!/usr/bin/env bash
# S13 — hook wiring lives inside the Kiro agent configs (replacing Claude Code's
# hooks/hooks.json). agents/cli/zensu.json is the default orchestrator carrying
# ALL hooks; agents/cli/zensu-plm.json carries NO @zensu write-gate hook (the
# per-agent replacement for upstream's agent_type exemption). Templates use the
# __ZENSU_HOME__ placeholder that install.sh renders to an absolute path.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

Z="$ROOT/agents/cli/zensu.json"
[ -f "$Z" ] || { bad "agents/cli/zensu.json missing"; printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

# Validate via node after substituting the placeholder.
CHECK="$(ZJSON="$Z" ROOT="$ROOT" node -e '
  const fs = require("fs");
  const raw = fs.readFileSync(process.env.ZJSON, "utf8").replace(/__ZENSU_HOME__/g, "/tmp/zensu-home");
  let j;
  try { j = JSON.parse(raw); } catch (e) { console.log("PARSE_FAIL " + e.message); process.exit(0); }
  const out = [];
  const hooks = j.hooks || {};
  const events = ["agentSpawn","userPromptSubmit","preToolUse","postToolUse","stop"];
  out.push("events " + events.every(e => Array.isArray(hooks[e]) && hooks[e].length > 0));
  const all = [].concat(...events.map(e => hooks[e] || []));
  out.push("shimmed " + all.every(h => typeof h.command === "string" && /__ZENSU_HOME__\/hooks\/kiro\/kiro-shim\.sh [a-z0-9-]+\.sh$/.test(fs.readFileSync(process.env.ZJSON,"utf8").match(new RegExp(h.command.replace(/[.*+?^${}()|[\]\\]/g,"\\$&"))) ? h.command.replace("/tmp/zensu-home","__ZENSU_HOME__") : h.command)));
  const scripts = all.map(h => (h.command.match(/kiro-shim\.sh ([a-z0-9-]+\.sh)/) || [])[1]).filter(Boolean);
  out.push("scripts " + JSON.stringify([...new Set(scripts)]));
  const pre = (hooks.preToolUse || []).map(h => h.matcher || "");
  out.push("pre_write " + (pre.includes("write") && pre.includes("fs_write")));
  out.push("pre_zensu " + pre.includes("@zensu"));
  const post = (hooks.postToolUse || []).map(h => h.matcher || "");
  out.push("post_shell " + (post.includes("shell") && post.includes("execute_bash")));
  out.push("post_subagent " + post.includes("subagent"));
  out.push("no_cache " + !JSON.stringify(hooks).includes("cache_ttl_seconds"));
  out.push("prompt " + (typeof j.prompt === "string" && j.prompt.includes("zensu-orchestrator.md")));
  out.push("skills " + (Array.isArray(j.resources) && j.resources.some(r => typeof r === "string" && r.startsWith("skill://"))));
  out.push("subagents " + ((((j.toolsSettings||{}).subagent||{}).availableAgents||[]).join(",")));
  out.push("mcpjson " + (j.includeMcpJson === true));
  console.log(out.join("\n"));
' 2>&1)"

case "$CHECK" in PARSE_FAIL*) bad "zensu.json parse: $CHECK" ;; *) ok "zensu.json parses (with substitution)" ;; esac
printf '%s' "$CHECK" | grep -q "^events true" && ok "all 5 hook events wired" || bad "missing hook events"
printf '%s' "$CHECK" | grep -q "^pre_write true" && ok "preToolUse covers write + fs_write" || bad "preToolUse write matchers missing"
printf '%s' "$CHECK" | grep -q "^pre_zensu true" && ok "preToolUse covers @zensu (MCP gate)" || bad "preToolUse @zensu matcher missing"
printf '%s' "$CHECK" | grep -q "^post_shell true" && ok "postToolUse covers shell + execute_bash (witness)" || bad "postToolUse shell matchers missing"
printf '%s' "$CHECK" | grep -q "^post_subagent true" && ok "postToolUse covers subagent (review delegate)" || bad "postToolUse subagent matcher missing"
printf '%s' "$CHECK" | grep -q "^no_cache true" && ok "no cache_ttl_seconds on any hook" || bad "cache_ttl_seconds found (stale gate decisions!)"
printf '%s' "$CHECK" | grep -q "^prompt true" && ok "prompt points at zensu-orchestrator.md" || bad "prompt wiring wrong"
printf '%s' "$CHECK" | grep -q "^skills true" && ok "skill:// resources present" || bad "skill:// resources missing"
printf '%s' "$CHECK" | grep -q "^subagents .*zensu-plm" && ok "subagent allowlist includes zensu-plm" || bad "subagent allowlist incomplete"
printf '%s' "$CHECK" | grep -q "^subagents .*zensu-code-reviewer" && ok "subagent allowlist includes zensu-code-reviewer" || bad "allowlist lacks code-reviewer"
printf '%s' "$CHECK" | grep -q "^subagents .*zensu-review-aspect" && ok "subagent allowlist includes zensu-review-aspect" || bad "allowlist lacks review-aspect"
printf '%s' "$CHECK" | grep -q "^mcpjson true" && ok "includeMcpJson enabled" || bad "includeMcpJson not true"

# every wired script exists
for s in $(printf '%s' "$CHECK" | sed -n 's/^scripts \[\(.*\)\]$/\1/p' | tr -d '"' | tr ',' ' '); do
  [ -f "$ROOT/hooks/$s" ] && ok "wired script exists: $s" || bad "wired script missing: $s"
done

# zensu-plm.json: NO @zensu gate hook, but @zensu tools available
P="$ROOT/agents/cli/zensu-plm.json"
if [ -f "$P" ]; then
  PCHK="$(PJSON="$P" node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.env.PJSON,"utf8").replace(/__ZENSU_HOME__/g,"/tmp/x"));
    const pre = ((j.hooks||{}).preToolUse||[]).map(h=>h.matcher||"");
    console.log("plm_nogate " + !pre.includes("@zensu"));
    console.log("plm_tools " + JSON.stringify(j.tools||[]));
  ' 2>&1)"
  printf '%s' "$PCHK" | grep -q "^plm_nogate true" && ok "zensu-plm has NO @zensu gate hook (per-agent exemption)" || bad "zensu-plm wrongly carries the MCP gate"
  printf '%s' "$PCHK" | grep -q '@zensu' && ok "zensu-plm has @zensu tools" || bad "zensu-plm lacks @zensu tools"
else
  bad "agents/cli/zensu-plm.json missing"
fi

# reviewer agents: read-only (no write/shell-free as designed: no write tool)
for a in zensu-code-reviewer zensu-review-aspect; do
  F="$ROOT/agents/cli/$a.json"
  if [ -f "$F" ]; then
    W="$(AJSON="$F" node -e 'const j=JSON.parse(require("fs").readFileSync(process.env.AJSON,"utf8").replace(/__ZENSU_HOME__/g,"/tmp/x"));console.log(JSON.stringify(j.tools||[]))' 2>/dev/null)"
    printf '%s' "$W" | grep -qE '"(write|fs_write)"' && bad "$a grants write tool (must be read-only)" || ok "$a is read-only (no write tool)"
  else
    bad "agents/cli/$a.json missing"
  fi
done

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
