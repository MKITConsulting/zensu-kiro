#!/usr/bin/env bash
# F02 — large payloads must not bypass the gates. Passing the whole hook
# payload to node through an environment variable hits execve limits
# (E2BIG: ~128 KiB per string on Linux, ~1 MiB total on macOS); node then
# never runs, extraction returns empty, and the hook exits 0 — i.e. a big
# `write` (large file_text) or a big MCP argument silently disarms the TDD
# phase-gate and the MCP write-gate. Payloads must reach node via stdin
# (the witness already does this). These cases use a ~3 MiB payload to
# exceed both platforms' limits.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TDD_STATE_DIR="$TMP/state"
unset CLAUDE_PROJECT_DIR 2>/dev/null || true
mkdir -p "$TMP/home" "$TDD_STATE_DIR"
export HOME="$TMP/home"
SID="f02-large"
SHIM="$ROOT/hooks/kiro/kiro-shim.sh"
LOG="$ROOT/hooks/lib/zensu-log.sh"

BIG="$TMP/big.json"
node -e '
  const fs = require("fs");
  const filler = "x".repeat(3 * 1024 * 1024);
  fs.writeFileSync(process.argv[1], JSON.stringify({
    tool_name: "fs_write",
    session_id: "f02-large",
    cwd: process.argv[2],
    tool_input: { command: "create", path: "src/app.js", file_text: filler }
  }));
' "$BIG" "$TMP"

ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --phase RED_WRITE --step s1 --session "$SID" >/dev/null 2>&1
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --phase RED_FAIL --step s1 --session "$SID" >/dev/null 2>&1

# 1) TDD gate must still DENY a 3 MiB prod write in RED_FAIL
env -u ZENSU_PLUGIN_ROOT bash "$SHIM" pre-edit-tdd-reminder.sh < "$BIG" >"$TMP/o" 2>"$TMP/e"
RC=$?
[ "$RC" -eq 2 ] && ok "TDD gate denies 3MiB prod write" || bad "TDD gate rc=$RC on 3MiB payload (expected 2) — large-payload bypass"

# 2) CLI write-gate must still DENY a 3 MiB `zensu` mutation command
node -e '
  const fs = require("fs");
  const filler = "y".repeat(3 * 1024 * 1024);
  fs.writeFileSync(process.argv[1], JSON.stringify({
    tool_name: "shell",
    session_id: "f02-large",
    cwd: process.argv[2],
    tool_input: { command: "zensu features create --name X --description " + filler }
  }));
' "$BIG" "$TMP"
env -u ZENSU_PLUGIN_ROOT bash "$SHIM" pre-bash-zensu-gate.sh < "$BIG" >"$TMP/o" 2>"$TMP/e"
RC=$?
[ "$RC" -eq 2 ] && ok "CLI gate denies 3MiB mutation command" || bad "CLI gate rc=$RC on 3MiB payload (expected 2) — large-payload bypass"

# 3) stop enforcer must still block with a 3 MiB stop payload field
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --tdd-complete --session "$SID" >/dev/null 2>&1
node -e '
  const fs = require("fs");
  const filler = "z".repeat(3 * 1024 * 1024);
  fs.writeFileSync(process.argv[1], JSON.stringify({
    session_id: "f02-large",
    cwd: process.argv[2],
    last_response: filler
  }));
' "$BIG" "$TMP"
OUT="$(env -u ZENSU_PLUGIN_ROOT bash "$SHIM" stop-chain-enforcer.sh < "$BIG" 2>/dev/null)"
printf '%s' "$OUT" | grep -q '"decision":"block"' && ok "stop enforcer blocks with 3MiB payload" || bad "stop enforcer silent on 3MiB payload — large-payload bypass"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
