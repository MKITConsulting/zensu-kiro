# zensu-kiro

![version](https://img.shields.io/badge/version-0.1.0-blue)
![hosts](https://img.shields.io/badge/hosts-Kiro%20IDE%20%E2%89%A50.9%20%C2%B7%20Kiro%20CLI%20%E2%89%A52.6-purple)
![license](https://img.shields.io/badge/license-FSL--1.1--Apache--2.0-green)

The **Kiro port of [Zensu](https://zensu.dev)** — a Product Lifecycle Manager
that makes **features first-class citizens** from roadmap to release: feature
tracking with `KEY-N` feature ids, strict RED→GREEN TDD behind a phase-gated edit
guard, a five-perspective review chain, security reviews with STRIDE threat
models, greenfield bootstrap and brownfield ghost-scan.

One repo serves **both Kiro hosts**: the IDE installs it as a **Power**
(`POWER.md` at the repo root), the CLI — which has no native plugin system —
installs via `install.sh`. Both converge on the shared `~/.kiro/` surfaces
(skills, agents, MCP settings), so each host sees the same plugin.

## Requirements

- **Kiro CLI ≥ 2.6** (`kiro-cli`) and/or **Kiro IDE ≥ 0.9**
- `node` (all JSON handling), `bash`, `git`
- Windows: Kiro CLI is native, the zensu hooks need **Git Bash** (see below)

## Install

### Kiro CLI

```bash
git clone https://github.com/MKITConsulting/zensu-kiro
cd zensu-kiro
bash install.sh                       # --scope user (default)
# optional: make the gate-enforced agent the default for every session
kiro-cli agent set-default zensu
kiro-cli chat --agent zensu           # OAuth to mcp.zensu.dev on first @zensu call
```

`install.sh` flags: `--scope user|workspace` · `--dry-run` · `--force` ·
`--set-default|--no-default` · `--mcp-url <url>` (self-hosted) · `--uninstall`.
It is idempotent (manifest with per-file sha256), never stomps user-modified
files (SKIP + warn), merges `mcpServers.zensu` into `~/.kiro/settings/mcp.json`
without touching other servers, and uninstalls only what it installed.

### Kiro IDE (Power)

Powers panel → **Add power from GitHub** (this repo URL) or **from Local
Path** — the MCP server registers automatically; then follow the onboarding in
[POWER.md](POWER.md) (one `install.sh` run adds skills + subagents shared with
the CLI).

### Headless / CI

```bash
KIRO_API_KEY=... kiro-cli chat --no-interactive --agent zensu --trust-all-tools "<prompt>"
```

## What you get

| Piece | Names |
|---|---|
| **MCP server** | `zensu` → `https://mcp.zensu.dev/mcp` (OAuth browser flow; `ZENSU_API_KEY` header for CI/self-hosting via `--mcp-url`) |
| **Skills** (slash commands, IDE + CLI) | `/zensu-bootstrap` · `/zensu-ghost-scan` · `/zensu-implement` · `/zensu-tdd` · `/zensu-plan-review` · `/zensu-pr-team-review` · `/zensu-security-review` · `/zensu-self-review` · `/zensu-reset-review-limit` · `/zensu-pulse` · `/zensu-help` |
| **Agents** | `zensu` (default orchestrator, carries all hooks) · `zensu-plm` (PLM workflows, MCP-gate-exempt by design) · `zensu-code-reviewer` · `zensu-review-aspect` (read-only reviewers) |
| **Hooks** (inside `zensu` agent config) | TDD phase-gate (`preToolUse` write) · MCP write-gate (`preToolUse @zensu`) · shell witness (`postToolUse shell`) · review delegate (`postToolUse subagent`) · stop chain-enforcer (`stop`) · intent router + TDD reminder + context nudge (`userPromptSubmit`) · banner/primer/pulse/sid (`agentSpawn`) |

## The TDD engine

`/zensu-tdd` runs strict RED→IMPL→GREEN in the main thread. While a session is
armed (`zensu-log.sh --tdd-begin`), the **phase-gate** denies `write`-tool edits
that violate the FSM (production code before a failing test → **exit 2**, the
reason goes straight back to the model), the **witness** records every shell
command for the audit cross-check, and the **stop chain-enforcer** refuses to
end the turn (`{"decision":"block"}`) until the five-perspective review chain
and `/zensu-self-review` have completed. See
[steering/zensu-tdd-protocol.md](steering/zensu-tdd-protocol.md) for the
phase-marker cheat sheet.

## Claude Code → Kiro fidelity matrix

| Upstream mechanism | Kiro CLI | Kiro IDE |
|---|---|---|
| Plugin packaging (`.claude-plugin/`) | `install.sh` (no native plugin system, [kirodotdev/Kiro#8578](https://github.com/kirodotdev/Kiro/issues/8578)) | **Power** (`POWER.md`) |
| Skills `/zensu:x` | **FULL ✓ live-verified** — Agent Skills standard; `/zensu-x` slash commands interactively, invoke by name in `--no-interactive` (headless parses a leading `/` as a built-in command) | **FULL** (same skill dirs) |
| Subagents | **FULL ✓ live-verified** — `subagent` tool (payloads report `use_subagent`), max 4 concurrent (5-aspect fan-out queues the fifth) | **FULL** — `.kiro/agents/*.md` |
| TDD phase-gate (PreToolUse deny) | **FULL ✓ live-verified (D2)** — exit 2 + stderr via `kiro-shim.sh`; a real premature `write` was blocked, file unchanged | advisory (steering) — pending R8 |
| MCP write-gate | **FULL ✓ live-verified (B3)** — `@zensu` matcher + strip chain denied a direct `create_feature` and redirected | advisory (steering) |
| Stop chain enforcement | **mechanism ✓ live-verified (D3)** — enforcer fires and emits `{"decision":"block"}` (budget written); the re-prompt loop is interactive-session behavior, headless `--no-interactive` runs end regardless | n/a |
| Review auto-fix loop (PostToolUse on agent completion) | **FULL ✓ live-verified (D4/R3)** — fires on `use_subagent` completion; wired under both matcher names | skill prose |
| Plan-approval TDD ask (ExitPlanMode) | **DEGRADED by design** — replaced by the per-turn `userPromptSubmit` TDD reminder (**✓ live-verified, B2**: asks before editing, file untouched) + steering | same |
| Session identity | payloads carry **no `session_id`** (live-verified) — convergence via the project-scoped `.zensu/state/session-id-current.txt` written at `agentSpawn` (pinned by `test-session-resolution.sh`) | same |
| Context-compaction nudge | wired but **inert** (Claude-transcript-shaped payload) | n/a |
| Session banner/primer | **FULL ✓ live-verified** (`agentSpawn`; payload keys `hook_event_name`/`cwd`/`prompt`, fires on every spawn) | n/a |
| Pulse session telemetry | **FULL ✓ live-verified (B6)** (plugin-root + MCP pulse tools) | **FULL** |

Verified against kiro-cli **2.6.1** (2026-06-10): diagnostics suite (D1–D4, D6)
5/5, behavior suite B1–B3+B6 green, and the [slow] B5 full-TDD live run green (RED_FAIL→IMPL→GREEN_PASS in the FSM state, 18 witness-recorded shell commands) — `tests/promptfoo/results/`. Re-run
`bash tests/run-promptfoo.sh diagnostics` after Kiro releases to re-verify.

Known kiro-cli 2.6.1 host bug (observed via the B5 live eval): when a
preToolUse hook **blocks** the same tool call repeatedly, the client can crash
with a Bedrock `ValidationException: duplicate toolResult Ids`
(`chat-cli/mod.rs:1905`) and end the session — the gate's deny itself works as
designed; consider reporting upstream if you hit it interactively.

## Configuration

`~/.zensu/config.json` (seeded from [config.example.json](config.example.json),
shared schema with the Claude Code and Codex ports): `hooks.*` toggles
(`sessionBanner`, `tddReminder`, `intentRouter`, `mcpGate`, `autoFix`,
`autoFixMaxRounds`, `selfReview`, `chainEnforcer`, …),
`logging.timestampStyle` (`wall|relative|none`). Env escape hatches:
`ZENSU_TDD_GATE=off`, `ZENSU_MCP_GATE=off`, `ZENSU_CHAIN=off`,
`ZENSU_TEST_WITNESS=off`.

## Tests

```bash
bash tests/run-all.sh                      # deterministic gate (CI): structure tests, no network
bash tests/run-promptfoo.sh diagnostics    # LIVE risk verification vs real kiro-cli (costs credits)
bash tests/run-promptfoo.sh behavior       # LIVE regression suite (RUN_SLOW=1 adds the full TDD run)
```

## Windows

Kiro CLI 2.x is Windows-native; the zensu hooks are bash scripts. Install
[Git for Windows](https://gitforwindows.org/) and run `install.ps1` (a thin
wrapper that locates Git Bash and executes `install.sh`). Without bash the
skills, agents, and MCP server still work — only the hook tier (gates,
witness, stop enforcement) is inactive.

## Repository layout

```
POWER.md mcp.json install.sh install.ps1 VERSION
agents/{cli,ide,prompts}/   hooks/{kiro,lib}/ + 13 hook scripts
skills/zensu-*/             steering/   docs/   reference/
tests/{run-all.sh,structure/,run-promptfoo.sh,promptfoo/}
.github/workflows/{ci,release,evals}.yml
```

## Versioning & releases

`VERSION` + `POWER.md metadata.version` + the README badge + the newest
CHANGELOG heading always carry the same value
(`tests/structure/test-version-sync.sh` enforces it; the `Release` workflow
bumps all four together). Conventional commits; changelog via git-cliff.

## License

[FSL-1.1-Apache-2.0](LICENSE). Ported from
[zensu-claude-code](https://github.com/MKITConsulting/zensu-claude-code)
(upstream v0.8.4) with the
engine-adaptation patterns of the zensu-codex port.
