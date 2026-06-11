#!/usr/bin/env bash
# zensu-kiro installer — Kiro CLI has no native plugin system, so this script
# delivers the plugin pieces onto the shared .kiro surfaces:
#
#   ~/.kiro/zensu/            hook runtime (hooks/, prompts/, VERSION, manifest)
#   <scope>/.kiro/skills/     11 Agent-Skills-standard skills (IDE + CLI)
#   <scope>/.kiro/agents/     4 CLI agent JSONs (rendered) + 3 IDE agent md
#   <scope>/.kiro/settings/mcp.json  zensu remote MCP server (merged, https-only)
#   ~/.zensu/plugin-root      runtime-home pointer the skills depend on
#   ~/.zensu/config.json      seeded from config.example.json if missing
#
# Usage:
#   install.sh [--scope user|workspace] [--uninstall] [--dry-run] [--force]
#              [--set-default|--no-default] [--mcp-url <https-url>]
#
# Idempotent via manifests recording ABSOLUTE destinations + sha256: unmodified
# files are overwritten on upgrade, user-modified files are SKIPped on every
# upgrade (the previous record is carried forward; --force overwrites),
# re-running the same version is a NOOP. The hook runtime is always user-level
# (hook command paths are absolute) and tracked in the user manifest
# (~/.kiro/zensu/manifest.json); workspace skills/agents are tracked in
# <workspace>/.kiro/zensu-manifest.json. --uninstall removes only manifest
# entries whose hash still matches, refusing any path outside the allowed
# roots, and unmerges exactly the mcp entry it installed (URL recorded).
set -u

SRC="$(cd "$(dirname "$0")" && pwd)"
SCOPE="user"
DRY=0
FORCE=0
UNINSTALL=0
SET_DEFAULT="ask"
MCP_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      [ $# -ge 2 ] || { echo "FATAL: --scope needs a value" >&2; exit 2; }
      SCOPE="$2"; shift 2 ;;
    --mcp-url)
      [ $# -ge 2 ] || { echo "FATAL: --mcp-url needs a value" >&2; exit 2; }
      MCP_URL="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --set-default) SET_DEFAULT="yes"; shift ;;
    --no-default) SET_DEFAULT="no"; shift ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "FATAL: node is required (all JSON operations use node)" >&2; exit 1; }
if command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
  sha_stdin() { shasum -a 256 | cut -d' ' -f1; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }
  sha_stdin() { sha256sum | cut -d' ' -f1; }
else
  echo "FATAL: neither shasum nor sha256sum found (manifest integrity needs one)" >&2
  exit 1
fi
command -v kiro-cli >/dev/null 2>&1 || echo "note: kiro-cli not found on PATH — files install fine, install the CLI later" >&2

ZENSU_HOME="$HOME/.kiro/zensu"
case "$SCOPE" in
  user)      KIRO_DIR="$HOME/.kiro" ;;
  workspace) KIRO_DIR="$PWD/.kiro" ;;
  *) echo "FATAL: --scope must be user or workspace" >&2; exit 2 ;;
esac
USER_MANIFEST="$ZENSU_HOME/manifest.json"
if [ "$SCOPE" = "workspace" ]; then
  SCOPE_MANIFEST="$KIRO_DIR/zensu-manifest.json"
else
  SCOPE_MANIFEST="$USER_MANIFEST"
fi
MCP_FILE="$KIRO_DIR/settings/mcp.json"
REPO_MCP_URL="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers.zensu.url)' "$SRC/mcp.json" 2>/dev/null || echo "https://mcp.zensu.dev/mcp")"
[ -n "$MCP_URL" ] || MCP_URL="$REPO_MCP_URL"

# https-only MCP endpoint (OAuth tokens must not transit cleartext); loopback
# http is allowed for local development with a warning.
case "$MCP_URL" in
  https://*) ;;
  http://*@*)
    # userinfo form: the REAL host follows the @ (http://127.0.0.1:x@evil.com)
    echo "FATAL: --mcp-url must not carry userinfo (@) in a plain-http url (got: $MCP_URL)" >&2; exit 2 ;;
  http://127.0.0.1|http://127.0.0.1:*|http://127.0.0.1/*|http://localhost|http://localhost:*|http://localhost/*)
    echo "warn: non-TLS loopback MCP url ($MCP_URL)" >&2 ;;
  *) echo "FATAL: --mcp-url must be https:// (got: $MCP_URL; loopback http is allowed only as http://127.0.0.1[:port]/... or http://localhost[:port]/...)" >&2; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }

