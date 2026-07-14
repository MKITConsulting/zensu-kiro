#!/usr/bin/env bash
# Test-only helper. It deliberately lives outside runtime-files.txt so shipped
# hooks have no ambient test escape hatch: shim tests execute a complete runtime
# installed exactly as Kiro would use it.

zensu_prepare_kiro_runtime_fixture() { # $1=source root $2=fixture HOME
  local source_root="$1" fixture_home="$2"
  mkdir -p "$fixture_home" || return 1
  HOME="$fixture_home" bash "$source_root/install.sh" --scope user --no-default >/dev/null 2>&1 || {
    printf 'failed to install Kiro runtime fixture under %s\n' "$fixture_home" >&2
    return 1
  }
  ZENSU_KIRO_FIXTURE_ROOT="$fixture_home/.kiro/zensu"
  ZENSU_KIRO_FIXTURE_SHIM="$ZENSU_KIRO_FIXTURE_ROOT/hooks/kiro/kiro-shim.sh"
  [ -f "$ZENSU_KIRO_FIXTURE_SHIM" ] || return 1
}
