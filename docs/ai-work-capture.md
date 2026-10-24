# Automatic work capture

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
