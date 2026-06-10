#!/usr/bin/env bash
# D1/D4 scenario — installs a variant agent "zensu-dump" into the sandbox
# KIRO_HOME whose hooks append every raw event payload to .zensu-dump/*.jsonl
# in the project cwd. The diagnostics suite reads those dumps to verify the
# payload-field assumptions of the risk register (R2/R3/R4/R5/R12/R14).
set -eu

KIRO_DIR="${KIRO_HOME:-$HOME/.kiro}"
mkdir -p "$KIRO_DIR/agents"

DUMP='mkdir -p "$PWD/.zensu-dump" && cat >>'

cat > "$KIRO_DIR/agents/zensu-dump.json" <<EOF
{
  "name": "zensu-dump",
  "description": "Diagnostics variant of the zensu agent: dumps every hook payload to .zensu-dump/*.jsonl for the promptfoo risk suite.",
  "tools": ["@builtin", "@zensu"],
  "allowedTools": ["read", "grep", "glob", "thinking", "todo", "shell", "write", "subagent", "@zensu/list_*", "@zensu/get_*", "@zensu/search_*", "@zensu/suggest_*"],
  "includeMcpJson": true,
  "toolsSettings": {
    "subagent": {
      "availableAgents": ["zensu-plm", "zensu-code-reviewer", "zensu-review-aspect"],
      "trustedAgents": ["zensu-plm", "zensu-code-reviewer", "zensu-review-aspect"]
    }
  },
  "hooks": {
    "agentSpawn":       [ { "command": "bash -c '$DUMP \"\$PWD/.zensu-dump/agentSpawn.jsonl\"'" } ],
    "userPromptSubmit": [ { "command": "bash -c '$DUMP \"\$PWD/.zensu-dump/userPromptSubmit.jsonl\"'" } ],
    "preToolUse":       [ { "matcher": "*", "command": "bash -c '$DUMP \"\$PWD/.zensu-dump/preToolUse.jsonl\"'" } ],
    "postToolUse":      [ { "matcher": "*", "command": "bash -c '$DUMP \"\$PWD/.zensu-dump/postToolUse.jsonl\"'" } ],
    "stop":             [ { "command": "bash -c '$DUMP \"\$PWD/.zensu-dump/stop.jsonl\"'" } ]
  }
}
EOF
echo "zensu-dump agent installed into $KIRO_DIR/agents"
