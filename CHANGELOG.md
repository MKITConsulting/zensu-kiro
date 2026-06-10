# Changelog

All notable changes to zensu-kiro are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

## [Unreleased]

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
