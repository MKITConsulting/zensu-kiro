#!/usr/bin/env bash
# S14/F01 — install.sh contract, exercised in a sandbox HOME (the user's real
# ~/.kiro and ~/.zensu are never touched):
#   fresh install   -> runtime home ~/.kiro/zensu (hooks, prompts, VERSION,
#                      manifest.json {version, files} with sha256 + absolute
#                      destinations), skills, agents (rendered: zero
#                      __ZENSU_HOME__ leftovers), fixed-runtime validation + config
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
CYGPATH_POSIX=""
case "${OSTYPE:-}" in
  msys*|cygwin*)
    if [ "${MSYS2_ENV_CONV_EXCL:-}" != "*" ]; then
      for RAW_ENV_NAME in ZENSU_KIRO_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_RAW ZENSU_KIRO_WORKSPACE_ANCHOR_RAW ZENSU_KIRO_TEST_ANCHOR_RAW ZENSU_KIRO_ROOT; do
        case ";${MSYS2_ENV_CONV_EXCL:-};" in
          *";$RAW_ENV_NAME;"*) ;;
          *) MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+${MSYS2_ENV_CONV_EXCL};}$RAW_ENV_NAME" ;;
        esac
      done
    fi
    export MSYS2_ENV_CONV_EXCL
    CYGPATH_POSIX="${BASH%/*}/cygpath.exe"
    BASH_POSIX="$BASH"; case "$BASH_POSIX" in *.exe) ;; *) [ -x "${BASH_POSIX}.exe" ] && BASH_POSIX="${BASH_POSIX}.exe" ;; esac
    ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE="$("$CYGPATH_POSIX" -m "$CYGPATH_POSIX")"
    ZENSU_KIRO_TRUSTED_BASH_NATIVE="$("$CYGPATH_POSIX" -m "$BASH_POSIX")"
    export ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE ZENSU_KIRO_TRUSTED_BASH_NATIVE
    ;;
