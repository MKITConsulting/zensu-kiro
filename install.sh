#!/usr/bin/env bash
# zensu-kiro installer — Kiro CLI has no native plugin system, so this script
# delivers the plugin pieces onto the shared .kiro surfaces:
#
#   ~/.kiro/zensu/            hook runtime (hooks/, prompts/, VERSION, manifest)
#   <scope>/.kiro/skills/     11 Agent-Skills-standard skills (IDE + CLI)
#   <scope>/.kiro/agents/     4 CLI agent JSONs (rendered) + 3 IDE agent md
#   ~/.zensu/config.json      seeded from config.example.json if missing
#
# Zensu data access goes through the local `zensu` CLI (installed separately:
# curl -fsSL https://zensu.dev/install.sh | sh, then `zensu auth login`). This
# installer only checks for it and hints — it is not a hard dependency here.
#
# Usage:
#   install.sh [--scope user|workspace] [--uninstall] [--dry-run] [--force]
#              [--set-default|--no-default]
#
# Idempotent via manifests recording ABSOLUTE destinations + sha256: unmodified
# files are overwritten on upgrade, user-modified files are SKIPped (the
# previous record is carried forward; --force overwrites), and re-running the
# same version is a NOOP. A skipped skill/agent remains usable; a skipped runtime
# hook makes the complete runtime validation fail until explicit repair. The hook runtime is always user-level
# (hook command paths are absolute) and tracked in the user manifest
# (~/.kiro/zensu/manifest.json); workspace skills/agents are tracked in
# <workspace>/.kiro/zensu-manifest.json. --uninstall removes only manifest
# entries whose hash still matches, refusing any path outside the allowed roots.
set -u

SRC="$(cd "$(dirname "$0")" && pwd)"
SCOPE="user"
DRY=0
FORCE=0
UNINSTALL=0
SET_DEFAULT="ask"

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      [ $# -ge 2 ] || { echo "FATAL: --scope needs a value" >&2; exit 2; }
      SCOPE="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --force) FORCE=1; shift ;;
    --set-default) SET_DEFAULT="yes"; shift ;;
    --no-default) SET_DEFAULT="no"; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "FATAL: node is required (all JSON operations use node)" >&2; exit 1; }
INSTALL_SUPPORT="$SRC/scripts/install-support.js"
[ -f "$INSTALL_SUPPORT" ] || { echo "FATAL: installer support helper is missing" >&2; exit 1; }

