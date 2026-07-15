# Changelog

All notable changes to zensu-kiro are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

### Changed

- **runtime**: Treat `$HOME/.kiro/zensu` as Kiro's fixed plugin runtime and
  resolve it through a fail-closed validator that checks `VERSION`, scope
  protocol, the install manifest, and the complete declarative hook closure
  before model-issued commands or automatic hooks run.
- **installer**: Structurally render agent JSON and shell-escape hook paths
  (including hostile-but-valid HOME characters), reject control-character
  bases and symlinked path components, publish files/manifests atomically, and
  serialize the full runtime transaction with one HOME-wide token lock. File
  replacement/removal now atomically claims expected bytes and restores or
  preserves them on concurrent editor races. Claims are self-describing crash
  journals recovered before the next preflight, and obsolete unmodified runtime
  files are removed from the prior manifest before the new one is published.
- **runtime**: Share the installer lock with automatic hook dispatch, revalidate
  the complete runtime snapshot before returning it, and serialize stale-lock
  recovery with visible unique election claims that survive claimant crashes
  without moving the canonical recovery guard. Security/TDD preToolUse hooks now deny
  while the runtime is corrupt or being upgraded; lifecycle hooks remain
  fail-open.
- **installer safety**: Refuse to replace a malformed prior manifest even with
  `--force`, because unknown obsolete hooks cannot be reconciled safely without
  trustworthy inventory provenance.
- **versioning**: Compare prerelease identifiers with SemVer precedence, refuse
  replacing a newer installed runtime unless `--force` is explicit, and keep
  safe uninstall available across version drift without weakening schema or
  path validation.

### Fixed

- **isolation**: Stop installer and `agentSpawn` hooks from reading or rewriting
  the legacy shared plugin-root locator, preventing other hosts and worktrees
  from redirecting Kiro's runtime.

## [0.2.0] - 2026-06-27

### Added

