# Kiro V3 prompt installation and migration

Kiro CLI 3.1.0's V3 loader rejects absolute `file://` prompt URIs and paths
outside its prompt directory boundary. The installer now copies canonical
`agents/prompts/*.md` into the selected scope:

| Scope | Agent configuration | Prompt location |
| --- | --- | --- |
| User | `~/.kiro/agents/<agent>.json` | `~/.kiro/agents/zensu-prompts/<prompt>.md` |
| Workspace | `<workspace>/.kiro/agents/<agent>.json` | `<workspace>/.kiro/agents/zensu-prompts/<prompt>.md` |

All four agents use `file://./zensu-prompts/<prompt>.md`; `zensu` uses
`zensu-orchestrator.md`. The orchestrator's file resource uses the same URI.
Hook runtime paths remain absolute and user-scoped. Legacy runtime prompt
copies under `~/.kiro/zensu/prompts/` remain available for preserved older
configurations. New agents do not use those copies.

Run the installer from the intended workspace for a workspace installation:

```sh
bash /path/to/zensu-kiro/install.sh --scope workspace --no-default
kiro-cli chat --v3 --agent zensu
```

Use `--scope user` for global agents. Explicit `--v3` matters: headless Kiro
can otherwise select the older harness. These CLI checks do not certify the IDE.

## Reinstall and uninstall ownership

Both the scoped prompts and rendered JSONs have SHA-256 records in the scope's
manifest. Reinstall updates a file only if its current bytes still match the
installer's record (or already match the requested output). Changed and foreign
files are skipped on every reinstall. Uninstall deletes only matching recorded
files in the selected scope; workspace uninstall preserves the user runtime.
Symlinked agent/prompt directories or prompt files are refused before mutation.
Use real directories and files for these installation paths.

Kiro's own `agent upgrade` can change JSONs and add `kiroUpgrade` metadata and
`.json.bak` files. Such JSONs no longer match the install manifest and are
**intentionally preserved**, including later user changes. A `.bak` matching
an old manifest proves nothing about the current JSON. The installer neither
uses backups as ownership proof nor rewrites migration fingerprints.

Even an unchanged legacy JSON is kept when its old runtime prompt is customized:
automatically changing its URI would stop applying those edits. Migrate the
intentional prompt changes into the scoped copy before replacing that JSON.

A `SKIP` message is not proof that an old prompt URI has been repaired. Inspect
the current `prompt` value in every skipped agent. Do not use a blanket
`--force` reinstall to fix one agent: it also overwrites unrelated local edits.

## Explicit replacement of skipped agents

This is an opt-in replacement procedure. Keep the original configurations and
backups until you have compared and restored all custom settings. Stop if you
cannot account for a difference; do not overwrite the only copy of a change.

1. Run the normal installer for the intended scope. It installs the new prompt
   copies and preserves modified JSONs and prompts. Note every `SKIP`.
2. Select the correct agent directory and make a private backup of its contents,
   including existing `.bak` files. For a workspace install, run these commands
   from that workspace and use `agent_dir="$PWD/.kiro/agents"` instead:

   ```sh
   agent_dir="$HOME/.kiro/agents"
   backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/zensu-agent-backup.XXXXXXXX")"
   cp -R "$agent_dir" "$backup_dir/agents"
   printf 'Keep this backup until migration is verified: %s\n' "$backup_dir"
   ```

   Also preserve any customized legacy runtime prompts before replacing their
   use. New scoped prompts may contain different local edits; compare both.
3. Move **only the agent you choose to replace** out of the active directory.
   For example, for `zensu` (repeat explicitly for other affected names):

   ```sh
   mv "$agent_dir/zensu.json" "$backup_dir/zensu.json.original"
   if [ -f "$agent_dir/zensu.json.bak" ]; then
     mv "$agent_dir/zensu.json.bak" "$backup_dir/zensu.json.bak.original"
   fi
   bash /path/to/zensu-kiro/install.sh --scope user --no-default
   ```

   Use `--scope workspace` for the workspace directory. No `--force` is needed.
   Other customized agents, prompts, and skills remain skipped.
4. Compare the replacement with the saved configuration. Reapply intentional
   customizations using Kiro's supported agent configuration/editor, preserving
   the new relative `prompt` and file resource. Do not copy stale `kiroUpgrade`
   metadata into a fresh config. Do not remove migration metadata from an
   already customized universal config merely to force another migration.
   Keep both legacy and V3 settings consistent with Kiro's current format.
5. If using `kiro-cli agent upgrade`, first inspect `--dry-run` on a staging
   directory containing copies of **only your selected agent JSONs**. Upgrade
   those staged copies, inspect the complete diff, then copy back only the
   approved replacements. This avoids migrating unrelated agents. Kiro owns
   its fingerprints; out-of-sync files require review, not a fabricated hash.
6. Validate each selected config with `kiro-cli agent validate --path <file>`
   and actually launch `kiro-cli chat --v3 --agent <name>` from the intended
   workspace. Validation alone does not prove that the V3 prompt loader accepts
   a file. A user agent should be tested from a workspace with no local override.

To roll back, copy the saved original JSON and its original `.bak` back into the
selected directory. The legacy runtime prompt copies are retained by installs.
Never delete the backup as part of reinstall or rollback. Once Kiro or the user
changes a new config, later reinstalls will preserve it again. Uninstall can
leave customized configs behind while removing owned prompts/runtime files;
review these retained configs before using them after uninstall.

## Regression and native acceptance

`bash tests/run-all.sh` includes `test-install-prompt-containment.sh`: all four
canonical bodies in both scopes, relative URI containment, exact manifest
hashes, byte/mtime idempotency, clean legacy upgrades, repeated preservation of
migrated and subsequently edited JSONs despite matching `.bak` hashes, foreign
files, active legacy prompt customizations, scoped uninstall, and symlink refusal.
It requires no Kiro login or API.
Migration metadata in deterministic fixtures is synthetic; it does not model
Kiro's migration algorithm.

Native acceptance must additionally use the real `kiro-cli chat --v3` loader
with disposable user/workspace installation data. Keep provider authentication
unchanged, isolate global files with Kiro's [documented `KIRO_HOME` override](https://kiro.dev/docs/cli/reference/settings/), and block Zensu
API traffic in fixtures with an empty `ZENSU_CONFIG_DIR` and
`ZENSU_API_URL=http://127.0.0.1:9`. Pause capture using the fixture session's own
native helper before edits. Do not borrow identities, run product bindings, or
submit reports. Record the exact scopes, agent names, CLI version, and any
fixture-only adjustments; distinguish schema validation from real V3 loading.

See the [native acceptance record](validation/2026-11-11-kiro-v3-installer.md) for
the tested paths, real migration/reinstall results, and explicit limits.
