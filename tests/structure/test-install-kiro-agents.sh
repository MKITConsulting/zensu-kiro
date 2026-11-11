#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME/.kiro"
INSTALL="$ROOT/install.sh"
AGENTS="$HOME/.kiro/agents"
MANIFEST="$HOME/.kiro/zensu/manifest.json"

prompt_of() {
  node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).prompt || ""))' "$1" 2>/dev/null
}
hash_of() {
  node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$1" 2>/dev/null
}
record_of() {
  node -e '
    const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const k = Object.keys(m.files || {}).find(k => k.endsWith("/.kiro/agents/" + process.argv[2]));
    process.stdout.write(k ? m.files[k] : "");
  ' "$MANIFEST" "$1" 2>/dev/null
}
set_record() {
  node -e '
    const fs = require("fs");
    const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const k = Object.keys(m.files || {}).find(k => k.endsWith("/.kiro/agents/" + process.argv[2]));
    if (!k) process.exit(1);
    if (process.argv[3]) m.files[k] = process.argv[3]; else delete m.files[k];
    fs.writeFileSync(process.argv[1], JSON.stringify(m, null, 2) + "\n");
  ' "$MANIFEST" "$1" "${2:-}"
}
kiro_upgrade() {
  mv "$1" "$1.bak" && node -e '
    const fs = require("fs");
    const j = JSON.parse(fs.readFileSync(process.argv[1] + ".bak", "utf8"));
    j.permissions = { rules: [{ capability: "fs_read", effect: "allow" }] };
    j.kiroUpgrade = { revision: 2, fingerprint: "sha256:" + "1".repeat(64), source: "sha256:" + "2".repeat(64) };
    fs.writeFileSync(process.argv[1], JSON.stringify(j, null, 2) + "\n");
  ' "$1"
}

bash "$INSTALL" --scope user --no-default >/dev/null 2>&1 && ok "user-scope install exits 0" || bad "user-scope install failed"
for pair in zensu:zensu-orchestrator zensu-plm:zensu-plm zensu-code-reviewer:zensu-code-reviewer zensu-review-aspect:zensu-review-aspect; do
  agent="${pair%%:*}"; prompt="${pair#*:}"
  P="$(prompt_of "$AGENTS/$agent.json")"
  [ "$P" = "file://../zensu/prompts/$prompt.md" ] && ok "user scope: $agent prompt is file://../zensu/prompts/$prompt.md" || bad "user scope: $agent prompt is '$P'"
  cmp -s "$AGENTS/${P#file://}" "$HOME/.kiro/zensu/prompts/$prompt.md" && ok "user scope: $agent prompt resolves to \$HOME/.kiro/zensu/prompts/$prompt.md" || bad "user scope: $agent prompt does not resolve"
done
grep -l '"prompt": *"file:///' "$AGENTS"/*.json >/dev/null 2>&1 && bad "a rendered prompt is an absolute file:// URI" || ok "no rendered prompt is an absolute file:// URI"

WS="$TMP/ws"; mkdir -p "$WS"
( cd "$WS" && bash "$INSTALL" --scope workspace --no-default >/dev/null 2>&1 ) && ok "workspace-scope install exits 0" || bad "workspace-scope install failed"
P="$(prompt_of "$WS/.kiro/agents/zensu.json")"
[ "$P" = "file://../../../home/.kiro/zensu/prompts/zensu-orchestrator.md" ] && ok "workspace scope: prompt is relative to \$PWD/.kiro/agents" || bad "workspace scope: prompt is '$P'"
cmp -s "$WS/.kiro/agents/${P#file://}" "$HOME/.kiro/zensu/prompts/zensu-orchestrator.md" && ok "workspace scope: prompt resolves to \$HOME/.kiro/zensu/prompts" || bad "workspace scope: prompt does not resolve"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ok "skipped: symlinked workspace (Git Bash has no POSIX symlinks)" ;;
  *)
    mkdir -p "$TMP/deep/a/b/ws"
    ln -s "$TMP/deep/a/b/ws" "$HOME/ws-link"
    ( cd "$HOME/ws-link" && bash "$INSTALL" --scope workspace --no-default >/dev/null 2>&1 )
    P="$(prompt_of "$TMP/deep/a/b/ws/.kiro/agents/zensu.json")"
    cmp -s "$HOME/ws-link/.kiro/agents/${P#file://}" "$HOME/.kiro/zensu/prompts/zensu-orchestrator.md" && ok "symlinked workspace: prompt resolves through the physical agents dir" || bad "symlinked workspace: prompt '$P' does not resolve"
    ;;
esac

for agent in zensu zensu-plm zensu-code-reviewer zensu-review-aspect; do
  cp "$AGENTS/$agent.json" "$TMP/$agent.current"
  sed "s|file://\.\./zensu/prompts/|file://$HOME/.kiro/zensu/prompts/|" "$TMP/$agent.current" > "$TMP/$agent.old"
done
[ "$(hash_of "$TMP/zensu-plm.old")" != "$(hash_of "$TMP/zensu-plm.current")" ] && ok "fixture: older absolute-prompt rendering differs" || bad "fixture: older rendering equals the current one"

NOOP_A="$AGENTS/zensu-plm.json"
kiro_upgrade "$NOOP_A"
NOOP_UP="$(hash_of "$NOOP_A")"

UPD_A="$AGENTS/zensu-code-reviewer.json"
cp "$TMP/zensu-code-reviewer.old" "$UPD_A"; kiro_upgrade "$UPD_A"
set_record zensu-code-reviewer.json "$(hash_of "$TMP/zensu-code-reviewer.old")" || bad "fixture: no manifest record for zensu-code-reviewer.json"
UPD_UP="$(hash_of "$UPD_A")"

MOD_A="$AGENTS/zensu-review-aspect.json"
{ cat "$TMP/zensu-review-aspect.old"; printf '\n'; } > "$MOD_A"; kiro_upgrade "$MOD_A"
set_record zensu-review-aspect.json "$(hash_of "$TMP/zensu-review-aspect.old")" || bad "fixture: no manifest record for zensu-review-aspect.json"
MOD_UP="$(hash_of "$MOD_A")"; MOD_BAK="$(hash_of "$MOD_A.bak")"

NUM_A="$AGENTS/zensu.json"
cp "$TMP/zensu.old" "$NUM_A"; kiro_upgrade "$NUM_A"; cp "$NUM_A" "$NUM_A.bak.1"
set_record zensu.json "$(hash_of "$TMP/zensu.old")" || bad "fixture: no manifest record for zensu.json"
NUM_UP="$(hash_of "$NUM_A")"

OUT="$(bash "$INSTALL" --scope user --no-default --dry-run 2>&1)"
printf '%s\n' "$OUT" | grep -q "^UPDATE .*/zensu-code-reviewer\.json (kiro-cli upgraded it in place)" && ok "dry-run reports the kiro-upgraded UPDATE" || bad "dry-run does not report the kiro-upgraded UPDATE"
[ "$(hash_of "$UPD_A")" = "$UPD_UP" ] && [ -f "$UPD_A.bak" ] && ok "dry-run leaves the kiro-upgraded file and its .bak alone" || bad "dry-run touched the kiro-upgraded file"

OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
printf '%s\n' "$OUT" | grep -q "^NOOP .*/zensu-plm\.json (kiro-cli upgraded it in place)" && ok "kiro-upgraded current rendering: NOOP" || bad "kiro-upgraded current rendering not reported as NOOP"
[ "$(hash_of "$NOOP_A")" = "$NOOP_UP" ] && [ -f "$NOOP_A.bak" ] && ok "kiro-upgraded current rendering: file and .bak kept" || bad "kiro-upgraded current rendering was rewritten"
printf '%s\n' "$OUT" | grep -q "^UPDATE .*/zensu-code-reviewer\.json (kiro-cli upgraded it in place)" && ok "kiro-upgraded older rendering whose .bak matches the manifest: UPDATE" || bad "kiro-upgraded older rendering not updated"
cmp -s "$UPD_A" "$TMP/zensu-code-reviewer.current" && ok "kiro-upgraded file replaced by the current rendering" || bad "kiro-upgraded file content wrong after UPDATE"
[ ! -e "$UPD_A.bak" ] && ok "stale .bak removed (kiro-cli never overwrites an existing .bak)" || bad "stale .bak left behind"
[ "$(record_of zensu-code-reviewer.json)" = "$(hash_of "$UPD_A")" ] && ok "manifest records the updated hash" || bad "manifest record not updated"
printf '%s\n' "$OUT" | grep -q "^SKIP .*/zensu-review-aspect\.json (pre-existing" && ok "user-modified before the kiro upgrade: SKIP" || bad "user-modified kiro-upgraded file not skipped"
[ "$(hash_of "$MOD_A")" = "$MOD_UP" ] && [ "$(hash_of "$MOD_A.bak")" = "$MOD_BAK" ] && ok "user-modified kiro-upgraded file and its .bak untouched" || bad "user-modified kiro-upgraded file overwritten"
printf '%s\n' "$OUT" | grep -q "^SKIP .*/zensu\.json (pre-existing" && [ "$(hash_of "$NUM_A")" = "$NUM_UP" ] && ok "numbered kiro backup (edited between upgrades): SKIP, untouched" || bad "file with a numbered kiro backup was overwritten"

rm -f "$MOD_A" "$MOD_A".bak*
cp "$TMP/zensu-review-aspect.old" "$MOD_A"; kiro_upgrade "$MOD_A"
set_record zensu-review-aspect.json "" || bad "fixture: no manifest record for zensu-review-aspect.json"
FOREIGN_UP="$(hash_of "$MOD_A")"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"
printf '%s\n' "$OUT" | grep -q "^SKIP .*/zensu-review-aspect\.json (pre-existing" && [ "$(hash_of "$MOD_A")" = "$FOREIGN_UP" ] && [ -f "$MOD_A.bak" ] && ok "foreign kiro-upgraded file without a manifest record: SKIP, untouched" || bad "foreign kiro-upgraded file was overwritten"
[ -z "$(record_of zensu-review-aspect.json)" ] && ok "foreign file stays unrecorded" || bad "foreign file got recorded"

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