- **cli**: Re-home plugin from MCP tools to the typed zensu CLI
- **skills**: Add zensu-pr-fix-findings skill (#5)
- **hooks**: Vanilla implementation mode (hooks.tddImplementation)

### Changed

- **plans**: MCP-to-CLI re-home plan for kiro (parity with claude-code #117/#128) (#6)
- Show vanilla mode in the workflow diagram (#4)
- **readme**: Add three-layer workflow mermaid diagram
- **ids**: Migrate ZEN-XXX wording to per-product KEY-N feature ids

### Fixed

- **tdd**: Drop unflippable plan checkboxes; Status column is sole completion tracker (#9)
- **ghost-scan**: Mint v1 baseline server-side, drop client-side Phase 5b
- **windows**: Cygpath-normalize gate classifier inputs for native node

merge

- Main (KEY-N feature-id wording) into vanilla-mode branch

### Changed

- **Re-homed from the hosted MCP server to the typed `zensu` CLI** (ports
  `zensu-claude-code` #117 + the narrowed write-gate #128). The plugin now drives
  Zensu through `zensu <noun> <verb>` commands instead of `@zensu/*` MCP tools:
  `mcp.json` is deleted and `includeMcpJson` is off in every agent; all
  data-touching skills + the `zensu-plm`/orchestrator agents + onboarding docs +
  installers use the CLI (`curl -fsSL https://zensu.dev/install.sh | sh`,
  `zensu auth login`). The MCP write-gate `pre-mcp-zensu-gate.sh` is retired and
  replaced by `pre-bash-zensu-gate.sh` (PreToolUse on `shell`/`execute_bash` via
  the kiro-shim), backed by a new `hooks/lib/zensu-cli-map.sh`; the gate keeps the
  post-#128 narrowing (reads / `--help` / inline `ZENSU_MCP_GATE=off` / localhost
  targets pass) and is hardened to read large payloads via stdin so a 3 MiB
  command cannot bypass it. The hosted MCP server stays live for the Zensu web app
  but is no longer wired into the plugin. Tests: new `test-bash-zensu-gate.sh`;
  `test-mcp-gate-kiro-names.sh` retired; `test-hooks-wiring` / `test-json-validity`
  / `test-large-payload` / `test-install-script` updated for the CLI surface.

### Added

- Vanilla implementation mode (`hooks.tddImplementation`, default `true`):
  setting it to `false` makes `/zensu-tdd` implement WITHOUT the RED→GREEN
  ceremony — no FSM phase markers, the preToolUse edit gate passes through,
  tests at the agent's discretion — while plan/log artifacts, the Phase 5/6
  evidence audits (build, coverage, witness cross-check), the review fan-out →
  `zensu-code-reviewer` → auto-fix loop → `/zensu-self-review`, and the
  Stop-hook chain guarantee stay enforced. The mode is frozen per session at
  `--tdd-begin` (echoes `mode: strict|vanilla`; query via `zensu-log.sh
  --mode`) — config flips mid-session change nothing. Ported from
  zensu-claude-code PR #112.
- TDD phase-gate hardening that travels with the freeze: while a session is
  active, edit-tool writes touching the session-state files (`.zensu/state/`
  and the rounds-counter dir, normalized + realpath-resolved — dot-segments,
  case variants, traversal, MSYS vs native Windows drive spellings,
  `TDD_STATE_DIR` overrides, and symlink aliases all collapse to the same
  deny) are blocked in BOTH modes unless the gate itself is bypassed via
  `ZENSU_TDD_GATE=off`; state flags change only through `zensu-log.sh`.
- State-lib robustness (upstream-synced): `--phase` writes preserve unknown
  state keys (the `vanilla` flag and scoped MCP workflow windows survive
  rebuilds), array-shaped state files recover to objects, `--tdd-reset`
  clears the vanilla freeze.

### Changed

- **`/zensu:ghost-scan` no longer creates the v1 baseline revision client-side — it is minted server-side by `ghost_apply` (zensu-monorepo #266).** Removed Phase 5b from the ghost-scan skill (replaced with a server-side note), dropped the agent's ghost-scan baseline workflow step + Important Rule (renumbered the trailing rule), and trimmed `create_revision` from the skill's workflow-gate tool list and MCP-tools table. Keeping the client step would 400 against a #266 backend (its baseline is `planned`; `create_revision` requires the prior revision `released`/`superseded`). Ported from zensu-claude-code #109; release-coupled to the #266 deploy.

## [0.1.0] - 2026-06-10

Initial Kiro port of the zensu plugin (content base: zensu-claude-code v0.8.4;
engine-adaptation patterns from the zensu-codex port).

### Added

- `hooks/kiro/kiro-shim.sh` — single engine-translation layer: deny JSON →
  exit 2 + stderr (Kiro preToolUse block), Stop `{"decision":"block"}`
  passthrough (full parity), `additionalContext` → plain stdout.
- TDD phase-gate accepting Kiro write payloads (`write`/`fs_write`/`fsWrite`,
  `tool_input.path`) alongside Claude and Codex shapes.
- MCP write-gate with Kiro tool-name strip chain (`@zensu/x`, `zensu___x`,
  legacy) and foreign-tool pass-through; workflow windows unchanged.
- Stop chain-enforcer, shell witness, agentSpawn hooks (banner reads VERSION),
  per-turn TDD reminder, intent router, post-review delegate with tolerant
  `subagent` matching — all wired inside `agents/cli/zensu.json`.
- 11 skills on the open Agent Skills standard (`/zensu-*` slash commands,
  shared by IDE and CLI), workflow markers preserved.
- Dual-format agents: 4 CLI JSON configs + 3 IDE markdown subagents with
  deduplicated bodies in `agents/prompts/` (equality test-pinned).
- `install.sh` (manifest-hash idempotency, mcp.json merge, `__ZENSU_HOME__`
  rendering, opt-in default agent, uninstall) + `install.ps1` wrapper.
- `POWER.md` + steering files — installable as a Kiro IDE Power.
- Deterministic test suite (`tests/run-all.sh`; one structure suite per `tests/structure/test-*.sh`) and the
  promptfoo live-eval layer (`diagnostics.yaml` risk suite D1–D6,
  `promptfooconfig.yaml` behavior suite B1–B6, sandboxed `kiro-cli.mjs`
  provider with `KIRO_HOME` isolation).
- CI (`ci.yml` ubuntu+windows), release pipeline (`release.yml`,
  VERSION/POWER.md/badge/CHANGELOG sync), `evals.yml` manual live-eval
  dispatch.
