# Automatic work capture

## Recover a blocked local receipt

Recovery never uploads a report, accepts a result, repairs attribution or changes
server history. Run these commands in the affected worktree with the exact
capture key supplied by its plugin; do not borrow another conversation's key.

```sh
zensu ai-work recover --session <capture-key>
zensu ai-work recover --session <capture-key> --archive <active-receipt-sha256> --confirm
zensu ai-work recover --session <capture-key> --restore <archived-receipt-sha256> --confirm
```

Inspection is offline and returns the active receipt digest, its reason and the
same session's archives. Archive requires the exact inspected digest and explicit
confirmation. Restore requires an empty active slot, checks the digest and leaves
the archive intact. Its working copy is paused using the existing `capturePaused`
flag, which older plugin versions also honor; only an explicit validated `begin`
can resume reporting. All other JSON values are retained without numeric rounding. All mutations share the capture lock; a held or stale lock is
reported for inspection, never forcibly removed. No OAuth login is needed.

A new, explicitly scoped `begin` preserves an old receipt lacking product or
feature scope before replacing it, including its pending event and unknown fields.
The result's `recoveredReceipt` identifies that local archive. Missing or rejected
new scope leaves the legacy receipt untouched. A fully scoped pending report still
requires its exact retry or explicit CLI archival; it is never silently retargeted.

Archives live at `<git-dir>/zensu-ai-work-v1/recovery/<capture-key>/<sha256>.json`.
They retain the original bytes, event IDs, expected version and any review details.
They are private, outside tracked files, and are never scanned or submitted by Stop.
Restoration does not make legacy scope valid: use a new explicitly confirmed goal
for new work. Every restored valid receipt requires an explicit `begin` for its original
goal before retrying; restoration alone never enables Stop reporting. Archival is not evidence that a previous request
failed at the server; a lost response may already have been recorded. Check that
original work's server history explicitly before any manual resubmission, and keep
its original event ID for retries. Never delete or edit receipts to unblock capture.



## Feature scope per work objective

Automatic capture requires both the confirmed repository product and an explicitly
selected feature for each goal: pass `--feature <feature-uuid>` to `begin`.
The server derives the product from the feature and validates an optional
`--feature-revision <revision-uuid>`. Never infer confirmation from a branch,
repository, title or a previous goal.

For product-wide maintenance, explicitly pass `--maintenance-reason <reason>`
instead of a feature. Cross-product work requires explicit human intent and
`--cross-product-reason <reason>`. These choices are mutually exclusive.
Without a goal scope, capture returns `skipped_missing_feature`; development
continues. A rejected or incomplete goal change pauses the old receipt, including
Stop capture, until an explicit valid `begin` resumes it. Fully scoped pending
reports retain their frozen identity and must be retried under their original
goal or explicitly archived locally. Legacy receipts can be preserved separately
when a new explicitly scoped goal begins, as described above.

Receipts freeze feature, optional revision, exception reason and product.
Legacy receipts without feature scope cannot automatically submit new results.
Historical server records and human acceptance remain unchanged. Upgrade the
feature-scope backend first, then CLI, then plugins; older servers/CLIs fail closed.


## Confirmed product scope

Automatic capture requires an explicitly human-confirmed repository product.
After the user confirms the exact product, run `zensu ai-work bind --product <uuid> --confirm`
in the repository. Never infer confirmation from a folder name, remote, existing
configuration, a prior unassigned record, or permission to implement a task.
The CLI validates the product against the current personal OAuth account and
organization. Its private binding lives in the Git common directory, outside
tracked files, and is shared by worktrees of that repository. It contains IDs and
an origin fingerprint, never credentials or the remote URL.

`zensu ai-work context` revalidates the binding. A host, account, organization,
origin or product-access change requires renewed explicit confirmation. Missing
bindings return `ready=false` and `workScope=unassigned`; the helper returns
`skipped_unassigned` without creating a work entry. Continue authorized coding.
Do not create a placeholder or silently switch to cross-product capture.

Only when the user explicitly requests work spanning products, supply
`--cross-product-reason <specific-reason>` on `begin`. The reason is required for
that goal and cannot be a repository default. Normal product work (including its
tests) keeps the confirmed product; run purpose and product scope are independent.

Receipts freeze product/cross-product scope, reason and authenticated identity
before declaration. Checkpoints revalidate the same scope. A changed binding
cannot retarget a pending report. Legacy receipts without confirmed scope remain
untouched and cannot auto-submit new results: use a new explicitly scoped goal.
Existing unassigned server entries appear in the separate **Unassigned** tab,
excluded from regular result metrics, with history and human acceptance retained.

Requires the product-scope backend and CLI `ai-work bind`, `context --cross-product`,
and `start --product/--cross-product-reason`. Upgrade backend, CLI, then plugins;
missing protocol support is visible incomplete capture. No fallback to an older
unscoped command is allowed. Submission never accepts a result.


A personal `zensu auth login` identifies the reporting account. Use Zensu CLI v0.11.0 or newer. The CLI must
provide `ai-work context/start/get/submit`, and the server must provide the
capture endpoints and CLI provenance migration. Missing prerequisites remain
visible incomplete capture; never borrow credentials or change login automatically.

