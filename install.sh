#!/usr/bin/env bash
# zensu-kiro installer — Kiro CLI has no native plugin system, so this script
# delivers the plugin pieces onto the shared .kiro surfaces:
#
#   ~/.kiro/zensu/            hook runtime (hooks/, prompts/, VERSION, manifest)
#   ~/.kiro/skills/zensu-*    11 Agent-Skills-standard skills (IDE + CLI)
#   ~/.kiro/agents/           4 CLI agent JSONs (rendered) + 3 IDE agent md
#   ~/.kiro/settings/mcp.json zensu remote MCP server (merged, never stomped)
#   ~/.zensu/plugin-root      runtime-home pointer the skills depend on
#   ~/.zensu/config.json      seeded from config.example.json if missing
#
# Usage:
#   install.sh [--scope user|workspace] [--uninstall] [--dry-run] [--force]
#              [--set-default|--no-default] [--mcp-url <url>]
#
# Idempotent via manifest.json (sha256 per installed file): unmodified files
# are overwritten on upgrade, user-modified files are SKIPped (use --force),
# re-running the same version is a NOOP. --uninstall removes only files whose
# hash still matches the manifest and only our mcp.json entry.
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
    --scope) SCOPE="${2:-user}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --set-default) SET_DEFAULT="yes"; shift ;;
    --no-default) SET_DEFAULT="no"; shift ;;
    --mcp-url) MCP_URL="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "FATAL: node is required (all JSON operations use node)" >&2; exit 1; }
command -v kiro-cli >/dev/null 2>&1 || echo "note: kiro-cli not found on PATH — files install fine, install the CLI later" >&2

ZENSU_HOME="$HOME/.kiro/zensu"
case "$SCOPE" in
  user)      KIRO_DIR="$HOME/.kiro" ;;
  workspace) KIRO_DIR="$PWD/.kiro" ;;
  *) echo "FATAL: --scope must be user or workspace" >&2; exit 2 ;;
esac
MANIFEST="$ZENSU_HOME/manifest.json"
MCP_FILE="$KIRO_DIR/settings/mcp.json"
REPO_MCP_URL="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).mcpServers.zensu.url)' "$SRC/mcp.json" 2>/dev/null || echo "https://mcp.zensu.dev/mcp")"
[ -n "$MCP_URL" ] || MCP_URL="$REPO_MCP_URL"

sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
say() { printf '%s\n' "$*"; }

manifest_hash() { # $1=relpath -> recorded hash or empty
  [ -f "$MANIFEST" ] || return 0
  REL="$1" node -e '
    try {
      const m = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
      process.stdout.write((m.files && m.files[process.env.REL]) || "");
    } catch (_) {}
  ' "$MANIFEST" 2>/dev/null
}

INSTALLED_LIST="$(mktemp)"
trap 'rm -f "$INSTALLED_LIST"' EXIT

# install_file <src-abs> <dst-abs> <manifest-relpath> [render]
install_file() {
  local src="$1" dst="$2" rel="$3" render="${4:-no}" content tmp old want
  if [ "$render" = "render" ]; then
    content="$(sed "s|__ZENSU_HOME__|$ZENSU_HOME|g" "$src")"
  else
    content="$(cat "$src")"
  fi
  want="$(printf '%s\n' "$content" | shasum -a 256 | cut -d' ' -f1)"
  if [ -f "$dst" ]; then
    old="$(sha "$dst")"
    if [ "$old" = "$want" ]; then
      say "NOOP    $rel"
      printf '%s\t%s\n' "$rel" "$want" >> "$INSTALLED_LIST"
      return 0
    fi
    recorded="$(manifest_hash "$rel")"
    if [ -n "$recorded" ] && [ "$old" != "$recorded" ] && [ "$FORCE" -ne 1 ]; then
      say "SKIP    $rel (user-modified; --force to overwrite)"
      return 0
    fi
    say "UPDATE  $rel"
  else
    say "CREATE  $rel"
  fi
  [ "$DRY" -eq 1 ] && { printf '%s\t%s\n' "$rel" "$want" >> "$INSTALLED_LIST"; return 0; }
  mkdir -p "$(dirname "$dst")"
  tmp="$(mktemp "$(dirname "$dst")/.zensu-install.XXXXXX")" || return 1
  printf '%s\n' "$content" > "$tmp" && mv "$tmp" "$dst"
  case "$dst" in *.sh) chmod +x "$dst" ;; esac
  printf '%s\t%s\n' "$rel" "$want" >> "$INSTALLED_LIST"
}

merge_mcp() {
  say "MERGE   $MCP_FILE (mcpServers.zensu -> $MCP_URL)"
  [ "$DRY" -eq 1 ] && return 0
  mkdir -p "$(dirname "$MCP_FILE")"
  MCP_FILE_ENV="$MCP_FILE" MCP_URL_ENV="$MCP_URL" FORCE_ENV="$FORCE" node -e '
    const fs = require("fs");
    const file = process.env.MCP_FILE_ENV, url = process.env.MCP_URL_ENV;
    let j = {};
    try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) {}
    if (typeof j !== "object" || j === null) j = {};
    j.mcpServers = j.mcpServers || {};
    const existing = j.mcpServers.zensu;
    if (existing && existing.url !== url && process.env.FORCE_ENV !== "1") {
      console.error("warn: mcpServers.zensu already exists with a different url (" + existing.url + ") — left untouched (--force to overwrite)");
      process.exit(0);
    }
    j.mcpServers.zensu = { url };
    fs.writeFileSync(file, JSON.stringify(j, null, 2) + "\n");
  '
}