manifest_lookup() { # $1=manifest $2=abs path -> recorded hash or empty
  [ -f "$1" ] || return 0
  M="$1" P="$2" node -e '
    try {
      const m = JSON.parse(require("fs").readFileSync(process.env.M,"utf8"));
      process.stdout.write((m.files && m.files[process.env.P]) || "");
    } catch (_) {}
  ' 2>/dev/null
}

USER_LIST="$(mktemp)"; SCOPE_LIST="$(mktemp)"
trap 'rm -f "$USER_LIST" "$SCOPE_LIST"' EXIT
INSTALL_FAILED=0

# install_file <src-abs> <dst-abs> <list-file> [render]
install_file() {
  local src="$1" dst="$2" list="$3" render="${4:-no}" content tmp old want recorded
  if [ "$render" = "render" ]; then
    content="$(sed "s|__ZENSU_HOME__|$ZENSU_HOME|g" "$src")"
  else
    content="$(cat "$src")"
  fi
  want="$(printf '%s\n' "$content" | sha_stdin)"
  if [ -f "$dst" ]; then
    old="$(sha "$dst")"
    if [ "$old" = "$want" ]; then
      say "NOOP    $dst"
      printf '%s\t%s\n' "$dst" "$want" >> "$list"
      return 0
    fi
    recorded="$(manifest_lookup "$USER_MANIFEST" "$dst")"
    [ -n "$recorded" ] || recorded="$(manifest_lookup "$SCOPE_MANIFEST" "$dst")"
    if [ "$FORCE" -ne 1 ] && { { [ -n "$recorded" ] && [ "$old" != "$recorded" ]; } || [ -z "$recorded" ]; }; then
      # Either the user modified a file we installed, or the file pre-existed
      # without any record of ours — never silently overwrite foreign content.
      say "SKIP    $dst (pre-existing/user-modified; --force to overwrite)"
      # User-modified OUR file: carry the previous record forward so the guard
      # survives this upgrade's manifest rewrite. FOREIGN file (no record):
      # record NOTHING — recording its hash would make the next run treat it
      # as ours (silent UPDATE) and uninstall would delete it.
      [ -n "$recorded" ] && printf '%s\t%s\n' "$dst" "$recorded" >> "$list"
      return 0
    fi
    say "UPDATE  $dst"
  else
    say "CREATE  $dst"
  fi
  [ "$DRY" -eq 1 ] && { printf '%s\t%s\n' "$dst" "$want" >> "$list"; return 0; }
  mkdir -p "$(dirname "$dst")"
  tmp="$(mktemp "$(dirname "$dst")/.zensu-install.XXXXXX")" || return 1
  if printf '%s\n' "$content" > "$tmp" && mv "$tmp" "$dst"; then
    case "$dst" in *.sh) chmod +x "$dst" ;; esac
    # Record ONLY successful writes — a failed write must not poison the
    # manifest with a hash the on-disk file does not have.
    printf '%s\t%s\n' "$dst" "$want" >> "$list"
  else
    rm -f "$tmp" 2>/dev/null
    say "ERROR   $dst (write failed; not recorded)"
    INSTALL_FAILED=1
    return 1
  fi
}

json_write_atomic() { # $1=file ; JSON on stdin
  local tmp
  mkdir -p "$(dirname "$1")"
  tmp="$(mktemp "$(dirname "$1")/.zensu-mcp.XXXXXX")" || return 1
  cat > "$tmp" && mv "$tmp" "$1"
}

