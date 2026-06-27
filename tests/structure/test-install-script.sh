#!/usr/bin/env bash
# S14/F01 — install.sh contract, exercised in a sandbox HOME (the user's real
# ~/.kiro and ~/.zensu are never touched):
#   fresh install   -> runtime home ~/.kiro/zensu (hooks, prompts, VERSION,
#                      manifest.json {version, files} with sha256 + absolute
#                      destinations), skills, agents (rendered: zero
#                      __ZENSU_HOME__ leftovers), ~/.zensu/plugin-root + config
#   idempotency     -> second run changes nothing (portable mtime via node)
#   user edits      -> a user-modified installed file is SKIPped on EVERY
#                      subsequent upgrade (guard must survive the manifest
#                      rewrite), not just the first one
#   --dry-run       -> writes nothing at all (no skills/agents/.zensu side
#                      effects)
#   CLI re-home     -> no hosted MCP wiring: no ~/.kiro/settings/mcp.json write,
#                      a fresh install never references mcp.zensu.dev, the
#                      manifest carries no mcpFile/mcpUrl fields
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

INSTALL="$ROOT/install.sh"
[ -f "$INSTALL" ] || { bad "install.sh missing"; printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }
bash -n "$INSTALL" && ok "install.sh parses (bash -n)" || bad "install.sh has a syntax error"

# 1) --dry-run writes NOTHING
bash "$INSTALL" --scope user --no-default --dry-run >/dev/null 2>&1
[ -d "$HOME/.kiro/zensu" ] && bad "dry-run created runtime home" || ok "dry-run: no runtime home"
[ -d "$HOME/.kiro/skills" ] && bad "dry-run created skills" || ok "dry-run: no skills"
[ -d "$HOME/.kiro/agents" ] && bad "dry-run created agents" || ok "dry-run: no agents"
[ -d "$HOME/.zensu" ] && bad "dry-run created ~/.zensu" || ok "dry-run: no ~/.zensu"

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
[ -f "$HOME/.kiro/zensu/hooks/plan-approved-delegate.sh" ] && bad "unwired plan-approved hook installed to runtime" || ok "unwired plan-approved hook excluded from runtime"
grep -r "__ZENSU_HOME__" "$HOME/.kiro/agents" >/dev/null 2>&1 && bad "__ZENSU_HOME__ leftovers in agents" || ok "placeholder fully rendered"
grep -q "$HOME/.kiro/zensu/hooks/kiro/kiro-shim.sh" "$HOME/.kiro/agents/zensu.json" && ok "hook commands point at runtime home" || bad "hook command paths wrong"
[ "$(cat "$HOME/.zensu/plugin-root" 2>/dev/null)" = "$HOME/.kiro/zensu" ] && ok "plugin-root written" || bad "plugin-root wrong"
[ -f "$HOME/.zensu/config.json" ] && ok "config seeded" || bad "config not seeded"

# 2b) CLI re-home: no hosted MCP wiring is left behind by a fresh install
[ -f "$HOME/.kiro/settings/mcp.json" ] && bad "installer wrote ~/.kiro/settings/mcp.json (MCP wiring retired)" || ok "no ~/.kiro/settings/mcp.json written"
grep -rq "mcp.zensu.dev" "$HOME/.kiro" 2>/dev/null && bad "fresh install references mcp.zensu.dev" || ok "fresh install never references mcp.zensu.dev"

# manifest is {version, files} only — no retired mcpFile/mcpUrl fields
MAN_SHAPE="$(node -e '
  const m = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const okShape = typeof m.version === "string"
    && m.files && typeof m.files === "object"
    && !("mcpFile" in m) && !("mcpUrl" in m);
  console.log(okShape ? "yes" : "no");
' "$HOME/.kiro/zensu/manifest.json" 2>/dev/null)"
[ "$MAN_SHAPE" = "yes" ] && ok "manifest validates as {version, files} (no mcp fields)" || bad "manifest shape wrong (expected {version, files}, no mcpFile/mcpUrl)"

# manifest must record absolute destinations (scope-safe uninstall)
grep -q "\"$HOME/.kiro/agents/zensu.json\"" "$HOME/.kiro/zensu/manifest.json" && ok "manifest records absolute destinations" || bad "manifest keys not absolute"

# 3) idempotency: re-run -> nothing changes (portable mtime)
M1="$(mt "$HOME/.kiro/agents/zensu.json")"
sleep 1
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
M2="$(mt "$HOME/.kiro/agents/zensu.json")"
[ "$M1" = "$M2" ] && ok "re-run is NOOP (mtime stable)" || bad "re-run rewrote files"

# 4) user-modified file is SKIPped — and the guard SURVIVES further upgrades
printf '\n# user tweak\n' >> "$HOME/.kiro/skills/zensu-help/SKILL.md"
S1="$(shasum "$HOME/.kiro/skills/zensu-help/SKILL.md" | cut -d' ' -f1)"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
printf '%s' "$OUT" | grep -qi "skip" && ok "skip warned (1st upgrade)" || bad "no SKIP warning (1st upgrade)"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
S3="$(shasum "$HOME/.kiro/skills/zensu-help/SKILL.md" | cut -d' ' -f1)"
[ "$S1" = "$S3" ] && ok "user-modified file preserved across TWO upgrades" || bad "guard lost after manifest rewrite (2nd upgrade overwrote)"
printf '%s' "$OUT" | grep -qi "skip" && ok "skip warned (2nd upgrade)" || bad "no SKIP warning (2nd upgrade)"

# 5) tampered manifest entries outside the allowed roots are refused
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
[ -f "$HOME/.zensu/config.json" ] && ok "user config untouched by uninstall" || bad "uninstall deleted user config"

# 6) first-install over a PRE-EXISTING user file must not silently overwrite
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

# 7) sha256sum fallback: with `shasum` hidden from PATH the installer must
#    still hash correctly (idempotent NOOP re-run proves real hashes).
#    Skipped on MSYS/Git Bash: a symlinked single-dir PATH sandbox is not
#    reproducible there (.exe resolution + MSYS runtime deps) — the fallback
#    shell logic is platform-independent and proven on Linux CI.
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
SENT2="$HOME/.kiro/zensu/hooks/pre-bash-zensu-gate.sh"
node -e '
  const fs=require("fs"); const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  m.files[process.argv[2]] = "0".repeat(64);
  fs.writeFileSync(process.argv[1], JSON.stringify(m,null,2));
' "$WS/.kiro/zensu-manifest.json" "$SENT2"
# Match the path SUFFIX, not "$SENT2" verbatim: MSYS converts argv paths for
# native node, so on Windows the planted key is C:/... while $SENT2 is /c/...
grep -q "hooks/pre-bash-zensu-gate.sh" "$WS/.kiro/zensu-manifest.json" || bad "8b tamper failed to plant entry"
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
