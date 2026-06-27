# Plan: Re-home zensu-kiro from hosted MCP to the typed `zensu` CLI (+ narrowed write-gate)

**Status:** proposed · **Owner:** TBD · **Created:** 2026-06-26
**Reference:** `zensu-claude-code` PR #117 (the original MCP→CLI re-home) and PR #128 (the *narrowed* CLI write-gate — this plan ports the **post-#128** gate, not the pre-narrow one).

## 1. Why

`zensu-claude-code` re-homed from MCP tools to the typed `zensu` CLI in #117, then narrowed its CLI write-gate in #128 (reads / `--help` / inline `ZENSU_MCP_GATE=off` / localhost-target are no longer gated; only freelance mutations against a real backend are nudged). `zensu-kiro` is still on the **older MCP architecture**:

- Backend access = **OAuth → hosted `mcp.zensu.dev`** on first `@zensu` call (README badge), not the local CLI.
- Write-gate = `hooks/pre-mcp-zensu-gate.sh` — intercepts MCP **tool-name** calls (`@zensu/<tool>`, `zensu___<tool>`, …), classified via `hooks/lib/zensu-mcp-tools.sh`. There is **no** bash CLI gate, no `hooks/lib/zensu-cli-map.sh`.

Because the gate-narrowing (#128) is **bash-CLI-specific** (`--help` flag, inline env prefix, `--api-url`/`ZENSU_API_URL` parsing), it has **no MCP-tool counterpart** and cannot be ported directly. Achieving parity requires re-homing Kiro to the CLI first, then carrying the narrowed bash gate. This is the same migration #117 did for claude-code.

## 2. Product implication (decide explicitly)

Re-homing flips Kiro's backend-access model: **drop hosted `mcp.zensu.dev` OAuth, require the local `zensu` CLI + `zensu auth login`.** This is an onboarding + docs change for Kiro users (CLI install, auth), exactly as claude-code did. Confirm this is intended before executing — if Kiro must keep hosted-MCP for some hosts, this plan does not apply and the gate-narrowing simply does not reach Kiro.

## 3. Surface (files to touch)

Mirrors the #117 file list, adapted to Kiro's layout + shim.

**Gate infra**
- `hooks/pre-bash-zensu-gate.sh` — NEW; port the **narrowed** version from claude-code (post-#128), including: capture env prefixes, allow `--help`/`-h`, honor inline `ZENSU_MCP_GATE=off`, skip localhost `--api-url`/`ZENSU_API_URL`, `isLocalUrl()` helper.
- `hooks/lib/zensu-cli-map.sh` — NEW; port from claude-code (maps `zensu <noun> <verb>` → canonical tool name).
- `hooks/kiro/kiro-shim.sh` — adapt so the bash gate's `permissionDecision:deny` JSON is translated to Kiro's exit-2 + stderr (the shim already does this for the MCP gate; point it at / generalize for the bash gate).
- `reference/hooks.json` — register `pre-bash-zensu-gate.sh` on the Bash/shell matcher; remove the MCP matcher.
- `hooks/pre-mcp-zensu-gate.sh` — retire (delete or leave dormant + unregistered, matching #117).

**Skills (8) — MCP tool calls → `zensu` CLI bash calls**
`zensu-bootstrap`, `zensu-ghost-scan`, `zensu-implement`, `zensu-security-review`, `zensu-pulse`, `zensu-tdd`, `zensu-help`, `zensu-reset-review-limit`.
Per skill: replace `@zensu/<tool>` references with `zensu <noun> <verb> …`; the `zensu-log.sh --workflow-begin --tools "…"` markers already exist (kiro skills use them for MCP) — keep the tool-name list; rewrite the "MCP write-gate / MCP Tools Used / MCP Prompts Used / .mcp.json" prose to the CLI equivalents. **claude-code's same skills are the finished CLI-form template — port them near-verbatim, adjusting Kiro invocation syntax + frontmatter.**

**Agents + routing**
- `agents/cli/zensu.json`, `agents/cli/zensu-plm.json`, `agents/prompts/zensu-orchestrator.md`, `agents/prompts/zensu-plm.md`, `agents/ide/zensu-plm.md` — drop MCP-tool guidance, point at the CLI (`zensu <noun> <verb>`, `--help`, required-flags guidance like codex's `zensu-plm.toml`).
- `hooks/user-prompt-intent-router.sh` — update any MCP-tool references.

**Onboarding / config / docs**
- `README.md` — replace the OAuth-to-`mcp.zensu.dev` flow with `zensu` CLI install + `zensu auth login`; update the hosts/mermaid; keep the Windows Git Bash note.
- `AGENTS.md`, any `.mcp.json` / MCP-server config, plugin manifest — remove MCP-server wiring (cf. #117 `.mcp.json` + `.claude-plugin/plugin.json`).
- `CHANGELOG.md` — `[Unreleased]` entry.

**Tests**
- `tests/structure/test-bash-zensu-gate.sh` — NEW; port from claude-code **including the B33–B37 narrowing cases** (help/inline-off/localhost), adapted to Kiro payload shapes.
- `tests/structure/test-gate-kiro-payloads.sh`, `test-mcp-gate-kiro-names.sh` — convert to the bash-gate form (Kiro CLI command payloads) or retire the MCP-name ones, matching #117's `test-mcp-zensu-gate.sh` removal.
- Update `tests/structure/test-skill-workflow-markers.sh` if it asserts MCP-tool names.

## 4. Phased execution

- **Phase 0 — branch.** Worktree off `main`.
- **Phase 1 — gate infra.** Port narrowed `pre-bash-zensu-gate.sh` + `zensu-cli-map.sh`; wire `reference/hooks.json` + `kiro-shim.sh`; retire MCP gate. Port `test-bash-zensu-gate.sh` (with B33–B37). Convert/retire the two kiro gate tests. `tests/run-all.sh` green. **Note:** the bash gate is inert until skills emit CLI calls — so Phase 1 alone changes no runtime behavior (safe but not yet useful).
- **Phase 2 — skills.** Re-home all 8 skills MCP→CLI using claude-code's skills as the template. Keep workflow-window `--tools` lists. Verify `test-skill-workflow-markers.sh`.
- **Phase 3 — agents + onboarding.** Agents, intent-router, README/AGENTS/manifest, drop MCP-server config + hosted-MCP onboarding → CLI auth.
- **Phase 4 — finalize.** Full `tests/run-all.sh` green, CHANGELOG, single PR (reference #117 + #128).

## 5. Risks / watch-outs

- **kiro-shim output contract** — Kiro expects exit-2+stderr, not Claude's `permissionDecision` JSON. The bash gate must route its deny through the shim; verify with `test-gate-kiro-payloads.sh`-style payloads.
- **Kiro invocation syntax** — skills are `$zensu-x` (not `/zensu:x`) with YAML frontmatter (cf. codex). Keep Kiro's form.
- **Onboarding break** — existing Kiro users on hosted-MCP must install the CLI + `zensu auth login`; call this out in the PR + release notes.
- **Carry the post-#128 gate, not the #117 original** — the narrowing (help/inline/localhost) must be included from the start, plus the known follow-up noted in #128 (command-as-data false-positive: the parser matches `zensu <noun> <verb>` even inside quoted/heredoc strings passed to other tools — consider parsing only the leading command per segment).
- **Windows Git Bash** — the hooks already require Git Bash on Windows; the new bash gate keeps that constraint.

## 6. Acceptance criteria

- `tests/run-all.sh` (no-arg, deterministic) green, including a ported `test-bash-zensu-gate.sh` whose narrowing cases (help/inline-off/localhost) pass.
- No remaining `@zensu/<tool>` / MCP-tool references in skills/agents (grep clean), except where intentionally documenting the deprecation.
- A fresh Kiro user can: install `zensu` CLI → `zensu auth login` → run a skill that creates a feature via the CLI, with the gate allowing it inside the workflow window and denying the same command freelance.
- README/onboarding no longer instructs OAuth-to-`mcp.zensu.dev` as the primary path.