merge_mcp() {
  say "MERGE   $MCP_FILE (mcpServers.zensu -> $MCP_URL)"
  [ "$DRY" -eq 1 ] && return 0
  MCP_FILE_ENV="$MCP_FILE" MCP_URL_ENV="$MCP_URL" FORCE_ENV="$FORCE" node -e '
    const fs = require("fs");
    // Git Bash / MSYS env conversion is heuristic: path-like env values may
    // reach native node in EITHER form (/c/... untouched, or converted to
    // C:/...). Normalize for fs ops only; emitted strings stay POSIX.
    const norm = p => process.platform === "win32" ? p.replace(/^\/([A-Za-z])(\/|$)/, (m,d,s) => d.toUpperCase() + ":" + (s || "")) : p;
    const file = norm(process.env.MCP_FILE_ENV), url = process.env.MCP_URL_ENV;
    let j = {};
    if (fs.existsSync(file)) {
      // An existing-but-malformed settings file must never be replaced by a
      // zensu-only document — that would silently drop every other server.
      try { j = JSON.parse(fs.readFileSync(file, "utf8")); }
      catch (e) {
        console.error("warn: " + file + " exists but is not valid JSON (" + e.message + ") — mcp merge skipped; fix the file and re-run");
        process.exit(3);
      }
    }
    if (typeof j !== "object" || j === null || Array.isArray(j)) {
      console.error("warn: " + file + " has a non-object JSON root — mcp merge skipped; fix the file and re-run");
      process.exit(3);
    }
    j.mcpServers = j.mcpServers || {};
    const existing = j.mcpServers.zensu;
    if (existing && existing.url !== url && process.env.FORCE_ENV !== "1") {
      console.error("warn: mcpServers.zensu already exists with a different url (" + existing.url + ") — left untouched (--force to overwrite)");
      process.exit(3);
    }
    // Preserve user-added sibling keys (disabled, headers, ...) on re-merge.
    j.mcpServers.zensu = Object.assign({}, existing || {}, { url });
    process.stdout.write(JSON.stringify(j, null, 2) + "\n");
  ' | { read -r first || exit 0; { printf '%s\n' "$first"; cat; } | json_write_atomic "$MCP_FILE"; }
}

unmerge_mcp() { # $1=mcp file $2=recorded url
  [ -f "$1" ] || return 0
  say "UNMERGE $1 (remove mcpServers.zensu if url == $2)"
  [ "$DRY" -eq 1 ] && return 0
  MCP_FILE_ENV="$1" MCP_URL_ENV="$2" node -e '
    const fs = require("fs");
    const norm = p => process.platform === "win32" ? p.replace(/^\/([A-Za-z])(\/|$)/, (m,d,s) => d.toUpperCase() + ":" + (s || "")) : p;
    const file = norm(process.env.MCP_FILE_ENV), url = process.env.MCP_URL_ENV;
    let j;
    try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { process.exit(3); }
    if (j && j.mcpServers && j.mcpServers.zensu && j.mcpServers.zensu.url === url) {
      delete j.mcpServers.zensu;
      process.stdout.write(JSON.stringify(j, null, 2) + "\n");
    } else { process.exit(3); }
  ' | { read -r first || exit 0; { printf '%s\n' "$first"; cat; } | json_write_atomic "$1"; }
}

# Allowed deletion root: a manifest entry may only be removed when it is an
# absolute path under the ACTIVE scope's .kiro dir (user scope: $HOME/.kiro;
# workspace scope: $PWD/.kiro) and contains no parent traversal. Deliberately
# scope-confined: a crafted WORKSPACE manifest in a malicious checkout must
# not be able to name user-scope files. The trailing slash in the pattern
# keeps sibling prefixes ($HOME/.kiro-evil) out.
path_allowed() { # $1=abs path
  case "$1" in
    *..*) return 1 ;;
    "$KIRO_DIR/"*) return 0 ;;
  esac
  return 1
}

write_manifest() { # $1=manifest file $2=list file $3=mcp file $4=mcp url
  MF="$1" LIST="$2" MCPF="$3" MCPU="$4" VERSION_VAL="$(cat "$SRC/VERSION" 2>/dev/null || echo '?')" node -e '
    const fs = require("fs");
    // fs targets normalized for Windows-native node. The recorded file paths
    // come from the LIST file CONTENT (never env-converted, stays POSIX); the
    // recorded mcpFile may arrive MSYS-converted — uninstall treats it as a
    // merged-or-not flag only and never compares or dereferences it as a path.
    const norm = p => process.platform === "win32" ? p.replace(/^\/([A-Za-z])(\/|$)/, (m,d,s) => d.toUpperCase() + ":" + (s || "")) : p;
    const lines = fs.readFileSync(norm(process.env.LIST), "utf8").trim().split("\n").filter(Boolean);
    const files = {};
    for (const l of lines) { const i = l.indexOf("\t"); files[l.slice(0, i)] = l.slice(i + 1); }
    fs.writeFileSync(norm(process.env.MF), JSON.stringify({
      version: process.env.VERSION_VAL,
      mcpFile: process.env.MCPF,
      mcpUrl: process.env.MCPU,
      files
    }, null, 2) + "\n");
  '
}

