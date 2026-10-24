---
inclusion: always
---

# Zensu PLM conventions

Zensu makes **features first-class citizens** across the software lifecycle.
This workspace uses the zensu-kiro plugin: the typed `zensu` CLI, the
`zensu-*` skills (`/zensu-help` lists them), and the `zensu-*` subagents.

- **Features** carry `KEY-N` ids; reference them in commit messages as
  `[ZEN-42]`. Lifecycle `planned → in-progress → testing → released`, gated by
  security score, docs completeness, and journey health.
- Route ANY Zensu CLI interaction through the **`zensu-plm`** subagent or the
  matching skill (`/zensu-bootstrap`, `/zensu-ghost-scan`, `/zensu-implement`,
  `/zensu-security-review`). Direct state-mutating `zensu` commands are denied by
  the CLI write-gate and bypass workflow conventions everywhere else.
- For any task that adds or modifies executable code: plan first, then **ask
  the user whether to run the strict TDD flow** (`/zensu-tdd`) before the first
  code edit. On yes, RED→GREEN under the phase-gate with the review chain at
  the end; on no, implement directly. With `hooks.tddImplementation=false` the
  same `/zensu-tdd` workflow runs in vanilla implementation mode (ask about the
  "Zensu workflow (vanilla implementation + review chain)" instead): no
  RED→GREEN ceremony, while the evidence audits and the review chain stay
  enforced.
- After a TDD implementation, the review chain must complete: five
  `zensu-review-aspect` perspectives (or one `zensu-code-reviewer` pass), fix
  Critical/Important findings, finish with `/zensu-self-review`.
- Never guess feature IDs — `zensu features list` or ask. Set security
  classification before coding. Behavior is tunable via `~/.zensu/config.json`.

## AI work capture

Exception to PLM routing: the interactive main agent records the already agreed
implementation goal and clean commit result through the capture helper, including
in direct mode. Use the exact captureKey from the native primer. If the IDE Power
provides no primer, run `node <installed-runtime>/hooks/kiro/ai-work.js session`
once, retain its private conversation key, and follow its begin/checkpoint
instructions. The runtime is normally `~/.kiro/zensu`. Never use the project's
current-session file or delegate capture to a child. Missing native session IDs
mean no automatic Stop retry; checkpoint before handoff and state that limitation.
Return the exact reviewUrl. Personal CLI OAuth identifies the reporting account;
only the human accepts or revokes in the web UI. A report or merge is not acceptance.
