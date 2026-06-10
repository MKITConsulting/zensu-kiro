#!/usr/bin/env bash
# S14 — install.sh contract, exercised in a sandbox HOME (the user's real
# ~/.kiro and ~/.zensu are never touched):
#   fresh install   -> runtime home ~/.kiro/zensu (hooks, prompts, VERSION,
#                      manifest.json with sha256 per file), skills, agents
#                      (rendered: zero __ZENSU_HOME__ leftovers), mcp.json merge
#                      preserving pre-existing servers, ~/.zensu/plugin-root
#   idempotency     -> second run changes nothing (all NOOP)
#   user edits      -> a user-modified installed file is SKIPped, not stomped
#   --dry-run       -> writes nothing
#   --uninstall     -> removes only manifest-listed unmodified files + our mcp
#                      entry; keeps foreign mcp servers and user data
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.kiro/settings"
# pre-existing foreign MCP server must survive install + uninstall
printf '{"mcpServers":{"other":{"url":"https://example.com/mcp"}}}\n' > "$HOME/.kiro/settings/mcp.json"

INSTALL="$ROOT/install.sh"
[ -f "$INSTALL" ] || { bad "install.sh missing"; printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

# 1) --dry-run writes nothing
bash "$INSTALL" --scope user --no-default --dry-run >/dev/null 2>&1
[ -d "$HOME/.kiro/zensu" ] && bad "dry-run created runtime home" || ok "dry-run writes nothing"

# 2) fresh install
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "install exits 0" || { bad "install rc=$RC"; printf '%s\n' "$OUT" | tail -5; }
[ -f "$HOME/.kiro/zensu/hooks/kiro/kiro-shim.sh" ] && ok "runtime home has kiro-shim" || bad "kiro-shim not installed"
[ -f "$HOME/.kiro/zensu/hooks/lib/zensu-log.sh" ] && ok "runtime home has libs" || bad "libs not installed"
[ -f "$HOME/.kiro/zensu/prompts/zensu-orchestrator.md" ] && ok "prompts installed" || bad "prompts missing"
[ -f "$HOME/.kiro/zensu/VERSION" ] && ok "VERSION installed" || bad "VERSION missing"
[ -f "$HOME/.kiro/zensu/manifest.json" ] && ok "manifest written" || bad "manifest missing"
[ -f "$HOME/.kiro/skills/zensu-tdd/SKILL.md" ] && ok "skills installed" || bad "skills missing"
[ -f "$HOME/.kiro/agents/zensu.json" ] && ok "CLI agents installed" || bad "CLI agents missing"
[ -f "$HOME/.kiro/agents/zensu-plm.md" ] && ok "IDE agents installed" || bad "IDE agents missing"
grep -r "__ZENSU_HOME__" "$HOME/.kiro/agents" >/dev/null 2>&1 && bad "__ZENSU_HOME__ leftovers in agents" || ok "placeholder fully rendered"
grep -q "$HOME/.kiro/zensu/hooks/kiro/kiro-shim.sh" "$HOME/.kiro/agents/zensu.json" && ok "hook commands point at runtime home" || bad "hook command paths wrong"
[ "$(cat "$HOME/.zensu/plugin-root" 2>/dev/null)" = "$HOME/.kiro/zensu" ] && ok "plugin-root written" || bad "plugin-root wrong: $(cat "$HOME/.zensu/plugin-root" 2>/dev/null)"
[ -f "$HOME/.zensu/config.json" ] && ok "config seeded" || bad "config not seeded"

# mcp merge: zensu added, foreign server kept
MCP_OK="$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const z = j.mcpServers && j.mcpServers.zensu, o = j.mcpServers && j.mcpServers.other;
  console.log(z && z.url === "https://mcp.zensu.dev/mcp" && o && o.url === "https://example.com/mcp" ? "yes" : "no");
' "$HOME/.kiro/settings/mcp.json" 2>/dev/null)"
[ "$MCP_OK" = "yes" ] && ok "mcp.json merged (zensu added, foreign kept)" || bad "mcp merge wrong"

# 3) idempotency: re-run -> nothing changes (mtimes stable)
M1="$(stat -f %m "$HOME/.kiro/agents/zensu.json")"
sleep 1
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
M2="$(stat -f %m "$HOME/.kiro/agents/zensu.json")"
[ "$M1" = "$M2" ] && ok "re-run is NOOP (mtime stable)" || bad "re-run rewrote files"

# 4) user-modified file is SKIPped
printf '\n# user tweak\n' >> "$HOME/.kiro/skills/zensu-help/SKILL.md"
S1="$(shasum "$HOME/.kiro/skills/zensu-help/SKILL.md" | cut -d' ' -f1)"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
S2="$(shasum "$HOME/.kiro/skills/zensu-help/SKILL.md" | cut -d' ' -f1)"
[ "$S1" = "$S2" ] && ok "user-modified file preserved" || bad "user-modified file overwritten"
printf '%s' "$OUT" | grep -qi "skip" && ok "skip warned" || bad "no SKIP warning"

# 5) uninstall: ours removed (except user-modified), foreign mcp kept
bash "$INSTALL" --uninstall >/dev/null 2>&1
[ -f "$HOME/.kiro/zensu/hooks/kiro/kiro-shim.sh" ] && bad "runtime survived uninstall" || ok "runtime removed"
[ -f "$HOME/.kiro/agents/zensu.json" ] && bad "agent survived uninstall" || ok "agents removed"
[ -f "$HOME/.kiro/skills/zensu-help/SKILL.md" ] && ok "user-modified skill kept on uninstall" || bad "user-modified skill deleted"
UNMCP="$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  console.log(!(j.mcpServers||{}).zensu && (j.mcpServers||{}).other ? "yes" : "no");
' "$HOME/.kiro/settings/mcp.json" 2>/dev/null)"
[ "$UNMCP" = "yes" ] && ok "uninstall removed zensu mcp entry, kept foreign" || bad "uninstall mcp handling wrong"
[ -f "$HOME/.zensu/config.json" ] && ok "user config untouched by uninstall" || bad "uninstall deleted user config"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
