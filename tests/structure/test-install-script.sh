#!/usr/bin/env bash
# S14/F01 — install.sh contract, exercised in a sandbox HOME (the user's real
# ~/.kiro and ~/.zensu are never touched):
#   fresh install   -> runtime home ~/.kiro/zensu (hooks, prompts, VERSION,
#                      manifest.json with sha256 + absolute destinations),
#                      skills, agents (rendered: zero __ZENSU_HOME__ leftovers),
#                      mcp.json merge preserving pre-existing servers,
#                      ~/.zensu/plugin-root
#   idempotency     -> second run changes nothing (portable mtime via node)
#   user edits      -> a user-modified installed file is SKIPped on EVERY
#                      subsequent upgrade (guard must survive the manifest
#                      rewrite), not just the first one
#   --dry-run       -> writes nothing at all (mcp.json byte-identical, no
#                      skills/agents/.zensu side effects)
#   --mcp-url       -> https enforced (plain http rejected, loopback warned),
#                      custom https URL round-trips through uninstall
#   --scope workspace -> installs under $PWD/.kiro with its own manifest and
#                      uninstalls exactly those files (user scope untouched)
#   --uninstall     -> removes only manifest-listed unmodified files inside
#                      the allowed roots; tampered ../ entries are refused
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }
mt() { node -e 'console.log(require("fs").statSync(process.argv[1]).mtimeMs)' "$1" 2>/dev/null; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.kiro/settings"
printf '{"mcpServers":{"other":{"url":"https://example.com/mcp"}}}\n' > "$HOME/.kiro/settings/mcp.json"
MCP_BEFORE="$(shasum "$HOME/.kiro/settings/mcp.json" | cut -d' ' -f1)"

INSTALL="$ROOT/install.sh"
[ -f "$INSTALL" ] || { bad "install.sh missing"; printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }

# 1) --dry-run writes NOTHING
bash "$INSTALL" --scope user --no-default --dry-run >/dev/null 2>&1
[ -d "$HOME/.kiro/zensu" ] && bad "dry-run created runtime home" || ok "dry-run: no runtime home"
[ -d "$HOME/.kiro/skills" ] && bad "dry-run created skills" || ok "dry-run: no skills"
[ -d "$HOME/.kiro/agents" ] && bad "dry-run created agents" || ok "dry-run: no agents"
[ -d "$HOME/.zensu" ] && bad "dry-run created ~/.zensu" || ok "dry-run: no ~/.zensu"
[ "$(shasum "$HOME/.kiro/settings/mcp.json" | cut -d' ' -f1)" = "$MCP_BEFORE" ] && ok "dry-run: mcp.json byte-unchanged" || bad "dry-run touched mcp.json"

# 2) plain-http --mcp-url is rejected before any write
bash "$INSTALL" --scope user --no-default --mcp-url "http://evil.example/mcp" >/dev/null 2>&1
RC=$?
[ "$RC" -ne 0 ] && ok "http --mcp-url rejected (rc=$RC)" || bad "http --mcp-url accepted"
[ -d "$HOME/.kiro/zensu" ] && bad "rejected install still wrote files" || ok "rejected install wrote nothing"

# 3) fresh install
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
[ -f "$HOME/.kiro/zensu/hooks/plan-approved-delegate.sh" ] && bad "unwired plan-approved hook installed to runtime" || ok "unwired plan-approved hook excluded from runtime"
grep -r "__ZENSU_HOME__" "$HOME/.kiro/agents" >/dev/null 2>&1 && bad "__ZENSU_HOME__ leftovers in agents" || ok "placeholder fully rendered"
grep -q "$HOME/.kiro/zensu/hooks/kiro/kiro-shim.sh" "$HOME/.kiro/agents/zensu.json" && ok "hook commands point at runtime home" || bad "hook command paths wrong"
[ "$(cat "$HOME/.zensu/plugin-root" 2>/dev/null)" = "$HOME/.kiro/zensu" ] && ok "plugin-root written" || bad "plugin-root wrong"
[ -f "$HOME/.zensu/config.json" ] && ok "config seeded" || bad "config not seeded"

MCP_OK="$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const z = j.mcpServers && j.mcpServers.zensu, o = j.mcpServers && j.mcpServers.other;
  console.log(z && z.url === "https://mcp.zensu.dev/mcp" && o && o.url === "https://example.com/mcp" ? "yes" : "no");
' "$HOME/.kiro/settings/mcp.json" 2>/dev/null)"
[ "$MCP_OK" = "yes" ] && ok "mcp.json merged (zensu added, foreign kept)" || bad "mcp merge wrong"

# manifest must record absolute destinations (scope-safe uninstall)
grep -q "\"$HOME/.kiro/agents/zensu.json\"" "$HOME/.kiro/zensu/manifest.json" && ok "manifest records absolute destinations" || bad "manifest keys not absolute"

# 4) idempotency: re-run -> nothing changes (portable mtime)
M1="$(mt "$HOME/.kiro/agents/zensu.json")"
sleep 1
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
M2="$(mt "$HOME/.kiro/agents/zensu.json")"
[ "$M1" = "$M2" ] && ok "re-run is NOOP (mtime stable)" || bad "re-run rewrote files"

# 5) user-modified file is SKIPped — and the guard SURVIVES further upgrades
printf '\n# user tweak\n' >> "$HOME/.kiro/skills/zensu-help/SKILL.md"
S1="$(shasum "$HOME/.kiro/skills/zensu-help/SKILL.md" | cut -d' ' -f1)"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
printf '%s' "$OUT" | grep -qi "skip" && ok "skip warned (1st upgrade)" || bad "no SKIP warning (1st upgrade)"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
S3="$(shasum "$HOME/.kiro/skills/zensu-help/SKILL.md" | cut -d' ' -f1)"
[ "$S1" = "$S3" ] && ok "user-modified file preserved across TWO upgrades" || bad "guard lost after manifest rewrite (2nd upgrade overwrote)"
printf '%s' "$OUT" | grep -qi "skip" && ok "skip warned (2nd upgrade)" || bad "no SKIP warning (2nd upgrade)"

# 6) tampered manifest entries outside the allowed roots are refused
SENTINEL="$HOME/precious.txt"; printf 'keep me\n' > "$SENTINEL"
node -e '
  const fs=require("fs"); const p=process.argv[1];
  const m=JSON.parse(fs.readFileSync(p,"utf8"));
  m.files[process.argv[2]] = "0".repeat(64);
  m.files["../outside.txt"] = "0".repeat(64);
  fs.writeFileSync(p, JSON.stringify(m,null,2));
' "$HOME/.kiro/zensu/manifest.json" "$SENTINEL"
bash "$INSTALL" --uninstall --force >/dev/null 2>&1
[ -f "$SENTINEL" ] && ok "uninstall refuses paths outside allowed roots" || bad "uninstall deleted out-of-root file"
[ -f "$HOME/.kiro/zensu/hooks/kiro/kiro-shim.sh" ] && bad "runtime survived uninstall" || ok "runtime removed"
[ -f "$HOME/.kiro/agents/zensu.json" ] && bad "agent survived uninstall" || ok "agents removed"
UNMCP="$(node -e '
  const j = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  console.log(!(j.mcpServers||{}).zensu && (j.mcpServers||{}).other ? "yes" : "no");
' "$HOME/.kiro/settings/mcp.json" 2>/dev/null)"
[ "$UNMCP" = "yes" ] && ok "uninstall removed zensu mcp entry, kept foreign" || bad "uninstall mcp handling wrong"
[ -f "$HOME/.zensu/config.json" ] && ok "user config untouched by uninstall" || bad "uninstall deleted user config"

# 7) custom https --mcp-url round-trips through uninstall
bash "$INSTALL" --scope user --no-default --mcp-url "https://self.example/mcp" >/dev/null 2>&1
CUR_URL="$(node -e 'console.log((JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers.zensu||{}).url||"")' "$HOME/.kiro/settings/mcp.json")"
[ "$CUR_URL" = "https://self.example/mcp" ] && ok "custom https url merged" || bad "custom url merge wrong: $CUR_URL"
bash "$INSTALL" --uninstall >/dev/null 2>&1
CUR_URL="$(node -e 'console.log(((JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers||{}).zensu||{}).url||"")' "$HOME/.kiro/settings/mcp.json")"
[ -z "$CUR_URL" ] && ok "custom url entry removed on uninstall" || bad "custom url entry left behind: $CUR_URL"

# 7b) merge conflict: pre-existing zensu entry with a DIFFERENT url is left
#     untouched (warn, rc 0) without --force; --force overwrites; sibling keys
#     of an identical-url entry survive idempotent re-merge
node -e '
  const f=process.argv[1]; const j=JSON.parse(require("fs").readFileSync(f,"utf8"));
  j.mcpServers=j.mcpServers||{}; j.mcpServers.zensu={url:"https://custom.example/mcp",disabled:false};
  require("fs").writeFileSync(f, JSON.stringify(j,null,2)+"\n");
' "$HOME/.kiro/settings/mcp.json"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "conflicting-url install still exits 0" || bad "conflict install rc=$RC"
printf '%s' "$OUT" | grep -qi "warn" && ok "conflicting url warned" || bad "no conflict warning"
CUR_URL="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers.zensu.url)' "$HOME/.kiro/settings/mcp.json")"
[ "$CUR_URL" = "https://custom.example/mcp" ] && ok "conflicting url left untouched" || bad "conflict url clobbered: $CUR_URL"
bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1
CUR_URL="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers.zensu.url)' "$HOME/.kiro/settings/mcp.json")"
[ "$CUR_URL" = "https://mcp.zensu.dev/mcp" ] && ok "--force overwrites conflicting url" || bad "--force did not overwrite: $CUR_URL"
node -e '
  const f=process.argv[1]; const j=JSON.parse(require("fs").readFileSync(f,"utf8"));
  j.mcpServers.zensu.disabled=false;
  require("fs").writeFileSync(f, JSON.stringify(j,null,2)+"\n");
' "$HOME/.kiro/settings/mcp.json"
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
SIB="$(node -e 'console.log(String(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers.zensu.disabled))' "$HOME/.kiro/settings/mcp.json")"
[ "$SIB" = "false" ] && ok "idempotent re-merge preserves sibling keys" || bad "re-merge dropped sibling keys (disabled=$SIB)"

# 7c) malformed existing mcp.json must NOT be silently replaced by {zensu-only}
printf '{ broken json,,, \n' > "$HOME/.kiro/settings/mcp.json"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
grep -q "broken json" "$HOME/.kiro/settings/mcp.json" && ok "malformed mcp.json left untouched" || bad "malformed mcp.json was clobbered"
printf '%s' "$OUT" | grep -qiE "warn|malformed|parse" && ok "malformed mcp.json warned" || bad "no malformed warning"
printf '{"mcpServers":{"other":{"url":"https://example.com/mcp"}}}\n' > "$HOME/.kiro/settings/mcp.json"
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1   # restore healthy state

# 7d) non-loopback http disguised as loopback must be FATAL
for EVIL in "http://localhost.evil.com/mcp" "http://127.0.0.1.evil.com/mcp" "http://127.0.0.1@evil.com/mcp" "http://127.0.0.1:80@evil.com/mcp" "http://localhost:1@evil.com/mcp"; do
  bash "$INSTALL" --scope user --no-default --mcp-url "$EVIL" >/dev/null 2>&1
  RC=$?
  [ "$RC" -ne 0 ] && ok "rejected pseudo-loopback $EVIL" || bad "accepted pseudo-loopback $EVIL"
done
ERRTXT="$(bash "$INSTALL" --scope user --no-default --mcp-url "http://127.0.0.1:8080/mcp" 2>&1 >/dev/null)"
RC=$?
[ "$RC" -eq 0 ] && ok "true loopback with port passes https-only validation" || bad "true loopback rejected"
printf '%s' "$ERRTXT" | grep -q "non-TLS loopback" && ok "loopback warn announced" || bad "no loopback warning"
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1   # restore default url

# 7e) first-install over a PRE-EXISTING user file must not silently overwrite
PRE="$HOME/.kiro/skills/zensu-help/SKILL.md"
bash "$INSTALL" --uninstall --force >/dev/null 2>&1
mkdir -p "$(dirname "$PRE")"
printf 'my own notes\n' > "$PRE"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
[ "$(cat "$PRE")" = "my own notes" ] && ok "pre-existing unrecorded file preserved on first install" || bad "first install overwrote pre-existing user file"
printf '%s' "$OUT" | grep -qi "skip" && ok "pre-existing file SKIP warned" || bad "no warning for pre-existing file"
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
[ "$(cat "$PRE")" = "my own notes" ] && ok "pre-existing file STILL preserved on the run after (guard persists)" || bad "second run silently overwrote the foreign file (guard evaporated)"
bash "$INSTALL" --uninstall >/dev/null 2>&1
[ -f "$PRE" ] && ok "uninstall keeps the foreign file (never recorded as ours)" || bad "uninstall deleted a file the installer never wrote"
rm -f "$PRE"; bash "$INSTALL" --scope user --no-default >/dev/null 2>&1

# 7f) sha256sum fallback: with `shasum` hidden from PATH the installer must
#     still hash correctly (idempotent NOOP re-run proves real hashes).
#     Skipped on MSYS/Git Bash: a symlinked single-dir PATH sandbox is not
#     reproducible there (.exe resolution + MSYS runtime deps) — the fallback
#     shell logic is platform-independent and proven on Linux CI.
SHIMBIN="$TMP/shimbin"; mkdir -p "$SHIMBIN"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) : ;; *)
for t in node bash sed mv mkdir mktemp rm cat cut printf find sort dirname basename chmod cp tr grep sha256sum kiro-cli; do
  P="$(command -v "$t" 2>/dev/null)" && [ -n "$P" ] && ln -s "$P" "$SHIMBIN/$t" 2>/dev/null