configure_windows_native_tools() {
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      case "${BASH:-}" in /*) ;; *) return 1 ;; esac
      # Keep logical anchors raw in native Node while retaining normal MSYS
      # argv conversion for script/executable paths.
      local raw_name
      if [ "${MSYS2_ENV_CONV_EXCL:-}" != "*" ]; then
        for raw_name in ZENSU_KIRO_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_RAW ZENSU_KIRO_WORKSPACE_ANCHOR_RAW ZENSU_KIRO_TEST_ANCHOR_RAW ZENSU_KIRO_ROOT ZENSU_KIRO_RENDER_HOME_RAW; do
          case ";${MSYS2_ENV_CONV_EXCL:-};" in
            *";$raw_name;"*) ;;
            *) MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+${MSYS2_ENV_CONV_EXCL};}$raw_name" ;;
          esac
        done
      fi
      export MSYS2_ENV_CONV_EXCL
      local cygpath_posix="${BASH%/*}/cygpath.exe"
      local bash_posix="$BASH"
      case "$bash_posix" in *.exe) ;; *) [ -x "${bash_posix}.exe" ] && bash_posix="${bash_posix}.exe" ;; esac
      [ -x "$cygpath_posix" ] || return 1
      ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE="$("$cygpath_posix" -m "$cygpath_posix" 2>/dev/null)" || return 1
      ZENSU_KIRO_TRUSTED_BASH_NATIVE="$("$cygpath_posix" -m "$bash_posix" 2>/dev/null)" || return 1
      case "$ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE$ZENSU_KIRO_TRUSTED_BASH_NATIVE" in *[$'\r\n\t']*|'') return 1 ;; esac
      export ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE ZENSU_KIRO_TRUSTED_BASH_NATIVE
      ;;
  esac
}
configure_windows_native_tools || { echo "FATAL: cannot bind trusted Git Bash path tools" >&2; exit 1; }
NATIVE_ANCHOR_HELPER="$SRC/hooks/lib/resolve-native-anchor.js"
[ -f "$NATIVE_ANCHOR_HELPER" ] || { echo "FATAL: native anchor resolver is missing" >&2; exit 1; }
NATIVE_PID_HELPER="$SRC/hooks/lib/capture-native-shell-pid.sh"
[ -f "$NATIVE_PID_HELPER" ] || { echo "FATAL: native shell PID helper is missing" >&2; exit 1; }
. "$NATIVE_PID_HELPER"
ZENSU_KIRO_HOME_ANCHOR_RAW="${HOME:-}"
ZENSU_KIRO_HOME_ANCHOR_NATIVE="$(ZENSU_KIRO_ANCHOR_RAW="$ZENSU_KIRO_HOME_ANCHOR_RAW" node "$NATIVE_ANCHOR_HELPER" 2>&1)"; ANCHOR_RC=$?
[ "$ANCHOR_RC" -eq 0 ] || { echo "FATAL: unsafe HOME: $ZENSU_KIRO_HOME_ANCHOR_NATIVE" >&2; exit 1; }
ZENSU_KIRO_WORKSPACE_ANCHOR_RAW="$PWD"
ZENSU_KIRO_WORKSPACE_ANCHOR_NATIVE="$(ZENSU_KIRO_ANCHOR_RAW="$ZENSU_KIRO_WORKSPACE_ANCHOR_RAW" node "$NATIVE_ANCHOR_HELPER" 2>&1)"; ANCHOR_RC=$?
[ "$ANCHOR_RC" -eq 0 ] || { echo "FATAL: unsafe workspace path: $ZENSU_KIRO_WORKSPACE_ANCHOR_NATIVE" >&2; exit 1; }
export ZENSU_KIRO_HOME_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_NATIVE
export ZENSU_KIRO_WORKSPACE_ANCHOR_RAW ZENSU_KIRO_WORKSPACE_ANCHOR_NATIVE

BASE_ERROR="$(node "$INSTALL_SUPPORT" validate-base "${HOME:-}" 2>/dev/null)"; BASE_RC=$?
[ "$BASE_RC" -eq 0 ] || { echo "FATAL: unsafe HOME: $BASE_ERROR" >&2; exit 1; }
BASE_ERROR="$(node "$INSTALL_SUPPORT" validate-base "$PWD" 2>/dev/null)"; BASE_RC=$?
[ "$BASE_RC" -eq 0 ] || { echo "FATAL: unsafe workspace path: $BASE_ERROR" >&2; exit 1; }
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
if command -v zensu >/dev/null 2>&1; then
  if ! zensu auth status >/dev/null 2>&1; then
    echo "note: zensu CLI found but not authenticated — run 'zensu auth login' to enable Zensu data access" >&2
  fi
else
  echo "note: zensu CLI not found on PATH — the plugin drives Zensu through it; install with 'curl -fsSL https://zensu.dev/install.sh | sh' then 'zensu auth login' (files install fine without it)" >&2
fi

USER_ANCHOR="$HOME"
USER_ROOT="$HOME/.kiro"
ZENSU_HOME="$USER_ROOT/zensu"
case "$SCOPE" in
  user)      SCOPE_ANCHOR="$HOME"; KIRO_DIR="$USER_ROOT" ;;
  workspace) SCOPE_ANCHOR="$PWD"; KIRO_DIR="$PWD/.kiro" ;;
  *) echo "FATAL: --scope must be user or workspace" >&2; exit 2 ;;
esac
USER_MANIFEST="$ZENSU_HOME/manifest.json"
if [ "$SCOPE" = "workspace" ]; then
  SCOPE_MANIFEST="$KIRO_DIR/zensu-manifest.json"
else
  SCOPE_MANIFEST="$USER_MANIFEST"
fi

say() { printf '%s\n' "$*"; }

# One lock covers the complete shared-runtime publication transaction. Dry-run
# remains write-free and therefore intentionally does not acquire it.
LOCK_DIR="$HOME/.zensu-kiro-install.lock"
LOCK_HELD=0
LOCK_TOKEN=""
LOCK_OWNER_PID="1"
if [ "$DRY" -eq 0 ]; then
  LOCK_PID_FILE="$(mktemp)" || { echo "FATAL: cannot allocate native PID capture" >&2; exit 1; }
  if ! zensu_capture_native_shell_pid "$LOCK_PID_FILE"; then
    rm -f "$LOCK_PID_FILE"
    echo "FATAL: cannot determine native shell PID for install lock" >&2
    exit 1
  fi
  IFS= read -r LOCK_OWNER_PID < "$LOCK_PID_FILE" || LOCK_OWNER_PID=""
  rm -f "$LOCK_PID_FILE"
  case "$LOCK_OWNER_PID" in ''|*[!0-9]*) echo "FATAL: invalid native shell PID for install lock" >&2; exit 1 ;; esac
fi
USER_LIST=""; SCOPE_LIST=""; PRESERVE_LIST=""
cleanup() {
  [ -n "$USER_LIST" ] && rm -f "$USER_LIST" 2>/dev/null
  [ -n "$SCOPE_LIST" ] && rm -f "$SCOPE_LIST" 2>/dev/null
  [ -n "$PRESERVE_LIST" ] && rm -f "$PRESERVE_LIST" 2>/dev/null
  if [ "$LOCK_HELD" -eq 1 ]; then
    node "$INSTALL_SUPPORT" release-lock "$HOME" "$LOCK_DIR" "$LOCK_OWNER_PID" "$LOCK_TOKEN" >/dev/null 2>&1 || true
    LOCK_HELD=0
    LOCK_TOKEN=""
  fi
}
exit_on_signal() {
  local code="$1"
  trap - EXIT HUP INT TERM
  cleanup
  exit "$code"
}
trap cleanup EXIT
trap 'exit_on_signal 129' HUP
trap 'exit_on_signal 130' INT
trap 'exit_on_signal 143' TERM

acquire_install_lock() {
  local attempt=0 result rc
  [ "$DRY" -eq 1 ] && return 0
  while [ "$attempt" -lt 1200 ]; do
    result="$(node "$INSTALL_SUPPORT" acquire-lock "$HOME" "$LOCK_DIR" "$LOCK_OWNER_PID" 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ]; then LOCK_TOKEN="$result"; LOCK_HELD=1; return 0; fi
    if [ "$rc" -ne 75 ]; then
      echo "FATAL: cannot acquire install lock: $result" >&2
      exit 1
    fi
    attempt=$((attempt + 1))
    sleep 0.05
  done
  echo "FATAL: timed out waiting for shared Kiro install lock $LOCK_DIR" >&2
  exit 1
}

release_install_lock() {
  [ "$LOCK_HELD" -eq 1 ] || return 0
  local result rc
  result="$(node "$INSTALL_SUPPORT" release-lock "$HOME" "$LOCK_DIR" "$LOCK_OWNER_PID" "$LOCK_TOKEN" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FATAL: cannot release install lock: $result" >&2; exit 1; }
  LOCK_HELD=0
  LOCK_TOKEN=""
}

acquire_install_lock

if [ "${NODE_ENV:-}" = "test" ] && [ -n "${ZENSU_INSTALL_TEST_AFTER_LOCK_DIR:-}" ]; then
  printf 'reached\n' > "$ZENSU_INSTALL_TEST_AFTER_LOCK_DIR/reached"
  while [ ! -e "$ZENSU_INSTALL_TEST_AFTER_LOCK_DIR/release" ]; do sleep 0.02; done
fi

recover_target() { # $1=root $2=target $3=anchor
  [ "$DRY" -eq 1 ] && return 0
  local result rc
  result="$(node "$INSTALL_SUPPORT" recover-target "$1" "$2" "$3" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FATAL: cannot recover interrupted publication for $2: $result" >&2; exit 1; }
}

preflight_manifest() { # $1=manifest $2=installed VERSION $3=root $4=anchor
  local manifest="$1" installed_version="$2" root="$3" anchor="$4" result rc
  result="$(node "$INSTALL_SUPPORT" preflight "$manifest" "$installed_version" "$(cat "$SRC/VERSION")" "$root" "$anchor" "$UNINSTALL" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] && return 0
  # --force may explicitly replace a valid but incompatible version. It never
  # discards malformed manifest provenance: without a trustworthy old file
  # inventory, obsolete hooks cannot be reconciled safely before publication.
  if [ "$UNINSTALL" -eq 0 ] && [ "$FORCE" -eq 1 ] && [ "$rc" -eq 4 ]; then
    say "FORCE   $manifest ($result)"
    return 0
  fi
  if [ "$rc" -eq 5 ]; then
    echo "FATAL: refusing install: $result; --force cannot discard malformed manifest provenance — restore or quarantine the manifest after review" >&2
    exit 1
  fi
  echo "FATAL: refusing install: $result; use --force only after reviewing the installed runtime" >&2
  exit 1
}

recover_target "$USER_ROOT" "$USER_MANIFEST" "$USER_ANCHOR"
preflight_manifest "$USER_MANIFEST" "$ZENSU_HOME/VERSION" "$USER_ROOT" "$USER_ANCHOR"
if [ "$SCOPE" = "workspace" ]; then
  recover_target "$KIRO_DIR" "$SCOPE_MANIFEST" "$SCOPE_ANCHOR"
  preflight_manifest "$SCOPE_MANIFEST" "" "$KIRO_DIR" "$SCOPE_ANCHOR"
fi

manifest_lookup() { # $1=manifest $2=abs path $3=root $4=anchor
  local result rc
  result="$(node "$INSTALL_SUPPORT" manifest-lookup "$1" "$2" "$3" "$4" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FATAL: cannot read manifest safely: $result" >&2
    exit 1
  fi
  printf '%s' "$result"
}

USER_LIST="$(mktemp)"; SCOPE_LIST="$(mktemp)"; PRESERVE_LIST="$(mktemp)"
INSTALL_FAILED=0

# install_file <src> <dst> <list> <allowed-root> <anchor> [render]
install_file() {
  local src="$1" dst="$2" list="$3" root="$4" anchor="$5" render="${6:-no}"
  local content old want recorded state result rc executable=0 expected_hash="-"
  if [ "$render" = "render" ]; then
    content="$(ZENSU_KIRO_RENDER_HOME_RAW="$ZENSU_HOME" node "$INSTALL_SUPPORT" render-json < "$src" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || { echo "FATAL: cannot render $src safely: $content" >&2; exit 1; }
  else
    content="$(cat "$src")"
  fi
  want="$(printf '%s\n' "$content" | sha_stdin)"
  recover_target "$root" "$dst" "$anchor"
  state="$(node "$INSTALL_SUPPORT" state "$root" "$dst" "$anchor" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FATAL: unsafe install destination $dst: $state" >&2; exit 1; }
  [ "$state" != "other" ] || { echo "FATAL: install destination is not a regular file: $dst" >&2; exit 1; }
  if [ "$state" = "file" ]; then
    old="$(sha "$dst")"
    if [ "$old" = "$want" ]; then
      say "NOOP    $dst"
      printf '%s\t%s\n' "$dst" "$want" >> "$list"
      return 0
    fi
    recorded="$(manifest_lookup "$USER_MANIFEST" "$dst" "$USER_ROOT" "$USER_ANCHOR")"
    [ -n "$recorded" ] || recorded="$(manifest_lookup "$SCOPE_MANIFEST" "$dst" "$KIRO_DIR" "$SCOPE_ANCHOR")"
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
    expected_hash="$old"
  else
    say "CREATE  $dst"
  fi
  [ "$DRY" -eq 1 ] && { printf '%s\t%s\n' "$dst" "$want" >> "$list"; return 0; }
  case "$dst" in *.sh) executable=1 ;; esac
  result="$(printf '%s\n' "$content" | node "$INSTALL_SUPPORT" atomic-write "$root" "$dst" "$anchor" "$executable" "$state" "$expected_hash" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    # Record ONLY successful writes — a failed write must not poison the
    # manifest with a hash the on-disk file does not have.
    printf '%s\t%s\n' "$dst" "$want" >> "$list"
  else
    say "ERROR   $dst (safe write failed: $result; not recorded)"
    INSTALL_FAILED=1
    return 1
  fi
}

write_manifest() { # $1=manifest $2=list $3=root $4=anchor
  local result rc
  result="$(node "$INSTALL_SUPPORT" write-manifest "$1" "$(cat "$SRC/VERSION" 2>/dev/null || echo '?')" "$3" "$4" < "$2" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FATAL: cannot publish manifest safely: $result" >&2; exit 1; }
}

if [ "$UNINSTALL" -eq 1 ]; then
  MANIFEST_STATE="$(node "$INSTALL_SUPPORT" state "$KIRO_DIR" "$SCOPE_MANIFEST" "$SCOPE_ANCHOR" 2>/dev/null)"; RC=$?
  [ "$RC" -eq 0 ] || { echo "FATAL: unsafe uninstall manifest: $MANIFEST_STATE" >&2; exit 1; }
  if [ "$MANIFEST_STATE" = "missing" ]; then
    echo "nothing to uninstall (no manifest at $SCOPE_MANIFEST)" >&2
    exit 0
  fi
  [ "$MANIFEST_STATE" = "file" ] || { echo "FATAL: uninstall manifest is not a regular file" >&2; exit 1; }
  MANIFEST_HASH="$(sha "$SCOPE_MANIFEST")"
  MANIFEST_DUMP="$(node "$INSTALL_SUPPORT" manifest-lines "$SCOPE_MANIFEST" "$KIRO_DIR" "$SCOPE_ANCHOR" 2>/dev/null)"; RC=$?
  [ "$RC" -eq 0 ] || { echo "FATAL: cannot read uninstall manifest safely: $MANIFEST_DUMP" >&2; exit 1; }
  printf '%s\n' "$MANIFEST_DUMP" > "$SCOPE_LIST"
  while IFS="$(printf '\t')" read -r p hash; do
    [ -n "$p" ] || continue
    recover_target "$KIRO_DIR" "$p" "$SCOPE_ANCHOR"
    FILE_STATE="$(node "$INSTALL_SUPPORT" state "$KIRO_DIR" "$p" "$SCOPE_ANCHOR" 2>/dev/null)"; RC=$?
    [ "$RC" -eq 0 ] || { echo "FATAL: unsafe uninstall path $p: $FILE_STATE" >&2; exit 1; }
    [ "$FILE_STATE" = "missing" ] && continue
    [ "$FILE_STATE" = "file" ] || { echo "FATAL: uninstall target is not a regular file: $p" >&2; exit 1; }
    cur="$(sha "$p")"
    if [ "$cur" = "$hash" ] || [ "$FORCE" -eq 1 ]; then
      say "REMOVE  $p"
      if [ "$DRY" -ne 1 ]; then
        REMOVE_ERROR="$(node "$INSTALL_SUPPORT" remove "$KIRO_DIR" "$p" "$SCOPE_ANCHOR" "$cur" 2>/dev/null)"; RC=$?
        [ "$RC" -eq 0 ] || { echo "FATAL: safe remove failed for $p: $REMOVE_ERROR" >&2; exit 1; }
      fi
    else
      say "KEEP    $p (user-modified)"
    fi
  done < "$SCOPE_LIST"
  if [ "$DRY" -ne 1 ]; then
    REMOVE_ERROR="$(node "$INSTALL_SUPPORT" remove "$KIRO_DIR" "$SCOPE_MANIFEST" "$SCOPE_ANCHOR" "$MANIFEST_HASH" 2>/dev/null)"; RC=$?
    [ "$RC" -eq 0 ] || { echo "FATAL: safe manifest removal failed: $REMOVE_ERROR" >&2; exit 1; }
    find "$ZENSU_HOME" -type d -empty -delete 2>/dev/null || true
    find "$KIRO_DIR/skills" -type d -empty -delete 2>/dev/null || true
  fi
  say "uninstalled scope=$SCOPE. (~/.zensu user data left untouched; reset your default agent with: kiro-cli agent set-default <name>)"
  [ "$SCOPE" = "user" ] && say "note: workspace-scoped installs in other directories keep agent configs referencing the removed runtime — run --scope workspace --uninstall there, or reinstall user scope" 
  exit 0
fi

say "zensu-kiro installer — version $(cat "$SRC/VERSION" 2>/dev/null || echo '?') -> scope=$SCOPE$([ "$DRY" -eq 1 ] && echo ' (dry-run)')"

# 1) runtime home — always user-level (hook command paths are absolute), always
#    recorded in the USER manifest. The declarative inventory is also embedded
#    into the resolver at development time and excludes installer-only support.
while IFS= read -r rel; do
  case "$rel" in ""|/*|../*|*/../*|*/..) echo "FATAL: invalid runtime inventory entry: $rel" >&2; exit 1 ;; esac
  [ -f "$SRC/$rel" ] || { echo "FATAL: runtime inventory source is missing: $rel" >&2; exit 1; }
  install_file "$SRC/$rel" "$ZENSU_HOME/$rel" "$USER_LIST" "$USER_ROOT" "$USER_ANCHOR"
