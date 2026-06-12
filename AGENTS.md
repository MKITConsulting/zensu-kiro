# zensu-kiro Repo Conventions

## Language

**English only.** All code, comments, docs, commit messages, prompts, fixture
content, and pattern alternations must be in English. Exemptions: runtime
`.zensu/` artifacts (local-only, gitignored), the German-token detection lists
in `hooks/user-prompt-tdd-reminder.sh` (mirrors upstream's multilingual
user-preference matching verbatim), and the guard's own word list in
`tests/structure/test-english-only.sh`.

## What this repo is

The Kiro port of the zensu Product Lifecycle Manager plugin. Upstream content
base: `zensu-claude-code` (Claude Code plugin). Engine-adaptation precedent:
`zensu-codex` (OpenAI Codex CLI port). One repo serves BOTH hosts:

- **Kiro IDE (>= 0.9)** installs it as a Power (`POWER.md` at the repo root,
  `mcp.json` auto-registered, `steering/` shipped with the Power).
- **Kiro CLI (>= 2.6)** has no native plugin system — `install.sh` copies
  skills, agents, the hook runtime, and merges the MCP config.

## Architecture invariants

- `hooks/kiro/kiro-shim.sh` is the only OUTPUT-translation layer: it turns the
  engine-neutral hook outputs into Kiro semantics (deny-JSON to exit 2 + stderr,
  Stop `{"decision":"block"}` passthrough, `additionalContext` to plain stdout)
  and never makes policy decisions itself. INPUT-side Kiro awareness lives in
  the hook scripts as enumerated deltas — re-syncing a hook from upstream
  without re-applying its delta strips Kiro support (the structure tests catch
  it). Hook-level deltas vs upstream:
  - `pre-edit-tdd-reminder.sh` — accepts `write`/`fs_write`/`fsWrite`, extracts
    `tool_input.path`, envelope scan only for `apply_patch`/pathless payloads
    (pinned by `test-gate-kiro-payloads.sh`). Path handling is multi-file: one
    batch classification pass (state/zensu/other, normalized + realpath) feeds
    the ordered checks state-deny (both modes) → vanilla bypass (frozen state
    flag) → zensu exemption → FSM rules (pinned by
    `test-tdd-vanilla-mode.sh`).
  - `pre-mcp-zensu-gate.sh` — `@zensu/`/`zensu___`/`zensu__`/legacy strip chain,
    foreign tools pass (pinned by `test-mcp-gate-kiro-names.sh`).
  - `session-start-capture-sid.sh` — synthesizes a session id when the payload
    carries none and persists `session-id-current.txt` (pinned by
    `test-session-resolution.sh`).
  - `post-review-tdd-delegate.sh` — name-field-first reviewer match for the
    `subagent`/`use_subagent` tool, locked round bump (pinned by
    `test-post-review-delegate.sh`).
  - `post-bash-witness.sh` — reads `tool_response.result`, refuses symlinked
    log targets (pinned by `test-witness-log.sh`).
  - All payload extraction streams via stdin (never env vars — execve limits
    would silently disarm the gates on large payloads; pinned by
    `test-large-payload.sh`).
  Load-bearing host assumption: Kiro hook matchers are EXACT tool-name matches;
  the delegate is intentionally wired under both `subagent` and `use_subagent`
  and the gate under `write`/`fs_write`/`fsWrite` — a host matching aliases
  transitively would double-fire (the round counter is mutex-locked, but budget
  would count double; re-verify via the diagnostics suite on Kiro upgrades).
