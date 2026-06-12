---
inclusion: manual
---

# Zensu TDD protocol cheat sheet

Strict RED→IMPL→GREEN, enforced by the preToolUse phase-gate while a TDD
session is active (Kiro CLI, `zensu` agent). `PLUGIN_ROOT` = contents of
`~/.zensu/plugin-root` (normally `~/.kiro/zensu`).

## Session lifecycle

```bash
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --tdd-begin      # arm gate + witness
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --tdd-complete   # implementation done -> review chain required
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --chain-done     # chain terminus (owned by /zensu-self-review)
```

## Phase markers (before every edit)

```bash
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase RED_WRITE  --step <id>
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase RED_RUN    --step <id>
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase RED_FAIL   --step <id> --reason "..."
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase IMPL       --step <id>   # requires RED_FAIL for <id>
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase GREEN_RUN  --step <id>
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase GREEN_PASS --step <id>
bash $PLUGIN_ROOT/hooks/lib/zensu-log.sh --phase REFACTOR   --step <id>
```

`--step <id>` is REQUIRED on every marker: a marker without it records step
`(none)`, and the gate matches IMPL against a prior RED_FAIL **per step id** —
on mismatch the write is denied.

## Gate rules (write tool)

| Phase | Production file | Test file |
|---|---|---|
| RED_WRITE | allow | allow |
| RED_FAIL | **deny** | allow |
| IMPL (after RED_FAIL for step) | allow | allow |
| GREEN_PASS | **deny** | allow |
| REFACTOR | allow | allow |

Escape hatches: `ZENSU_TDD_GATE=off` (edits), `ZENSU_MCP_GATE=off` (MCP
write-gate), `ZENSU_CHAIN=off` (stop enforcer), `ZENSU_TEST_WITNESS=off`
(witness). Scoped MCP windows inside skills: `--workflow-begin --tools "a,b"`
… `--workflow-end`.

## Vanilla implementation mode

`hooks.tddImplementation:false` (read ONCE at `--tdd-begin`, frozen into the
state file; the command echoes `mode: strict|vanilla`, re-query with
`zensu-log.sh --mode`): the phase markers and the gate matrix above do NOT
apply — the gate passes through, tests are at your discretion. Edit-tool
writes to `.zensu/state/` stay denied in both modes (unless the gate itself is
bypassed via `ZENSU_TDD_GATE=off`). Still enforced: witness, Phase 5/6
evidence audits, review chain + `/zensu-self-review`, Stop-hook guarantee.