unmerge_mcp() {
  [ -f "$MCP_FILE" ] || return 0
  say "UNMERGE $MCP_FILE (remove mcpServers.zensu if ours)"
  [ "$DRY" -eq 1 ] && return 0
  MCP_FILE_ENV="$MCP_FILE" MCP_URL_ENV="$MCP_URL" node -e '
    const fs = require("fs");
    const file = process.env.MCP_FILE_ENV, url = process.env.MCP_URL_ENV;
    let j;
    try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (_) { process.exit(0); }
    if (j && j.mcpServers && j.mcpServers.zensu && j.mcpServers.zensu.url === url) {
      delete j.mcpServers.zensu;
      fs.writeFileSync(file, JSON.stringify(j, null, 2) + "\n");
    }
  '
}

if [ "$UNINSTALL" -eq 1 ]; then
  if [ ! -f "$MANIFEST" ]; then
    echo "nothing to uninstall (no manifest at $MANIFEST)" >&2
    exit 0
  fi
  node -e '
    const m = JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
    for (const [rel, hash] of Object.entries(m.files || {})) console.log(rel + "\t" + hash);
  ' "$MANIFEST" | while IFS="$(printf '\t')" read -r rel hash; do
    dst="$HOME/$rel"
    [ -f "$dst" ] || continue
    cur="$(sha "$dst")"
    if [ "$cur" = "$hash" ] || [ "$FORCE" -eq 1 ]; then
      say "REMOVE  $rel"
      [ "$DRY" -eq 1 ] || rm -f "$dst"
    else
      say "KEEP    $rel (user-modified)"
    fi
  done
  unmerge_mcp
  if [ "$DRY" -ne 1 ]; then
    rm -f "$MANIFEST"
    find "$ZENSU_HOME" -type d -empty -delete 2>/dev/null || true
    find "$HOME/.kiro/skills" -type d -empty -delete 2>/dev/null || true
  fi
  say "uninstalled. (~/.zensu user data left untouched; reset your default agent with: kiro-cli agent set-default <name>)"
  exit 0
fi

say "zensu-kiro installer — version $(cat "$SRC/VERSION" 2>/dev/null || echo '?') -> scope=$SCOPE${DRY:+}$([ "$DRY" -eq 1 ] && echo ' (dry-run)')"

# 1) runtime home (always under ~/.kiro/zensu — hook command paths are absolute)
while IFS= read -r f; do
  rel="${f#"$SRC"/}"
  install_file "$f" "$ZENSU_HOME/$rel" ".kiro/zensu/$rel"
done < <(find "$SRC/hooks" -type f \( -name '*.sh' -o -name '*.js' \) | sort)
install_file "$SRC/VERSION" "$ZENSU_HOME/VERSION" ".kiro/zensu/VERSION"
install_file "$SRC/config.example.json" "$ZENSU_HOME/config.example.json" ".kiro/zensu/config.example.json"
while IFS= read -r f; do
  rel="prompts/$(basename "$f")"
  install_file "$f" "$ZENSU_HOME/$rel" ".kiro/zensu/$rel"
done < <(find "$SRC/agents/prompts" -type f -name '*.md' | sort)

# 2) skills (whole folders, incl. references/)
while IFS= read -r f; do
  rel="${f#"$SRC"/skills/}"
  install_file "$f" "$KIRO_DIR/skills/$rel" "$(basename "$KIRO_DIR")/skills/$rel"
done < <(find "$SRC/skills" -type f | sort)

# 3) agents: CLI JSONs rendered, IDE md verbatim
while IFS= read -r f; do
  rel="agents/$(basename "$f")"
  install_file "$f" "$KIRO_DIR/$rel" "$(basename "$KIRO_DIR")/$rel" render
done < <(find "$SRC/agents/cli" -type f -name '*.json' | sort)
while IFS= read -r f; do
  rel="agents/$(basename "$f")"
  install_file "$f" "$KIRO_DIR/$rel" "$(basename "$KIRO_DIR")/$rel"
done < <(find "$SRC/agents/ide" -type f -name '*.md' | sort)

# 4) mcp merge
merge_mcp

# 5) ~/.zensu pointers (skills resolve the runtime through plugin-root)
if [ "$DRY" -ne 1 ]; then
  mkdir -p "$HOME/.zensu"
  printf '%s\n' "$ZENSU_HOME" > "$HOME/.zensu/plugin-root"
  say "WRITE   .zensu/plugin-root -> $ZENSU_HOME"
  if [ ! -f "$HOME/.zensu/config.json" ]; then
    cp "$SRC/config.example.json" "$HOME/.zensu/config.json"
    say "SEED    .zensu/config.json (from config.example.json)"
  fi
fi

# 6) manifest
if [ "$DRY" -ne 1 ]; then
  mkdir -p "$ZENSU_HOME"
  VERSION_VAL="$(cat "$SRC/VERSION" 2>/dev/null || echo '?')" node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").filter(Boolean);
    const files = {};
    for (const l of lines) { const [rel, hash] = l.split("\t"); files[rel] = hash; }
    fs.writeFileSync(process.argv[2], JSON.stringify({ version: process.env.VERSION_VAL, files }, null, 2) + "\n");
  ' "$INSTALLED_LIST" "$MANIFEST"
  say "WRITE   .kiro/zensu/manifest.json ($(wc -l < "$INSTALLED_LIST" | tr -d '[:space:]') files)"
fi

# 7) default agent (opt-in)
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
exit 0