esac
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }
mt() { node -e 'console.log(require("fs").statSync(process.argv[1]).mtimeMs)' "$1" 2>/dev/null; }
hash_file() { node -e 'const fs=require("fs"),c=require("crypto");process.stdout.write(c.createHash("sha256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.kiro/settings"
node -p 'process.ppid' > "$TMP/native-shell.pid"
LIVE_PID="$(cat "$TMP/native-shell.pid")"

INSTALL="$ROOT/install.sh"
HELPER="$ROOT/scripts/install-support.js"
ANCHOR_HELPER="$ROOT/hooks/lib/resolve-native-anchor.js"
INSTALL_WINDOWS_CONFIG="$(sed -n '/^configure_windows_native_tools() {$/,/^}$/p' "$INSTALL")"
SHIM_WINDOWS_CONFIG="$(sed -n '/^configure_windows_native_tools() {$/,/^}$/p' "$ROOT/hooks/kiro/kiro-shim.sh")"
RESOLVER_WINDOWS_CONFIG="$(sed -n '/^configure_windows_native_tools() {$/,/^}$/p' "$ROOT/hooks/lib/resolve-plugin-root.sh")"
if [ -n "$INSTALL_WINDOWS_CONFIG" ] && [ "$INSTALL_WINDOWS_CONFIG" = "$SHIM_WINDOWS_CONFIG" ] && \
   [ "$INSTALL_WINDOWS_CONFIG" = "$RESOLVER_WINDOWS_CONFIG" ]; then
  ok "Windows raw-anchor environment policy is identical in all entrypoints"
else
  bad "Windows raw-anchor environment policy drifted between entrypoints"
fi

# Exercise the real production merger even on POSIX (where the later trusted
# cygpath lookup intentionally fails). `*` is a special all-excluded mode and
# must remain byte-identical; ordinary prefix lists are preserved and extended
# exactly once.
eval "$INSTALL_WINDOWS_CONFIG"
SAVED_OSTYPE="$OSTYPE"
SAVED_EXCL_SET="${MSYS2_ENV_CONV_EXCL+x}"
SAVED_EXCL="${MSYS2_ENV_CONV_EXCL:-}"
OSTYPE=msys-zensu-policy-test
MSYS2_ENV_CONV_EXCL='*'; configure_windows_native_tools >/dev/null 2>&1 || true
STAR_EXCL="$MSYS2_ENV_CONV_EXCL"
MSYS2_ENV_CONV_EXCL='keep-one;keep-two'; configure_windows_native_tools >/dev/null 2>&1 || true
configure_windows_native_tools >/dev/null 2>&1 || true
LIST_EXCL="$MSYS2_ENV_CONV_EXCL"
EXPECTED_EXCL='keep-one;keep-two;ZENSU_KIRO_ANCHOR_RAW;ZENSU_KIRO_HOME_ANCHOR_RAW;ZENSU_KIRO_WORKSPACE_ANCHOR_RAW;ZENSU_KIRO_TEST_ANCHOR_RAW;ZENSU_KIRO_ROOT'
OSTYPE="$SAVED_OSTYPE"
if [ -n "$SAVED_EXCL_SET" ]; then MSYS2_ENV_CONV_EXCL="$SAVED_EXCL"; export MSYS2_ENV_CONV_EXCL; else unset MSYS2_ENV_CONV_EXCL; fi
if [ "$STAR_EXCL" = '*' ] && [ "$LIST_EXCL" = "$EXPECTED_EXCL" ]; then
  ok "MSYS exclusion merger preserves '*' and extends prefix lists idempotently"
else
  bad "MSYS exclusion merger corrupted '*' or an existing prefix list"
fi

ZENSU_KIRO_HOME_ANCHOR_RAW="$TMP"
ZENSU_KIRO_HOME_ANCHOR_NATIVE="$(ZENSU_KIRO_ANCHOR_RAW="$TMP" node "$ANCHOR_HELPER")" || {
  echo "could not resolve test anchor" >&2; exit 1;
}
export ZENSU_KIRO_HOME_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_NATIVE
[ -f "$INSTALL" ] || { bad "install.sh missing"; printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"; exit 1; }
bash -n "$INSTALL" && ok "install.sh parses (bash -n)" || bad "install.sh has a syntax error"

# Anchor canonicality is a pre-mutation invariant. In particular, a HOME that
# reaches the same directory through `..` must not publish files and then fail
# only when the manifest rejects its raw spelling.
NONCANON_BASE="$TMP/noncanonical-home"; mkdir -p "$NONCANON_BASE/x" "$NONCANON_BASE/home"
NONCANON_HOME="$NONCANON_BASE/x/../home"
HOME="$NONCANON_HOME" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1; RC=$?
if [ "$RC" -ne 0 ] && [ ! -e "$NONCANON_BASE/home/.kiro" ] && [ ! -e "$NONCANON_BASE/home/.zensu" ]; then
  ok "non-canonical HOME fails before any installer publication"
else
  bad "non-canonical HOME left a partial installation"
fi

if [ "$(node -p 'process.platform')" != "win32" ]; then
  BACKSLASH_HOME="$TMP/home\\with-backslash"; mkdir -p "$BACKSLASH_HOME"
  HOME="$BACKSLASH_HOME" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1; RC=$?
  BACKSLASH_LEAF="$BACKSLASH_HOME/.kiro/skills/optional-leaf\\"
  printf 'optional backslash leaf\n' > "$BACKSLASH_LEAF"
  MANIFEST="$BACKSLASH_HOME/.kiro/zensu/manifest.json" FILE="$BACKSLASH_LEAF" node - <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf8"));
manifest.files[process.env.FILE] = crypto.createHash("sha256").update(fs.readFileSync(process.env.FILE)).digest("hex");
fs.writeFileSync(process.env.MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
  BACKSLASH_ROOT="$(HOME="$BACKSLASH_HOME" bash "$BACKSLASH_HOME/.kiro/zensu/hooks/lib/resolve-plugin-root.sh" 1 2>/dev/null)"
  if [ "$RC" -eq 0 ] && [ "$BACKSLASH_ROOT" = "$BACKSLASH_HOME/.kiro/zensu" ]; then
    ok "POSIX backslash components and terminal-backslash manifest leaves remain valid"
  else
    bad "POSIX backslash path component was treated as a Windows escape"
  fi
else
  ok "skipped POSIX backslash-anchor case on Windows"
fi

if [ -n "$CYGPATH_POSIX" ]; then
  JUNCTION_TARGET="$TMP/junction-target"; JUNCTION_HOME="$TMP/junction-home"
  mkdir -p "$JUNCTION_TARGET"
  JUNCTION_TARGET_NATIVE="$("$CYGPATH_POSIX" -am "$JUNCTION_TARGET")"
  JUNCTION_HOME_NATIVE="$("$CYGPATH_POSIX" -am "$JUNCTION_HOME")"
  if node -e 'require("fs").symlinkSync(process.argv[1], process.argv[2], "junction")' \
      "$JUNCTION_TARGET_NATIVE" "$JUNCTION_HOME_NATIVE" >/dev/null 2>&1; then
    HOME="$JUNCTION_HOME" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1; RC=$?
    JUNCTION_ROOT="$(HOME="$JUNCTION_HOME" bash "$JUNCTION_HOME/.kiro/zensu/hooks/lib/resolve-plugin-root.sh" 1 2>/dev/null)"
    if [ "$RC" -eq 0 ] && [ "$JUNCTION_ROOT" = "$JUNCTION_HOME/.kiro/zensu" ] && \
       [ -f "$JUNCTION_TARGET/.kiro/zensu/VERSION" ]; then
      ok "Windows junction HOME preserves logical identity and writes through the physical anchor"
    else
      bad "Windows junction HOME lost its logical/native anchor identity"
    fi
  else
    ok "skipped Windows junction-anchor case (junction creation unavailable)"
  fi
else
  ok "skipped Windows junction-anchor case on POSIX"
fi

# 1) --dry-run writes NOTHING
bash "$INSTALL" --scope user --no-default --dry-run >/dev/null 2>&1
[ -d "$HOME/.kiro/zensu" ] && bad "dry-run created runtime home" || ok "dry-run: no runtime home"
[ -d "$HOME/.kiro/skills" ] && bad "dry-run created skills" || ok "dry-run: no skills"
[ -d "$HOME/.kiro/agents" ] && bad "dry-run created agents" || ok "dry-run: no agents"
[ -d "$HOME/.zensu" ] && bad "dry-run created ~/.zensu" || ok "dry-run: no ~/.zensu"

# A locator created by an older plugin generation is foreign state. The Kiro
# installer must neither consume nor rewrite it.
mkdir -p "$HOME/.zensu"
printf '%s\n' '/tmp/legacy-pointer-must-survive' > "$HOME/.zensu/plugin-root"

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
[ "$(cat "$HOME/.zensu/plugin-root" 2>/dev/null)" = '/tmp/legacy-pointer-must-survive' ] && ok "legacy locator preserved and ignored" || bad "legacy locator was rewritten"
[ "$(HOME="$HOME" bash "$HOME/.kiro/zensu/hooks/lib/resolve-plugin-root.sh" 1 2>/dev/null)" = "$HOME/.kiro/zensu" ] && ok "fixed runtime validates and resolves" || bad "fixed runtime validation failed"
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

# A file key with a trailing separator aliases the same native path after
# normalization. Provenance validation must reject it with rc=5 before an
# uninstall can remove any artifact or rewrite the manifest.
TRAIL_MANIFEST="$TMP/manifest.before-trailing-key.json"
cp "$HOME/.kiro/zensu/manifest.json" "$TRAIL_MANIFEST"
TRAIL_ARTIFACT="$HOME/.kiro/agents/zensu.json"
TRAIL_HASH="$(hash_file "$TRAIL_ARTIFACT")"
MANIFEST="$HOME/.kiro/zensu/manifest.json" ARTIFACT="$TRAIL_ARTIFACT" node - <<'NODE'
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.env.MANIFEST, "utf8"));
const hash = manifest.files[process.env.ARTIFACT];
if (!hash) process.exit(1);
delete manifest.files[process.env.ARTIFACT];
manifest.files[`${process.env.ARTIFACT}/`] = hash;
fs.writeFileSync(process.env.MANIFEST, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
TRAIL_BYTES="$(cat "$HOME/.kiro/zensu/manifest.json")"
node "$HELPER" preflight "$HOME/.kiro/zensu/manifest.json" "$HOME/.kiro/zensu/VERSION" \
  "$(cat "$ROOT/VERSION")" "$HOME/.kiro" "$HOME" 1 >/dev/null 2>&1; TRAIL_PREFLIGHT_RC=$?
bash "$INSTALL" --scope user --uninstall --force >/dev/null 2>&1; TRAIL_UNINSTALL_RC=$?
if [ "$TRAIL_PREFLIGHT_RC" -eq 5 ] && [ "$TRAIL_UNINSTALL_RC" -ne 0 ] && \
   [ "$(cat "$HOME/.kiro/zensu/manifest.json")" = "$TRAIL_BYTES" ] && \
   [ -f "$TRAIL_ARTIFACT" ] && [ "$(hash_file "$TRAIL_ARTIFACT")" = "$TRAIL_HASH" ]; then
  ok "trailing-separator manifest key fails rc=5 before atomic uninstall mutation"
else
  bad "trailing-separator manifest key changed manifest or installed artifacts"
fi
cp "$TRAIL_MANIFEST" "$HOME/.kiro/zensu/manifest.json"

# 3) idempotency: re-run -> nothing changes (portable mtime)
M1="$(mt "$HOME/.kiro/agents/zensu.json")"
sleep 1
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
M2="$(mt "$HOME/.kiro/agents/zensu.json")"
[ "$M1" = "$M2" ] && ok "re-run is NOOP (mtime stable)" || bad "re-run rewrote files"

# 4) user-modified file is SKIPped — and the guard SURVIVES further upgrades
printf '\n# user tweak\n' >> "$HOME/.kiro/skills/zensu-help/SKILL.md"
S1="$(hash_file "$HOME/.kiro/skills/zensu-help/SKILL.md")"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
printf '%s' "$OUT" | grep -qi "skip" && ok "skip warned (1st upgrade)" || bad "no SKIP warning (1st upgrade)"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
S3="$(hash_file "$HOME/.kiro/skills/zensu-help/SKILL.md")"
[ "$S1" = "$S3" ] && ok "user-modified file preserved across TWO upgrades" || bad "guard lost after manifest rewrite (2nd upgrade overwrote)"
printf '%s' "$OUT" | grep -qi "skip" && ok "skip warned (2nd upgrade)" || bad "no SKIP warning (2nd upgrade)"

# 5) tampered manifest entries outside the allowed roots fail the whole
#    operation closed. --force must never override path-safety failures.
SENTINEL="$HOME/precious.txt"; printf 'keep me\n' > "$SENTINEL"
cp "$HOME/.kiro/zensu/manifest.json" "$TMP/manifest.before-path-tamper.json"
node -e '
  const fs=require("fs"); const p=process.argv[1];
  const m=JSON.parse(fs.readFileSync(p,"utf8"));
  m.files[process.argv[2]] = "0".repeat(64);
  m.files["../outside.txt"] = "0".repeat(64);
  fs.writeFileSync(p, JSON.stringify(m,null,2));
' "$HOME/.kiro/zensu/manifest.json" "$SENTINEL"
bash "$INSTALL" --uninstall --force >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && ok "unsafe manifest blocks uninstall even with --force" || bad "--force overrode manifest path safety"
[ -f "$SENTINEL" ] && ok "uninstall refuses paths outside allowed roots" || bad "uninstall deleted out-of-root file"
[ -f "$HOME/.kiro/zensu/hooks/kiro/kiro-shim.sh" ] && ok "failed-closed uninstall leaves runtime intact" || bad "partial uninstall occurred before unsafe entry was rejected"
cp "$TMP/manifest.before-path-tamper.json" "$HOME/.kiro/zensu/manifest.json"
bash "$INSTALL" --uninstall --force >/dev/null 2>&1
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
cp "$WS/.kiro/zensu-manifest.json" "$TMP/workspace-manifest.before-tamper.json"
node -e '
  const fs=require("fs"); const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  m.files[process.argv[2]] = "0".repeat(64);
  fs.writeFileSync(process.argv[1], JSON.stringify(m,null,2));
' "$WS/.kiro/zensu-manifest.json" "$SENT2"
# Match the path SUFFIX, not "$SENT2" verbatim: MSYS converts argv paths for
# native node, so on Windows the planted key is C:/... while $SENT2 is /c/...
grep -q "hooks/pre-bash-zensu-gate.sh" "$WS/.kiro/zensu-manifest.json" || bad "8b tamper failed to plant entry"
( cd "$WS" && bash "$INSTALL" --uninstall --scope workspace --force >/dev/null 2>&1 ); RC=$?
[ "$RC" -ne 0 ] && ok "unsafe workspace manifest fails closed" || bad "workspace --force overrode path safety"
[ -f "$SENT2" ] && ok "workspace uninstall cannot delete user-scope files (scope-confined)" || bad "workspace manifest reached into \$HOME/.kiro (deleted gate hook!)"
[ -f "$WS/.kiro/agents/zensu.json" ] && ok "failed-closed workspace uninstall is atomic" || bad "workspace uninstall partially removed files before rejecting manifest"
cp "$TMP/workspace-manifest.before-tamper.json" "$WS/.kiro/zensu-manifest.json"
( cd "$WS" && bash "$INSTALL" --uninstall --scope workspace --force >/dev/null 2>&1 )
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

# 9) HOME is data, never code. The end-to-end fixture uses only NTFS-valid
#    metacharacters; quote/backslash escaping is covered directly by the helper
#    suite because those characters cannot both appear in a Windows path.
EVIL_BASE="$TMP/hostile-home-case"; mkdir -p "$EVIL_BASE"
EVIL_HOME="$EVIL_BASE/home \$dollar \$(touch PWNED_DOLLAR) \`touch PWNED_TICK\` quote' semi; amp&"
mkdir -p "$EVIL_HOME"
OUT="$(cd "$EVIL_BASE" && HOME="$EVIL_HOME" bash "$INSTALL" --scope user --no-default 2>&1)"; RC=$?
[ "$RC" -eq 0 ] && ok "hostile-but-valid HOME installs successfully" || bad "hostile HOME install rc=$RC: $OUT"
EVIL_AGENT="$EVIL_HOME/.kiro/agents/zensu.json"
if AGENT="$EVIL_AGENT" node -e 'JSON.parse(require("fs").readFileSync(process.env.AGENT,"utf8"))' 2>/dev/null; then
  ok "rendered agent remains valid JSON for hostile HOME"
else
  bad "raw HOME interpolation corrupted rendered agent JSON"
fi
CMD="$(AGENT="$EVIL_AGENT" node -e '
  const j=JSON.parse(require("fs").readFileSync(process.env.AGENT,"utf8"));
  const hook=Object.values(j.hooks||{}).flat().find(x=>x&&typeof x.command==="string");
  process.stdout.write(hook ? hook.command : "");
' 2>/dev/null)"
if [ -n "$CMD" ]; then
  ( cd "$EVIL_BASE" && bash -c "$CMD" </dev/null >/dev/null 2>&1 ) || true
fi
[ ! -e "$EVIL_BASE/PWNED_DOLLAR" ] && [ ! -e "$EVIL_BASE/PWNED_TICK" ] && ok "rendered hook command treats HOME metacharacters literally" || bad "rendered hook command executed HOME payload"

# Control characters cannot be represented safely across JSON/shell consumers.
CONTROL_HOME="$TMP/"$'control\nhome'; mkdir -p "$CONTROL_HOME"
CONTROL_OUT="$(HOME="$CONTROL_HOME" bash "$INSTALL" --scope user --no-default --dry-run 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && [ ! -e "$CONTROL_HOME/.kiro" ] && printf '%s' "$CONTROL_OUT" | grep -qi 'control characters'; then
  ok "control-character HOME is rejected explicitly before writes"
else
  bad "control-character HOME rejection was missing or ambiguous"
fi

# 10) Existing symlink components must never redirect an install outside the
#     intended root.
SYM_HOME="$TMP/symlink-install-home"; SYM_OUT="$TMP/symlink-install-outside"
mkdir -p "$SYM_HOME" "$SYM_OUT"
if ln -s "$SYM_OUT" "$SYM_HOME/.kiro" 2>/dev/null; then
  HOME="$SYM_HOME" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1; RC=$?
  [ "$RC" -ne 0 ] && ok "install rejects a symlinked .kiro root" || bad "install followed symlinked .kiro root"
  [ ! -e "$SYM_OUT/zensu" ] && ok "symlinked install wrote nothing outside HOME" || bad "install escaped through .kiro symlink"
else
  ok "skipped: filesystem does not permit symlink fixture"
  ok "skipped: filesystem does not permit symlink fixture"
fi

# The same rule applies to uninstall: a post-install directory swap must not
# let a valid recorded hash authorize deletion through a symlink.
UN_HOME="$TMP/symlink-uninstall-home"; UN_OUT="$TMP/symlink-uninstall-outside"
mkdir -p "$UN_HOME" "$UN_OUT"
HOME="$UN_HOME" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
if mv "$UN_HOME/.kiro/agents" "$UN_HOME/.kiro/agents-real" 2>/dev/null && ln -s "$UN_OUT" "$UN_HOME/.kiro/agents" 2>/dev/null; then
  cp "$UN_HOME/.kiro/agents-real/zensu.json" "$UN_OUT/zensu.json"
  HOME="$UN_HOME" bash "$INSTALL" --scope user --uninstall --force >/dev/null 2>&1; RC=$?
  [ "$RC" -ne 0 ] && ok "uninstall rejects a symlinked manifest path" || bad "uninstall followed a symlinked manifest path"
  [ -f "$UN_OUT/zensu.json" ] && ok "symlinked uninstall leaves outside file intact" || bad "uninstall deleted through symlink"
else
  ok "skipped: filesystem does not permit uninstall symlink fixture"
  ok "skipped: filesystem does not permit uninstall symlink fixture"
fi

# 11) Uninstall remains available after a newer runtime was installed. Version
#     drift is an install concern; schema and path safety still apply.
NEW_HOME="$TMP/newer-uninstall-home"; mkdir -p "$NEW_HOME"
HOME="$NEW_HOME" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
MANIFEST="$NEW_HOME/.kiro/zensu/manifest.json" node -e '
  const fs=require("fs"), p=process.env.MANIFEST, m=JSON.parse(fs.readFileSync(p,"utf8"));
  m.version="9.0.0"; fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
'
printf '9.0.0\n' > "$NEW_HOME/.kiro/zensu/VERSION"
HOME="$NEW_HOME" bash "$INSTALL" --scope user --uninstall >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && [ ! -e "$NEW_HOME/.kiro/zensu/manifest.json" ] && ok "uninstall ignores safe version drift" || bad "newer runtime could not be uninstalled"

# SemVer prerelease identifiers use numeric precedence: beta.10 is newer than
# beta.2 even though a lexical string comparison says otherwise.
BETA_SRC="$TMP/source-beta"; cp -R "$ROOT" "$BETA_SRC"
printf '1.0.0-beta.2\n' > "$BETA_SRC/VERSION"
BETA_HOME="$TMP/beta-home"; mkdir -p "$BETA_HOME/.kiro/zensu"
printf '1.0.0-beta.10\n' > "$BETA_HOME/.kiro/zensu/VERSION"
printf '{"version":"1.0.0-beta.10","files":{}}\n' > "$BETA_HOME/.kiro/zensu/manifest.json"
OUT="$(HOME="$BETA_HOME" bash "$BETA_SRC/install.sh" --scope user --no-default 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'downgrade'; then
  ok "SemVer guard treats beta.10 as newer than beta.2"
else
  bad "SemVer prerelease comparison is lexical or incomplete"
fi

# Valid SemVer may contain prerelease and build metadata simultaneously; the
# installed resolver and installer must agree on this grammar.
printf '1.0.0-beta.2+build.7\n' > "$BETA_SRC/VERSION"
COMBO_HOME="$TMP/combo-home"; mkdir -p "$COMBO_HOME"
HOME="$COMBO_HOME" bash "$BETA_SRC/install.sh" --scope user --no-default >/dev/null 2>&1; RC=$?
if [ "$RC" -eq 0 ] && HOME="$COMBO_HOME" bash "$COMBO_HOME/.kiro/zensu/hooks/lib/resolve-plugin-root.sh" 1 >/dev/null 2>&1; then
  ok "installer and resolver accept prerelease plus build SemVer"
else
  bad "resolver rejected valid prerelease plus build SemVer"
fi

# A normal upgrade must recognize its old manifest entry on native Windows
# Node even though Git Bash may spell the same path as /c/... vs C:/....
UPGRADE_SRC="$TMP/upgrade-source"; cp -R "$ROOT" "$UPGRADE_SRC"
UPGRADE_HOME="$TMP/upgrade-home"; mkdir -p "$UPGRADE_HOME"
HOME="$UPGRADE_HOME" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
printf '\nwindows canonical upgrade marker\n' >> "$UPGRADE_SRC/skills/zensu-help/SKILL.md"
OUT="$(HOME="$UPGRADE_HOME" bash "$UPGRADE_SRC/install.sh" --scope user --no-default 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && grep -q 'windows canonical upgrade marker' "$UPGRADE_HOME/.kiro/skills/zensu-help/SKILL.md"; then
  ok "upgrade matches canonical manifest paths across Git Bash/native Node"
else
  bad "upgrade treated its managed file as foreign: $OUT"
fi

# A noncritical write failure must abort before either manifest is replaced.
FAULT_SRC="$TMP/fault-source"; cp -R "$ROOT" "$FAULT_SRC"
FAULT_HOME="$TMP/fault-home"; mkdir -p "$FAULT_HOME"
HOME="$FAULT_HOME" bash "$FAULT_SRC/install.sh" --scope user --no-default >/dev/null 2>&1
FAULT_MANIFEST="$FAULT_HOME/.kiro/zensu/manifest.json"; BEFORE_MANIFEST="$(hash_file "$FAULT_MANIFEST")"
printf '\nforced noncritical candidate change\n' >> "$FAULT_SRC/skills/zensu-help/SKILL.md"
OUT="$(NODE_ENV=test ZENSU_INSTALL_TEST_FAIL_TARGET='/skills/zensu-help/SKILL.md' HOME="$FAULT_HOME" \
  bash "$FAULT_SRC/install.sh" --scope user --no-default 2>&1)"; RC=$?
AFTER_MANIFEST="$(hash_file "$FAULT_MANIFEST")"
if [ "$RC" -ne 0 ] && [ "$BEFORE_MANIFEST" = "$AFTER_MANIFEST" ] && printf '%s' "$OUT" | grep -q 'manifests were not published'; then
  ok "noncritical write failure leaves the prior manifest unpublished"
else
  bad "partial install published a manifest (rc=$RC)"
fi

# 12) A held HOME-wide lock deterministically blocks the installer. Releasing
#     it lets the waiting process finish with a valid runtime.
HELPER="$ROOT/scripts/install-support.js"
LOCK_HOME="$TMP/concurrent-home"; mkdir -p "$LOCK_HOME"
OWNER_PID="$LIVE_PID"
LOCK_PATH="$LOCK_HOME/.zensu-kiro-install.lock"
TOKEN="$(node "$HELPER" acquire-lock "$LOCK_HOME" "$LOCK_PATH" "$OWNER_PID" 2>/dev/null)"
HOME="$LOCK_HOME" bash "$INSTALL" --scope user --no-default >"$TMP/install-held.log" 2>&1 & HELD_PID=$!
sleep 0.25
if kill -0 "$HELD_PID" 2>/dev/null && [ ! -e "$LOCK_HOME/.kiro/zensu/manifest.json" ]; then
  ok "held HOME-wide lock blocks publication"
else
  bad "installer did not block behind the held lock"
fi
node "$HELPER" release-lock "$LOCK_HOME" "$LOCK_PATH" "$OWNER_PID" "$TOKEN" >/dev/null 2>&1
wait "$HELD_PID"; RC=$?
if [ "$RC" -eq 0 ] && HOME="$LOCK_HOME" bash "$LOCK_HOME/.kiro/zensu/hooks/lib/resolve-plugin-root.sh" 1 >/dev/null 2>&1; then
  ok "waiting installer completes after lock release"
else
  bad "waiting installer failed after lock release"
fi

# Signal a process only after it proves lock ownership. It must exit 143,
# release the lock, and perform no post-signal installation writes.
SIGNAL_HOME="$TMP/signal-home"; SIGNAL_BARRIER="$TMP/signal-barrier"
mkdir -p "$SIGNAL_HOME" "$SIGNAL_BARRIER"
NODE_ENV=test ZENSU_INSTALL_TEST_AFTER_LOCK_DIR="$SIGNAL_BARRIER" HOME="$SIGNAL_HOME" \
  bash "$INSTALL" --scope user --no-default >"$TMP/install-signal.log" 2>&1 & SIGNAL_PID=$!
i=0; while [ ! -e "$SIGNAL_BARRIER/reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
if [ -e "$SIGNAL_BARRIER/reached" ]; then
  kill -TERM "$SIGNAL_PID"; wait "$SIGNAL_PID"; RC=$?
  if [ "$RC" -eq 143 ] && [ ! -e "$SIGNAL_HOME/.zensu-kiro-install.lock" ] && [ ! -e "$SIGNAL_HOME/.kiro/zensu/manifest.json" ]; then
    ok "SIGTERM exits immediately and releases the lock before writes"
  else
    bad "SIGTERM continued installation or stranded the lock (rc=$RC)"
  fi
else
  bad "signal fixture never reached the post-lock barrier"
  kill -KILL "$SIGNAL_PID" 2>/dev/null || true
fi
HOME="$SIGNAL_HOME" bash "$INSTALL" --scope user --no-default >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "subsequent install acquires the signal-released lock" || bad "signal-released lock was not reusable"

# Two real contenders must also converge on one coherent publication.
PAR_HOME="$TMP/parallel-home"; mkdir -p "$PAR_HOME"
HOME="$PAR_HOME" bash "$INSTALL" --scope user --no-default >"$TMP/install-a.log" 2>&1 & PA=$!
HOME="$PAR_HOME" bash "$INSTALL" --scope user --no-default >"$TMP/install-b.log" 2>&1 & PB=$!
wait "$PA"; RCA=$?; wait "$PB"; RCB=$?
if [ "$RCA" -eq 0 ] && [ "$RCB" -eq 0 ] && HOME="$PAR_HOME" bash "$PAR_HOME/.kiro/zensu/hooks/lib/resolve-plugin-root.sh" 1 >/dev/null 2>&1; then
  ok "parallel installs publish one coherent runtime"
else
  bad "parallel installs raced or left an invalid runtime (rc=$RCA/$RCB)"
fi

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