if [ "$UNINSTALL" -eq 1 ]; then
  if [ ! -f "$SCOPE_MANIFEST" ]; then
    echo "nothing to uninstall (no manifest at $SCOPE_MANIFEST)" >&2
    exit 0
  fi
  REC_MCP_FILE="$(node -e 'try{const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.mcpFile||"")}catch(_){}' "$SCOPE_MANIFEST")"
  REC_MCP_URL="$(node -e 'try{const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.mcpUrl||"")}catch(_){}' "$SCOPE_MANIFEST")"
  node -e '
    const m = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    for (const [p, hash] of Object.entries(m.files || {})) console.log(p + "\t" + hash);
  ' "$SCOPE_MANIFEST" | while IFS="$(printf '\t')" read -r p hash; do
    if ! path_allowed "$p"; then
      say "REFUSE  $p (outside allowed roots)"
      continue
    fi
    [ -f "$p" ] || continue
    cur="$(sha "$p")"
    if [ "$cur" = "$hash" ] || [ "$FORCE" -eq 1 ]; then
      say "REMOVE  $p"
      [ "$DRY" -eq 1 ] || rm -f "$p"
    else
      say "KEEP    $p (user-modified)"
    fi
  done
  if [ -n "$REC_MCP_FILE" ]; then
    # The recorded mcpFile is a merged-or-not FLAG only. The unmerge target is
    # ALWAYS the active scope's canonical settings file: a crafted manifest can
    # never point the unmerge elsewhere, and Windows path-form drift (MSYS env
    # conversion records C:/...8.3 forms while bash compares /tmp/... mounts)
    # cannot break the match. The recorded URL still guards foreign entries.
    unmerge_mcp "$MCP_FILE" "${REC_MCP_URL:-$REPO_MCP_URL}"
  fi
  if [ "$DRY" -ne 1 ]; then
    rm -f "$SCOPE_MANIFEST"
    find "$ZENSU_HOME" -type d -empty -delete 2>/dev/null || true
    find "$KIRO_DIR/skills" -type d -empty -delete 2>/dev/null || true
  fi
  say "uninstalled scope=$SCOPE. (~/.zensu user data left untouched; reset your default agent with: kiro-cli agent set-default <name>)"
  [ "$SCOPE" = "user" ] && say "note: workspace-scoped installs in other directories keep agent configs referencing the removed runtime — run --scope workspace --uninstall there, or reinstall user scope" 
  exit 0
fi

say "zensu-kiro installer — version $(cat "$SRC/VERSION" 2>/dev/null || echo '?') -> scope=$SCOPE$([ "$DRY" -eq 1 ] && echo ' (dry-run)')"

# 1) runtime home — always user-level (hook command paths are absolute), always
#    recorded in the USER manifest. plan-approved-delegate.sh is upstream
#    reference material with no Kiro wiring and is deliberately not shipped.
while IFS= read -r f; do
  rel="${f#"$SRC"/}"
  install_file "$f" "$ZENSU_HOME/$rel" "$USER_LIST"
done < <(find "$SRC/hooks" -type f \( -name '*.sh' -o -name '*.js' \) ! -name 'plan-approved-delegate.sh' | sort)
install_file "$SRC/VERSION" "$ZENSU_HOME/VERSION" "$USER_LIST"
install_file "$SRC/config.example.json" "$ZENSU_HOME/config.example.json" "$USER_LIST"
while IFS= read -r f; do
  install_file "$f" "$ZENSU_HOME/prompts/$(basename "$f")" "$USER_LIST"
done < <(find "$SRC/agents/prompts" -type f -name '*.md' | sort)

# 2) skills + agents — into the selected scope, recorded in the scope manifest
while IFS= read -r f; do
  rel="${f#"$SRC"/skills/}"
  install_file "$f" "$KIRO_DIR/skills/$rel" "$SCOPE_LIST"
done < <(find "$SRC/skills" -type f | sort)
while IFS= read -r f; do
  install_file "$f" "$KIRO_DIR/agents/$(basename "$f")" "$SCOPE_LIST" render
done < <(find "$SRC/agents/cli" -type f -name '*.json' | sort)
while IFS= read -r f; do
  install_file "$f" "$KIRO_DIR/agents/$(basename "$f")" "$SCOPE_LIST"
done < <(find "$SRC/agents/ide" -type f -name '*.md' | sort)

# 3) mcp merge (into the scope's settings file)
merge_mcp