done
esac
if [ -x "$SHIMBIN/sha256sum" ]; then
  bash "$INSTALL" --uninstall --force >/dev/null 2>&1
  PATH="$SHIMBIN" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
  RC=$?
  [ "$RC" -eq 0 ] && ok "install works with sha256sum fallback (no shasum on PATH)" || bad "sha256sum-fallback install rc=$RC"
  MAN_HASH="$(node -e 'const m=require(process.argv[1]);const k=Object.keys(m.files)[0];console.log((m.files[k]||"").length)' "$HOME/.kiro/zensu/manifest.json" 2>/dev/null)"
  [ "$MAN_HASH" = "64" ] && ok "fallback produced real sha256 hashes (len 64)" || bad "fallback hashes wrong (len=$MAN_HASH — empty hashes disable every guard)"
  M1="$(mt "$HOME/.kiro/agents/zensu.json")"
  PATH="$SHIMBIN" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
  M2="$(mt "$HOME/.kiro/agents/zensu.json")"
  [ "$M1" = "$M2" ] && ok "fallback re-run is NOOP (hashes comparable)" || bad "fallback re-run rewrote files"
else
  ok "skipped: sha256sum PATH sandbox not reproducible here (fallback covered on Linux CI)"
fi
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1

# 8) --scope workspace: own tree, own manifest, scoped uninstall
WS="$TMP/ws"; mkdir -p "$WS"
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1   # re-establish user scope
( cd "$WS" && bash "$INSTALL" --scope workspace --no-default >/dev/null 2>&1 )
[ -f "$WS/.kiro/skills/zensu-tdd/SKILL.md" ] && ok "workspace skills installed under \$PWD/.kiro" || bad "workspace skills missing"
[ -f "$WS/.kiro/agents/zensu.json" ] && ok "workspace agents installed" || bad "workspace agents missing"
[ -f "$HOME/.kiro/zensu/manifest.json" ] && ok "user manifest still present" || bad "user manifest clobbered"
# 8b) a crafted WORKSPACE manifest must not reach into $HOME/.kiro: plant an
#     entry pointing at a user-scope hook with a dummy hash (--force ignores
#     hashes, so only path confinement protects the file) and force-uninstall
SENT2="$HOME/.kiro/zensu/hooks/pre-mcp-zensu-gate.sh"
node -e '
  const fs=require("fs"); const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  m.files[process.argv[2]] = "0".repeat(64);
  fs.writeFileSync(process.argv[1], JSON.stringify(m,null,2));