done < "$SRC/runtime-files.txt"
install_file "$SRC/config.example.json" "$ZENSU_HOME/config.example.json" "$USER_LIST" "$USER_ROOT" "$USER_ANCHOR"
while IFS= read -r f; do
  install_file "$f" "$ZENSU_HOME/prompts/$(basename "$f")" "$USER_LIST" "$USER_ROOT" "$USER_ANCHOR"
done < <(find "$SRC/agents/prompts" -type f -name '*.md' | sort)

# 2) skills + agents — into the selected scope, recorded in the scope manifest
while IFS= read -r f; do
  rel="${f#"$SRC"/skills/}"
  install_file "$f" "$KIRO_DIR/skills/$rel" "$SCOPE_LIST" "$KIRO_DIR" "$SCOPE_ANCHOR"
done < <(find "$SRC/skills" -type f | sort)
while IFS= read -r f; do
  install_file "$f" "$KIRO_DIR/agents/$(basename "$f")" "$SCOPE_LIST" "$KIRO_DIR" "$SCOPE_ANCHOR" render
done < <(find "$SRC/agents/cli" -type f -name '*.json' | sort)
while IFS= read -r f; do
  install_file "$f" "$KIRO_DIR/agents/$(basename "$f")" "$SCOPE_LIST" "$KIRO_DIR" "$SCOPE_ANCHOR"