Record one already agreed implementation goal using a stable task key, a concise
objective (at most 160 characters), and the agreed criteria version or digest.
Reuse all three on retries; changed scope uses a new task key. Do not record work
for startup, greetings or read-only questions. Capture applies in direct mode too
and is independent of private Pulse opt-in.

Only a new clean Git HEAD is submitted. A private receipt in the worktree Git
metadata persists stable IDs before requests, binds API host and reporting account,
and retries the same result after interrupted delivery. Dirty or unchanged work,
identity changes and version conflicts remain incomplete. Do not discard pending
receipts to hide an error. A process crash can leave a lock requiring inspection.

Include the returned exact `reviewUrl` at handoff. Human acceptance and revocation
are explicit authenticated web decisions about that result version. Never accept
from an agent, infer approval from a merge/release/test, or operate the decision
dialog on the human's behalf. Later results do not inherit acceptance. Attribution
identifies an authenticated reporting account, not human code authorship.

No code, transcripts, prompts, diffs, file lists, credentials or token usage are
uploaded. Both dashboard scopes use the same canonical units and credits.

## Kiro CLI and IDE Power

The main CLI agent initializes from `agentSpawn` on legacy hosts and lazily from
`userPromptSubmit` when the host provides a native `session_id`. Repeated native
prompts reuse the same binding; legacy prompts never create new keys. Follow
its exact begin/checkpoint commands; never use `.zensu/state/session-id-current.txt`.
When the host supplies a real session_id, Stop can retry that exact session.
Older hosts without session_id use an independent random conversation key. The
agent retains it and checkpoints automatically before handoff; Stop explicitly
reports that it cannot identify the session. This is not native session proof.

The IDE Power is advisory: if no capture primer was supplied, the main agent runs
`node <installed-runtime>/hooks/kiro/ai-work.js session` once for this conversation
and follows the returned instructions. Keep the key in this conversation, never
borrow another conversation's key or reinitialize to hide a pending result.
The installed runtime is normally `~/.kiro/zensu`; use the configured installation
path. The Power alone does not install a native IDE Stop hook. No human must
re-enter goals or results in the dashboard, but host-independent guaranteed Stop
capture is not claimed.

Current hook documentation describes session_id, while this repository's older
native observations lacked it. Capability is checked from the actual payload,
not assumed from a version number: https://kiro.dev/docs/hooks/types/.

## Validation boundary

On 2026-10-25 (Europe/Berlin), an isolated Kiro CLI 2.34.0 conversation ran
this checkout's unchanged hook adapter and shim against the released Zensu CLI
0.11.0 and the live capture API. Native prompt, tool and Stop events retained the
same session ID. The agent declared the agreed fixture goal, committed its result,
and submitted the exact clean commit with `native-capture-v1` criteria. A second
checkpoint and the native Stop hook both returned `already_submitted`.

Read-back confirmed one authenticated owner/reporter, one submission, version 2,
and no human decision; the CLI could not manage acceptance. Monitored global
settings and installed plugin hashes remained unchanged. See the
[native validation record](validation/2026-10-25-native-ai-work-capture.md).
The Power/IDE path remains advisory and has not been validated as native IDE capture.


## Declared source and run purpose

The reporter supplies its plugin name and packaged version automatically. These
are client declarations; personal OAuth authenticates the reporting account,
not the host or authorship. Use `--run-kind work` (the default) for normal product
implementation, including writing/running tests. Use `--run-kind test` explicitly
when the goal itself is a validation, demo or capture probe. Never guess from the
title, test commands or a green suite. Preserve the agreed purpose on retries.

New receipts freeze source, version and initial purpose before the first request.
An upgrade preserves existing receipt metadata; a receipt without confirmed product scope cannot resume automatic reporting. Historical receipts keep missing
metadata unknown; do not rewrite or delete them to force attribution. Purpose
corrections belong to the current owner/admin in the web UI, with a reason; the
reporter cannot classify, accept or revoke. Both dashboard scopes exclude declared
tests by default but offer an include-tests switch. Unknown records remain visible.
Billing credits stay separately unfiltered because they are not linked to runs.

Requires a CLI supporting the `ai-work start --source --source-version --run-kind`
flags and a backend supporting run metadata. Upgrade backend and CLI before the
plugin. Missing support is an incomplete capture, never a silent fallback. The
internal `--legacy-metadata` flag only replays pre-metadata receipts unchanged.

## Check scope before implementation

Use the same native helper and session/workspace arguments shown above, replacing
`begin` with `preflight` and omitting task/title/criteria. Confirmed per-goal feature
or exception flags are optional for this read-only check. It checks CLI
capabilities before requesting context and returns a precise prerequisite status.
Ask once for missing product/feature confirmation early, reuse a valid product
binding, and continue coding if scope is unavailable. Do not create placeholder
work or infer consent from discovery.

If reporting was explicitly declined, call the same native helper with `pause`
instead, without goal flags. This is local only; it preserves pending receipts,
suppresses preflight/context and Stop submissions, and asks no scope questions.
Only an explicitly authorized, confirmed `begin` clears this pause after success.
A failed or incompatible begin keeps the pause. CLI capability checks run again
before begin/checkpoint writes, so a later downgrade cannot drop required flags.

See [CLI installation and updates](cli-install-update.md), including `zensu update`,
the fallback for older versions, PATH diagnostics and all preflight statuses.