# 4) ~/.zensu pointers (skills resolve the runtime through plugin-root)
if [ "$DRY" -ne 1 ]; then
  mkdir -p "$HOME/.zensu"
  printf '%s\n' "$ZENSU_HOME" > "$HOME/.zensu/plugin-root"
  say "WRITE   $HOME/.zensu/plugin-root -> $ZENSU_HOME"
  if [ ! -f "$HOME/.zensu/config.json" ]; then
    cp "$SRC/config.example.json" "$HOME/.zensu/config.json"
    say "SEED    $HOME/.zensu/config.json (from config.example.json)"
  fi
fi

# 5) manifests
if [ "$DRY" -ne 1 ]; then
  mkdir -p "$ZENSU_HOME"
  if [ "$SCOPE" = "workspace" ]; then
    # user manifest keeps runtime entries; preserve its previous skills/agents
    # records by merging: runtime list + existing user-scope entries that still
    # exist on disk and are not runtime files re-recorded above.
    USER_MCP_FILE=""; USER_MCP_URL=""   # only what a USER-scope run actually recorded
    if [ -f "$USER_MANIFEST" ]; then
      # Preserve the user manifest's previous skills/agents records (only for
      # files that still exist) AND its recorded mcp target — a workspace run
      # must not clobber a custom user-scope --mcp-url record.
      PREV_MCP_FILE="$(node -e 'try{const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.mcpFile||"")}catch(_){}' "$USER_MANIFEST")"
      PREV_MCP_URL="$(node -e 'try{const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(m.mcpUrl||"")}catch(_){}' "$USER_MANIFEST")"
      [ -n "$PREV_MCP_FILE" ] && USER_MCP_FILE="$PREV_MCP_FILE"
      [ -n "$PREV_MCP_URL" ] && USER_MCP_URL="$PREV_MCP_URL"
      node -e '
        const fs = require("fs");
        const m = JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
        for (const [p,h] of Object.entries(m.files||{})) console.log(p+"\t"+h);
      ' "$USER_MANIFEST" | while IFS="$(printf '\t')" read -r p h; do
        [ -f "$p" ] || continue
        case "$p" in "$ZENSU_HOME"/*) ;; *) printf '%s\t%s\n' "$p" "$h" >> "$USER_LIST" ;; esac
      done
    fi
    write_manifest "$USER_MANIFEST" "$USER_LIST" "$USER_MCP_FILE" "$USER_MCP_URL"
    write_manifest "$SCOPE_MANIFEST" "$SCOPE_LIST" "$MCP_FILE" "$MCP_URL"
  else
    cat "$SCOPE_LIST" >> "$USER_LIST"
    write_manifest "$USER_MANIFEST" "$USER_LIST" "$MCP_FILE" "$MCP_URL"
  fi
  say "WRITE   $SCOPE_MANIFEST"
fi

# 6) default agent (opt-in)
if [ "$DRY" -ne 1 ] && command -v kiro-cli >/dev/null 2>&1; then
  case "$SET_DEFAULT" in
    yes) kiro-cli agent set-default zensu && say "DEFAULT kiro-cli agent set-default zensu" ;;
    ask)
      if [ -t 0 ] && [ -t 1 ]; then
        printf "Make 'zensu' your default Kiro CLI agent (enables the TDD gate + review-chain hooks in every session)? [y/N] "
        read -r ans
        case "$ans" in y|Y|yes) kiro-cli agent set-default zensu && say "DEFAULT kiro-cli agent set-default zensu" ;; *) say "DEFAULT skipped (run: kiro-cli agent set-default zensu)" ;; esac
      else
        say "DEFAULT skipped (non-interactive; run: kiro-cli agent set-default zensu)"
      fi
      ;;
    no) say "DEFAULT skipped (--no-default; run: kiro-cli agent set-default zensu)" ;;
  esac
fi

say ""
say "done. Next steps:"
say "  kiro-cli chat --agent zensu          # OAuth to the zensu MCP runs on first @zensu call"
say "  /zensu-help                          # orientation; /zensu-tdd for gate-enforced TDD"
say "  headless: KIRO_API_KEY=... kiro-cli chat --no-interactive --agent zensu --trust-all-tools '<prompt>'"
if [ "$INSTALL_FAILED" -ne 0 ]; then
  echo "install completed WITH ERRORS (see ERROR lines above)" >&2
  exit 1
fi
exit 0
