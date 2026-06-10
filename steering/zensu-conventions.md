---
inclusion: always
---

# Zensu PLM conventions

Zensu makes **features first-class citizens** across the software lifecycle.
This workspace uses the zensu-kiro plugin: the `zensu` MCP server, the
`zensu-*` skills (`/zensu-help` lists them), and the `zensu-*` subagents.

- **Features** carry `ZEN-XXX` IDs; reference them in commit messages as
  `[ZEN-001]`. Lifecycle `planned → in-progress → testing → released`, gated by
  security score, docs completeness, and journey health.
- Route ANY Zensu MCP interaction through the **`zensu-plm`** subagent or the
  matching skill (`/zensu-bootstrap`, `/zensu-ghost-scan`, `/zensu-implement`,
  `/zensu-security-review`). Direct state-mutating MCP calls are denied by the
  write-gate (CLI) and bypass workflow conventions everywhere else.
- For any task that adds or modifies executable code: plan first, then **ask
  the user whether to run the strict TDD flow** (`/zensu-tdd`) before the first
  code edit. On yes, RED→GREEN under the phase-gate with the review chain at
  the end; on no, implement directly.
- After a TDD implementation, the review chain must complete: five
  `zensu-review-aspect` perspectives (or one `zensu-code-reviewer` pass), fix
  Critical/Important findings, finish with `/zensu-self-review`.
- Never guess feature IDs — `list_features` or ask. Set security classification
  before coding. Behavior is tunable via `~/.zensu/config.json`.