done < <(find "$SRC/agents/ide" -type f -name '*.md' | sort)

# Reconcile runtime files that were managed by the previous manifest but are no
# longer part of this release. Unmodified files are CAS-removed; modified files
# remain untouched and abort publication with an actionable repair message.
reconcile_obsolete_runtime() {
  local previous p hash state current result rc
  state="$(node "$INSTALL_SUPPORT" state "$USER_ROOT" "$USER_MANIFEST" "$USER_ANCHOR" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || { echo "FATAL: unsafe user manifest during obsolete-runtime reconciliation: $state" >&2; exit 1; }
  [ "$state" = "file" ] || return 0
  previous="$(node "$INSTALL_SUPPORT" manifest-lines "$USER_MANIFEST" "$USER_ROOT" "$USER_ANCHOR" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FATAL: cannot inspect previous runtime inventory: $previous" >&2
    exit 1
  fi
  while IFS="$(printf '\t')" read -r p hash; do
    [ -n "$p" ] || continue
    case "$p" in "$ZENSU_HOME"/*) ;; *) continue ;; esac
    if awk -F "$(printf '\t')" -v wanted="$p" '$1 == wanted { found=1 } END { exit found ? 0 : 1 }' "$USER_LIST"; then
      continue
    fi
    recover_target "$USER_ROOT" "$p" "$USER_ANCHOR"
    state="$(node "$INSTALL_SUPPORT" state "$USER_ROOT" "$p" "$USER_ANCHOR" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || { echo "FATAL: unsafe obsolete runtime path $p: $state" >&2; exit 1; }
    [ "$state" = "missing" ] && continue
    [ "$state" = "file" ] || { echo "FATAL: obsolete runtime path is not a regular file: $p" >&2; exit 1; }
    current="$(sha "$p")"
    if [ "$current" = "$hash" ] || [ "$FORCE" -eq 1 ]; then
      say "REMOVE  $p (obsolete runtime)"
      if [ "$DRY" -ne 1 ]; then
        result="$(node "$INSTALL_SUPPORT" remove "$USER_ROOT" "$p" "$USER_ANCHOR" "$current" 2>/dev/null)"; rc=$?
        [ "$rc" -eq 0 ] || { echo "FATAL: safe obsolete-runtime removal failed for $p: $result" >&2; exit 1; }
      fi
    else
      say "ERROR   $p (obsolete runtime is user-modified; review it, then rerun with --force to remove)"
      INSTALL_FAILED=1
    fi
  done <<EOF
$previous
EOF
}
reconcile_obsolete_runtime

# Never publish configuration or manifests for a partial candidate. The old
# manifest intentionally remains authoritative so the resolver fails closed
# until a clean retry (or explicit repair) completes.
if [ "$INSTALL_FAILED" -ne 0 ]; then
  echo "FATAL: one or more files failed to install; manifests were not published" >&2
  exit 1
fi

# 3) Shared Zensu config. The runtime has a fixed Kiro-owned location;
#    legacy shared root-pointer files are deliberately ignored and preserved.
if [ "$DRY" -ne 1 ]; then
  CONFIG_ROOT="$HOME/.zensu"; CONFIG_FILE="$CONFIG_ROOT/config.json"
  MKDIR_ERROR="$(node "$INSTALL_SUPPORT" mkdir "$CONFIG_ROOT" "$CONFIG_ROOT" "$HOME" 2>/dev/null)"; RC=$?
  [ "$RC" -eq 0 ] || { echo "FATAL: cannot create config directory safely: $MKDIR_ERROR" >&2; exit 1; }
  CONFIG_STATE="$(node "$INSTALL_SUPPORT" state "$CONFIG_ROOT" "$CONFIG_FILE" "$HOME" 2>/dev/null)"; RC=$?
  [ "$RC" -eq 0 ] || { echo "FATAL: unsafe config destination: $CONFIG_STATE" >&2; exit 1; }
  [ "$CONFIG_STATE" != "other" ] || { echo "FATAL: config destination is not a regular file" >&2; exit 1; }
  if [ "$CONFIG_STATE" = "missing" ]; then
    CONFIG_ERROR="$(node "$INSTALL_SUPPORT" atomic-write "$CONFIG_ROOT" "$CONFIG_FILE" "$HOME" 0 missing - < "$SRC/config.example.json" 2>/dev/null)"; RC=$?
    [ "$RC" -eq 0 ] || { echo "FATAL: cannot seed config safely: $CONFIG_ERROR" >&2; exit 1; }
    say "SEED    $HOME/.zensu/config.json (from config.example.json)"
  fi
fi

# 4) manifests
if [ "$DRY" -ne 1 ]; then
  if [ "$SCOPE" = "workspace" ]; then
    # user manifest keeps runtime entries; preserve its previous skills/agents
    # records by merging: runtime list + existing user-scope entries that still
    # exist on disk and are not runtime files re-recorded above.
    USER_MANIFEST_STATE="$(node "$INSTALL_SUPPORT" state "$USER_ROOT" "$USER_MANIFEST" "$USER_ANCHOR" 2>/dev/null)"; RC=$?
    [ "$RC" -eq 0 ] || { echo "FATAL: unsafe user manifest: $USER_MANIFEST_STATE" >&2; exit 1; }
    if [ "$USER_MANIFEST_STATE" = "file" ]; then
      # Preserve the user manifest's previous skills/agents records (only for
      # files that still exist).
      PRESERVED="$(node "$INSTALL_SUPPORT" manifest-lines "$USER_MANIFEST" "$USER_ROOT" "$USER_ANCHOR" 2>/dev/null)"; RC=$?
      if [ "$RC" -ne 0 ]; then
        echo "FATAL: cannot preserve user manifest safely: $PRESERVED" >&2
        exit 1
      fi
      printf '%s\n' "$PRESERVED" > "$PRESERVE_LIST"
      while IFS="$(printf '\t')" read -r p h; do
        [ -n "$p" ] || continue
        PRESERVE_STATE="$(node "$INSTALL_SUPPORT" state "$USER_ROOT" "$p" "$USER_ANCHOR" 2>/dev/null)"; RC=$?
        [ "$RC" -eq 0 ] || { echo "FATAL: unsafe preserved path $p: $PRESERVE_STATE" >&2; exit 1; }
        [ "$PRESERVE_STATE" = "file" ] || continue
        case "$p" in "$ZENSU_HOME"/*) ;; *) printf '%s\t%s\n' "$p" "$h" >> "$USER_LIST" ;; esac
      done < "$PRESERVE_LIST"
    fi
    write_manifest "$USER_MANIFEST" "$USER_LIST" "$USER_ROOT" "$USER_ANCHOR"
    write_manifest "$SCOPE_MANIFEST" "$SCOPE_LIST" "$KIRO_DIR" "$SCOPE_ANCHOR"
  else
    cat "$SCOPE_LIST" >> "$USER_LIST"
    write_manifest "$USER_MANIFEST" "$USER_LIST" "$USER_ROOT" "$USER_ANCHOR"
  fi
  say "WRITE   $SCOPE_MANIFEST"
fi

# Validate the fixed runtime through the same fail-closed resolver used by the
# skills. Every executable runtime hook is checked; user-modified skills/agents
# remain governed by the existing manifest carry-forward policy. Preserving a
# modified runtime hook intentionally leaves the runtime invalid until the user
# reviews it and repairs explicitly with --force.
if [ "$DRY" -ne 1 ]; then
  if HOME="$HOME" ZENSU_KIRO_LOCK_OWNER_PID="$LOCK_OWNER_PID" ZENSU_KIRO_LOCK_TOKEN="$LOCK_TOKEN" \
    bash "$ZENSU_HOME/hooks/lib/resolve-plugin-root.sh" 1 >/dev/null 2>&1; then
    say "VALIDATE $ZENSU_HOME (VERSION + protocol + manifest + complete runtime closure)"
  else
    echo "FATAL: installed Zensu Kiro runtime failed VERSION/manifest integrity validation" >&2
    exit 1
  fi
fi

# Publication is complete once the resolver validates runtime+manifest. Do not
# hold the installer lock while waiting for an optional interactive CLI prompt.
release_install_lock

# 5) default agent (opt-in)
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
say "  zensu auth login                     # the plugin drives Zensu through the local zensu CLI"
say "                                       # install it first if missing: curl -fsSL https://zensu.dev/install.sh | sh"
say "  kiro-cli chat --agent zensu          # start a session"
say "  /zensu-help                          # orientation; /zensu-tdd for gate-enforced TDD"
say "  headless: KIRO_API_KEY=... kiro-cli chat --no-interactive --agent zensu --trust-all-tools '<prompt>'"
if [ "$INSTALL_FAILED" -ne 0 ]; then
  echo "install completed WITH ERRORS (see ERROR lines above)" >&2
  exit 1
fi
exit 0
