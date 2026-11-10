# Kiro V3 installer acceptance — 11 November 2026

## Actual native loader

Kiro CLI **3.1.0**, macOS, explicit `chat --v3`, existing provider login.
Eight separate native processes completed with exit 0 and `runFinished`.
Every stream identified engine `v3`, the requested selected agent, and the
expected `user` or `workspace` resource origin. A fallback to a global agent
was not counted as a workspace success. No `PromptFileError` occurred.

| Agent | Isolated user install | Isolated workspace install |
| --- | --- | --- |
| `zensu` | PASS, capture paused | PASS, capture paused, native README edit |
| `zensu-plm` | PASS | PASS |
| `zensu-code-reviewer` | PASS | PASS |
| `zensu-review-aspect` | PASS | PASS |

The three specialist agents have no capture hooks; their loading checks used
read-only prompts and no tools. These checks demonstrate loading, not the
quality of a specialist review or a complete review-chain execution.

The disposable fixture root was `/private/tmp/kiro-installer-v3-lbxs5zx0`.
The paths actually consumed were:

- User: `<fixture>/home/.kiro/agents/<agent>.json`, resolving
  `file://./zensu-prompts/<prompt>.md` under that same `agents` directory.
  Installation used a synthetic `HOME`; native execution used
  `KIRO_HOME=<fixture>/home/.kiro` from `<fixture>/workspace`, with no local
  agent override.
- Workspace: `<fixture>/local-workspace/.kiro/agents/<agent>.json`, resolving
  the same relative URI under that workspace's `agents` directory. Native
  execution ran from `<fixture>/local-workspace`. Stream metadata confirmed
  this workspace as the selected source despite the fixture's global agents.
- Hooks: `<fixture>/home/.kiro/zensu/hooks/kiro/kiro-shim.sh` and the installed
  runtime beneath it. Prompt bodies and relative URI spelling were unmodified
  installer output; no alias agent names or substituted prompts were used.

Each launch used:

```sh
kiro-cli chat --v3 --agent <agent> --no-interactive --trust-workspace \
  --trust-tools=execute_bash,read_file,write_file,str_replace,fs_write,fs_append \
  --output-format stream-json '<synthetic loading-check request>'
```

The initial user-orchestrator launch trusted only `execute_bash` and did not
edit a file. The workspace orchestrator used its own SessionStart identity to
pause capture, then appended `Native installer V3 verified.` to the synthetic
README using a native file tool. Both pause calls returned `capture_disabled`.
No identity from the parent or predecessor chat was supplied to a fixture.

## Real migration and ownership

Native Kiro startup upgraded all four JSONs in each scope, adding its actual
`kiroUpgrade` metadata and `.json.bak` originals. Each backup's SHA-256 matched
the install manifest's pre-migration JSON record. After native loading, the
reviewer's description was customized in each scope. Two normal reinstalls
then preserved all eight migrated JSONs, those additional customizations, and
all eight original backups byte for byte. This tests native migration output
in addition to the deterministic suite's synthetic metadata fixtures.

## Isolation and limits

Every fixture used an empty Zensu CLI configuration directory,
`ZENSU_API_URL=http://127.0.0.1:9`, and `ZENSU_NO_UPDATE_CHECK=1`. No product or
feature binding, capture begin, checkpoint, submit, or old-report upload was
performed. Existing provider authentication was used unchanged. Active chats
and installed user agents were not restarted or replaced.

Initial sandboxed attempts failed at authentication before loading. The same
existing login worked when the authorized native processes ran outside that
sandbox. Temporary authentication-path symlinks explored during diagnosis were
removed before the successful matrix; the definitive tests used no such links.
No login/logout or credential update was needed.

Raw JSONL traces remain local because they contain native conversation keys.
The sanitized summary is `<fixture>/summary.json`; the process logs use
`<scope>-<agent>.jsonl` and `.stderr`. The integration launcher is preserved
locally as `/private/tmp/kiro-installer-native-matrix.py`.

These results do not certify Kiro IDE, native Windows Kiro, or legacy-engine
behavior. Linux and Windows Git Bash CI exercise the deterministic installer
contracts separately. The prior five-host 50/50 report is independent evidence
and is not counted as an installer regression result.
