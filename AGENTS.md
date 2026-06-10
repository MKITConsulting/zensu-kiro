# zensu-kiro Repo Conventions

## Language

**English only.** All code, comments, docs, commit messages, prompts, fixture
content, and pattern alternations must be in English. Runtime `.zensu/` artifacts
are local-only (gitignored) and exempt.

## What this repo is

The Kiro port of the zensu Product Lifecycle Manager plugin. Upstream content
base: `zensu-claude-code` (Claude Code plugin). Engine-adaptation precedent:
`zensu-codex` (OpenAI Codex CLI port). One repo serves BOTH hosts:

- **Kiro IDE (>= 0.9)** installs it as a Power (`POWER.md` at the repo root,
  `mcp.json` auto-registered, `steering/` shipped with the Power).
- **Kiro CLI (>= 2.6)** has no native plugin system — `install.sh` copies
  skills, agents, the hook runtime, and merges the MCP config.

## Architecture invariants

- `hooks/kiro/kiro-shim.sh` is the ONLY engine-translation layer. Hook scripts
  stay byte-comparable to upstream (Claude output schemas); the shim translates
  deny-JSON to exit 2 + stderr, passes Stop `{"decision":"block"}` through, and
  unwraps `additionalContext` to plain stdout. Never fork engine logic into the
  individual hook scripts.
- `hooks/lib/*.sh` are verbatim upstream copies (plus `zensu-runtime.sh`).
  Fix bugs upstream first, then re-sync. **Documented delta** (upstream-sync
  candidate): `zensu-session.sh` consults the project-scoped
  `.zensu/state/session-id-current.txt` (written by
  `session-start-capture-sid.sh`) as the last step before the PPID fallback —
  on Kiro, model-shell processes carry no session env and a different
  ancestry, so without it skill-run `zensu-log.sh` calls arm a different
  state file than the hooks read (live-verified via the promptfoo
  diagnostics suite; pinned by `tests/structure/test-session-resolution.sh`).
- Hooks are wired in `agents/cli/zensu.json` (Kiro hooks live inside agent
  configs). `agents/cli/zensu-plm.json` intentionally has NO `@zensu` write-gate
  hook — that is the per-agent replacement for upstream's `agent_type` exemption.
- Agent prompt bodies live ONCE in `agents/prompts/*.md`; the IDE variants in
  `agents/ide/*.md` must keep identical bodies (pinned by
  `tests/structure/test-agent-prompt-sync.sh`).

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
