# Native Kiro AI-work capture validation

- Date: 2026-10-25 Europe/Berlin (2026-10-24 22:29–22:30 UTC).
- Source runtime: `419bf8b474506604abfe66be6c4fd04e0a221824`.
- Host: Kiro CLI 2.34.0, native v2 engine; Zensu CLI 0.11.0.
- Native session: `18bff05e-5b66-4023-aed1-e8e4a02454be`.
- Fixture result: `a44d38ac35705db76e7ada362f95d68ea8fd65c2`.

## Setup

A fresh Git fixture and a source archive of the PR runtime were used. A local
agent configuration registered the full production hook mapping through an
observer that forwarded the original payload to the unchanged Kiro shim.
The observer recorded event names, native identity, exit status and hook output.
The test-specific agent prompt confined work to the fixture and selected direct
implementation. No model, session identity, credentials, API responses or
acceptance events were substituted. The released CLI was selected on PATH for
this process only and used the existing personal OAuth login.

## Observed behavior

1. `userPromptSubmit` supplied a native capture primer. Prompt, tool and Stop
   payloads carried the same native session ID.
2. The model called the issued `begin` command with the agreed task, objective
   and criteria; the actual API returned `recording`.
3. The model appended one verified line to README.md and committed only that
   file. The working tree was clean. The native write tool required interactive
   approval in this headless configuration; the already permitted shell performed
   the authorized fixture edit. No tool permissions or gates were changed.
4. The first checkpoint returned `submitted_for_review` with a result-specific
   review URL. The second checkpoint and the native Stop checkpoint both returned
   `already_submitted` with that same URL.
5. Independent read-back through `zensu ai-work get` verified exactly two events
   (`started`, `submitted`), version 2, `cli_authenticated` provenance, and matching
   owner, reporting user and result actor. The artifact matched the fixture HEAD
   and criteria matched `native-capture-v1`.
6. `decision` remained null and `canManage` was false for the CLI. No acceptance
   or revocation operation was attempted.
7. The host exited successfully. Monitored global configuration and installed
   marketplace payload hashes remained unchanged.

## Scope

This validates native Kiro CLI capture against the live service, including
idempotent Stop delivery and authenticated attribution. The test uses an isolated
agent prompt and does not certify every orchestration skill or IDE Power behavior.
The Power still has no native IDE Stop guarantee. Human acceptance remains an
explicit web action; this release test deliberately leaves its fixture unaccepted.