- `hooks/lib/*.sh` are upstream copies (plus the port-owned `zensu-runtime.sh`).
  Fix bugs upstream first, then re-sync. **Documented lib deltas** (upstream-sync
  candidates, each pinned by a structure test):
  - `zensu-session.sh` — consults the project-scoped
    `.zensu/state/session-id-current.txt` (written by
    `session-start-capture-sid.sh`) directly after an explicit id and BEFORE
    the Claude-transcript helper: Kiro payloads carry no session id and
    model-shell processes have foreign ancestry, and on mixed machines the
    transcript helper would return live-changing Claude ids
    (`test-session-resolution.sh`).
  - `zensu-tdd-phase.sh` — adds `zensu_rounds_counter_file <session>`, the
    single owner of the rounds-counter path consumed by the delegate's bump,
    `--tdd-begin`'s reset, and the edit gate's state-deny set
    (`test-kiro-shim-stop.sh`). Coupling to mind on upstream re-syncs:
    `--phase`/flag writes are preserve-all (unknown keys survive rebuilds —
    that is what keeps the `vanilla` freeze alive), while
    `_tdd_write_clear_critical` resets an ENUMERATED flag list — any new
    per-session flag added upstream must also be added to that clear list or
    it silently survives `--tdd-reset`; and `zensu_rounds_counter_file`'s
    session-id sanitization must stay character-for-character identical to
    `tdd_state_file`'s, or the counter path diverges from the state-file
    naming and silently leaves the gate's deny set.
  - `zensu-log.sh` — `--tdd-begin` clears the previous chain's terminal flags
    (`implComplete`/`chainDone`/`codeReviewDone`/`selfReviewFixed`), deletes
    the `.stopblocks` budget AND the auto-fix rounds counter, so a second TDD
    chain in the same session re-arms the Stop backstop and starts at round 1;
    value-consuming options fail fast on a missing value instead of hanging
    (`test-kiro-shim-stop.sh`). The vanilla-mode freeze (`--tdd-begin` persists
    the `vanilla` flag per `hooks.tddImplementation` and echoes
    `mode: strict|vanilla`) and the `--mode` query verb are upstream-synced
    behavior, not Kiro deltas (`test-tdd-vanilla-mode.sh`). Open upstream-sync
    candidate (deferred by review, cosmetic): combine the freeze+active writes
    into ONE locked critical section in the state lib and echo the mode from
    the computed value instead of a state re-read — closes a
    concurrent-double-begin echo race; today's two-write sequence stays
    coherent (last-freeze-wins) and both partial-failure branches disarm.
- Hooks are wired in `agents/cli/zensu.json` (Kiro hooks live inside agent
  configs). `agents/cli/zensu-plm.json` intentionally has NO `@zensu` write-gate
  hook — that is the per-agent replacement for upstream's `agent_type` exemption.
- Agent prompt bodies live ONCE in `agents/prompts/*.md`; the IDE variants in
  `agents/ide/*.md` must keep identical bodies (pinned by
  `tests/structure/test-agent-prompt-sync.sh`).
- Convention wording is mirrored on three surfaces — CANONICAL source is
  `steering/zensu-conventions.md`; `agents/prompts/zensu-orchestrator.md`
  (CLI system prompt) and the POWER.md steering section are derived mirrors.
  Update order: steering first, then the two mirrors in the same commit.

## Version bumps

`VERSION`, `POWER.md` frontmatter `metadata.version`, the README badge, and the
newest `## [X.Y.Z]` CHANGELOG heading MUST carry the same value in the same
commit (`chore(release): bump version to X.Y.Z`). Machine-enforced by
`tests/structure/test-version-sync.sh`. The `Release` workflow bumps all four
together; for a manual hotfix follow the invariant by hand.

## Tests

- `bash tests/run-all.sh` — deterministic suites (CI gate; no network, no API).
- `bash tests/run-promptfoo.sh diagnostics|behavior` — live promptfoo evals
  against a real `kiro-cli` (logged-in or `KIRO_API_KEY`); costs credits; never
  part of the deterministic gate.

## MCP tool classification

`hooks/lib/zensu-mcp-tools.sh` is the single source of truth (synced from
upstream). When the Zensu MCP server gains a tool, classify it upstream and
re-sync; the write-gate default-denies anything not on the read allowlist.
