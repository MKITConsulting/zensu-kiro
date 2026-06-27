#!/usr/bin/env bash
# B-series — Kiro CLI write-gate (pre-bash-zensu-gate.sh) via kiro-shim.sh: a
# freelance `zensu` mutation denies (exit 2), the same mutation inside a declared
# workflow window allows (exit 0), reads/--help/inline-off/localhost/non-zensu
# never gate. Ported from the cc gate test; assertions are on the shim exit code,
# not raw JSON (the shim translates permissionDecision:deny -> exit 2).
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
SID="b-cli-gate"
SHIM="$ROOT/hooks/kiro/kiro-shim.sh"
LOG="$ROOT/hooks/lib/zensu-log.sh"

payload() { # $1=command  $2=session(optional)
  CMD="$1" SID="${2:-$SID}" CWD="$TMP" node -e '
    process.stdout.write(JSON.stringify({
      tool_name: "shell",
      session_id: process.env.SID,
      cwd: process.env.CWD,
      tool_input: { command: process.env.CMD }
    }));
  '
}

# gate <label> <command> <expected-rc> [session]
gate() { # expected-rc: 2 = DENY, 0 = ALLOW
  local label="$1" cmd="$2" exp="$3" sid="${4:-$SID}" rc
  payload "$cmd" "$sid" | env -u ZENSU_PLUGIN_ROOT bash "$SHIM" pre-bash-zensu-gate.sh >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$exp" ]; then
    ok "$label -> rc=$exp"
  else
    bad "$label -> got rc=$rc, expected rc=$exp"
  fi
}

# 1) Freelance mutation, no workflow active -> DENY
gate "B1 freelance mutation (features create)" "zensu features create --name X --description d" 2

# 3) Read command -> ALLOW (no workflow needed)
gate "B3 read (features list)" "zensu features list --product p" 0

# 4) Narrowing cases — reads/--help, inline ZENSU_MCP_GATE=off, localhost, non-zensu
gate "B4a mutation + --help (a read)"          "zensu features create --help" 0
gate "B4a2 mutation + -h (a read)"             "zensu features create -h" 0
gate "B4b inline ZENSU_MCP_GATE=off"           "ZENSU_MCP_GATE=off zensu features create --name X" 0
gate "B4b2 inline gate value not off -> DENY"  "ZENSU_MCP_GATE=on zensu features create --name X" 2
gate "B4c --api-url localhost"                 "zensu --api-url http://localhost:8080 features create --name X" 0
gate "B4c2 inline ZENSU_API_URL 127.0.0.1"     "ZENSU_API_URL=http://127.0.0.1:8080 zensu features create --name X" 0
gate "B4c3 --api-url prod still -> DENY"        "zensu --api-url https://api.zensu.dev features create --name X" 2
gate "B4d non-zensu command (git) -> ALLOW"    "git status" 0

# 5) Wrapper / env-prefix mutations still classify -> DENY
gate "B5a wrapper command + mutation"          "command zensu features create --name X" 2
gate "B5b env-prefix mutation"                 "FOO=bar zensu features create --name X" 2

# 2) Same mutation INSIDE an open workflow window that declared create_feature -> ALLOW
WS="wf-$SID"
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --workflow-begin --tools "create_feature" --session "$WS" >/dev/null 2>&1
gate "B2 mutation inside declared workflow"        "zensu features create --name X" 0 "$WS"
gate "B2b out-of-scope mutation in workflow -> DENY" "zensu security classify f1 --classification confidential" 2 "$WS"
ZENSU_PLUGIN_ROOT="$ROOT" bash "$LOG" --workflow-end --session "$WS" >/dev/null 2>&1
gate "B2c mutation after workflow-end -> DENY"     "zensu features create --name X" 2 "$WS"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
