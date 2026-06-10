#!/usr/bin/env bash
# D1/D4 scenario — installs a variant agent "zensu-dump" into the user's
# ~/.kiro/agents whose hooks append every raw event payload (via eval-dump.sh,
# which resolves the project dir from the payload cwd) to .zensu-dump/*.jsonl
# in the session project. The diagnostics suite reads those dumps to verify
# the payload-field assumptions of the risk register (R2/R3/R4/R5/R12/R14).
# The runner removes the variant agent after the suite.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
KIRO_DIR="${KIRO_HOME:-$HOME/.kiro}"
mkdir -p "$KIRO_DIR/agents"
chmod +x "$HERE/eval-dump.sh"

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
    "agentSpawn":       [ { "command": "bash $HERE/eval-dump.sh agentSpawn" } ],
    "userPromptSubmit": [ { "command": "bash $HERE/eval-dump.sh userPromptSubmit" } ],
    "preToolUse":       [ { "matcher": "*", "command": "bash $HERE/eval-dump.sh preToolUse" } ],
    "postToolUse":      [ { "matcher": "*", "command": "bash $HERE/eval-dump.sh postToolUse" } ],
    "stop":             [ { "command": "bash $HERE/eval-dump.sh stop" } ]
  }
}
EOF
echo "zensu-dump agent installed into $KIRO_DIR/agents (dump helper: $HERE/eval-dump.sh)"