' "$WS/.kiro/zensu-manifest.json" "$SENT2"
# Match the path SUFFIX, not "$SENT2" verbatim: MSYS converts argv paths for
# native node, so on Windows the planted key is C:/... while $SENT2 is /c/...
grep -q "hooks/pre-mcp-zensu-gate.sh" "$WS/.kiro/zensu-manifest.json" || bad "8b tamper failed to plant entry"
( cd "$WS" && bash "$INSTALL" --uninstall --scope workspace --force >/dev/null 2>&1 )
[ -f "$SENT2" ] && ok "workspace uninstall cannot delete user-scope files (scope-confined)" || bad "workspace manifest reached into \$HOME/.kiro (deleted gate hook!)"
[ -f "$WS/.kiro/agents/zensu.json" ] && bad "workspace uninstall left workspace agents" || ok "workspace uninstall removed workspace files"
[ -f "$HOME/.kiro/agents/zensu.json" ] && ok "workspace uninstall left USER scope untouched" || bad "workspace uninstall deleted user-scope files"

# 8c) sibling-prefix collision: $HOME/.kiro-evil must be refused on user uninstall
mkdir -p "$HOME/.kiro-evil"; printf 'owned\n' > "$HOME/.kiro-evil/owned.txt"
node -e '
  const fs=require("fs"); const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  m.files[process.argv[2]] = "0".repeat(64);
  fs.writeFileSync(process.argv[1], JSON.stringify(m,null,2));
' "$HOME/.kiro/zensu/manifest.json" "$HOME/.kiro-evil/owned.txt"
grep -q ".kiro-evil/owned.txt" "$HOME/.kiro/zensu/manifest.json" || bad "8c tamper failed to plant entry"
bash "$INSTALL" --uninstall --force >/dev/null 2>&1
[ -f "$HOME/.kiro-evil/owned.txt" ] && ok "sibling-prefix path refused (.kiro-evil intact)" || bad "uninstall deleted under .kiro-evil"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
