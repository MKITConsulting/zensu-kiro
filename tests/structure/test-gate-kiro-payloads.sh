#!/usr/bin/env bash
# S03 — TDD phase-gate must understand Kiro CLI write payloads.
# Kiro preToolUse stdin: {"session_id","cwd","tool_name","tool_input":{...}}.
# The write tool's canonical name is "write" (aliases fs_write, fsWrite) and the
# edited file arrives as tool_input.path. The gate must apply the same FSM rules
# it applies to Claude Edit/Write/MultiEdit and Codex apply_patch payloads, and
# it must still emit the engine-neutral deny JSON (the kiro-shim translates it).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export TDD_STATE_DIR="$TMP/state"
export ZENSU_PLUGIN_ROOT="$ROOT"
unset CLAUDE_PROJECT_DIR 2>/dev/null || true
mkdir -p "$TMP/home" "$TDD_STATE_DIR"
export HOME="$TMP/home"   # isolate ~/.zensu lookups
SID="s03-kiro-gate"
LOG="$ROOT/hooks/lib/zensu-log.sh"
GATE="$ROOT/hooks/pre-edit-tdd-reminder.sh"

# Kiro write payload: tool_input.path carries the target file.
mk_kiro_write() { # $1=session $2=tool_name $3=path
  printf '{"tool_name":"%s","session_id":"%s","cwd":"%s","tool_input":{"command":"create","path":"%s","file_text":"x"}}' "$2" "$1" "$TMP" "$3"
}
mk_claude_edit() { # $1=session $2=file_path
  printf '{"tool_name":"Edit","session_id":"%s","cwd":"%s","tool_input":{"file_path":"%s"}}' "$1" "$TMP" "$2"
}

run_gate() { local out; out="$(printf '%s' "$1" | bash "$GATE" 2>/dev/null)"; case "$out" in *'permissionDecision":"deny"'*) echo DENY ;; *) echo ALLOW ;; esac; }
expect() { if [ "$2" = "$3" ]; then ok "$1 -> $3"; else bad "$1 -> got $3, expected $2"; fi; }

# 0) inactive session: pass-through even for Kiro payloads
expect "inactive session, fs_write prod" ALLOW "$(run_gate "$(mk_kiro_write nosess fs_write src/app.js)")"

bash "$LOG" --tdd-begin --session "$SID" >/dev/null 2>&1
bash "$LOG" --phase RED_WRITE --step s1 --session "$SID" >/dev/null 2>&1
# 1) RED_WRITE: anything goes
expect "RED_WRITE, fs_write prod" ALLOW "$(run_gate "$(mk_kiro_write "$SID" fs_write src/app.js)")"

bash "$LOG" --phase RED_FAIL --step s1 --session "$SID" >/dev/null 2>&1
# 2) RED_FAIL: prod denied for every Kiro alias, test path allowed
expect "RED_FAIL, fs_write prod"  DENY  "$(run_gate "$(mk_kiro_write "$SID" fs_write src/app.js)")"
expect "RED_FAIL, write prod"     DENY  "$(run_gate "$(mk_kiro_write "$SID" write src/app.js)")"
expect "RED_FAIL, fsWrite prod"   DENY  "$(run_gate "$(mk_kiro_write "$SID" fsWrite src/app.js)")"
expect "RED_FAIL, fs_write test"  ALLOW "$(run_gate "$(mk_kiro_write "$SID" fs_write src/app.test.js)")"
# 2b) unrelated Kiro tools must never be gated
expect "RED_FAIL, shell tool"     ALLOW "$(run_gate "$(mk_kiro_write "$SID" shell src/app.js)")"
expect "RED_FAIL, fs_read tool"   ALLOW "$(run_gate "$(mk_kiro_write "$SID" fs_read src/app.js)")"
# 2c) Claude-style Edit still denied (cross-engine regression guard)
expect "RED_FAIL, Edit prod (Claude)" DENY "$(run_gate "$(mk_claude_edit "$SID" src/app.js)")"
# 2d) file CONTENT containing an apply_patch envelope must not inject phantom
#     paths: a legitimate TEST-file write whose body documents a patch touching
#     a production path stays ALLOWED (the envelope scan applies to apply_patch
#     payloads, not to explicit-path write payloads)
ENVELOPE_PAYLOAD="$(printf '{"tool_name":"fs_write","session_id":"%s","cwd":"%s","tool_input":{"command":"create","path":"src/app.test.js","file_text":"fixture: *** Begin Patch\\n*** Update File: src/app.js\\n+x\\n*** End Patch"}}' "$SID" "$TMP")"
expect "RED_FAIL, test write with envelope-looking content" ALLOW "$(run_gate "$ENVELOPE_PAYLOAD")"

bash "$LOG" --phase IMPL --step s1 --session "$SID" >/dev/null 2>&1
# 3) IMPL after RED_FAIL: prod allowed
expect "IMPL, fs_write prod" ALLOW "$(run_gate "$(mk_kiro_write "$SID" fs_write src/app.js)")"

# 4) env bypass
bash "$LOG" --phase RED_FAIL --step s1 --session "$SID" >/dev/null 2>&1
out="$(printf '%s' "$(mk_kiro_write "$SID" fs_write src/app.js)" | ZENSU_TDD_GATE=off bash "$GATE" 2>/dev/null)"
case "$out" in *'permissionDecision":"deny"'*) bad "gate OFF bypass -> DENY" ;; *) ok "gate OFF bypass -> ALLOW" ;; esac

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
