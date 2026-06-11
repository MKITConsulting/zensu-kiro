---
name: zensu
displayName: Zensu PLM
description: Product Lifecycle Manager — features as first-class citizens. Feature tracking with KEY-N feature ids, strict RED→GREEN TDD with a phase-gated edit guard, five-perspective review chain, security reviews and STRIDE threat models, greenfield bootstrap and brownfield ghost-scan, user journeys, tiers, and release readiness.
keywords: [zensu, plm, feature, roadmap, tdd, security-review, ghost-scan, bootstrap, journey, tier, release]
metadata:
  version: 0.1.0
---

# Zensu PLM Power

Zensu makes **features first-class citizens** across the whole software
lifecycle — from roadmap to release. Installing this Power gives the Kiro IDE
the Zensu MCP server plus the steering conventions; one onboarding command
adds the 11 `zensu-*` skills and 3 subagents shared by the IDE **and** the
Kiro CLI (where the enforced TDD/MCP gates live).

## What this Power adds

- **MCP server `zensu`** (`https://mcp.zensu.dev/mcp`, auto-registered from
  `mcp.json` on Power install; OAuth runs in the browser on first call) —
  60+ tools: feature CRUD, security, bootstrap, ghost-scan, journeys, tiers,
  wiki, knowledge, pulse.
- **Steering** — `steering/zensu-conventions.md` (always-on conventions) and
  `steering/zensu-tdd-protocol.md` (manual cheat sheet, `#zensu-tdd-protocol`).
- **Skills** (after onboarding step 2) — `/zensu-bootstrap`, `/zensu-ghost-scan`,
  `/zensu-implement`, `/zensu-tdd`, `/zensu-plan-review`, `/zensu-pr-team-review`,
  `/zensu-security-review`, `/zensu-self-review`, `/zensu-reset-review-limit`,
  `/zensu-pulse`, `/zensu-help`.
- **Subagents** (after onboarding step 2) — `zensu-plm` (PLM orchestration),
  `zensu-code-reviewer` (5-perspective review), `zensu-review-aspect`
  (single-perspective fan-out).

## Onboarding

1. Confirm the `zensu` MCP server is connected (Powers panel registered it in
   `~/.kiro/settings/mcp.json`; the first `@zensu` call triggers the OAuth
   browser flow).
2. From the Power checkout directory run:
   `bash install.sh --scope user --no-default`
   — installs the skills, subagents, and the hook runtime to `~/.kiro/` (IDE
   and CLI share these surfaces).
3. Optional, Kiro CLI: `kiro-cli agent set-default zensu` — enables the
   enforced tier (TDD phase-gate, MCP write-gate, witness, stop chain-enforcer)
   in every CLI session.
4. Smoke check: ask "What is Zensu?" (routes to `/zensu-help`) and confirm
   `/zensu-tdd` appears in the slash menu.

## Steering instructions

Follow `steering/zensu-conventions.md` for every task in this workspace:
route Zensu MCP work through `zensu-plm` or the matching skill; for code
changes plan first and ask about the strict TDD flow (`/zensu-tdd`); run the
review chain to completion after implementations; reference features as
`[KEY-N]` in commits.

## Fidelity note (IDE vs CLI)

The hard gates are CLI-tier: Kiro CLI hooks let the zensu agent **block**
premature edits (exit-2 preToolUse) and **refuse to stop** before the review
chain ends. In the IDE these disciplines are steering/skill-driven (advisory)
until IDE pre-tool-use blocking is verified. Full matrix: README.md.
