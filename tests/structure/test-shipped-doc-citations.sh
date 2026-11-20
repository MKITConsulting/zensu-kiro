#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
export ZENSU_CONFIG_DIR="$TMP/empty-cli"
export ZENSU_API_URL="http://127.0.0.1:9"
export ZENSU_NO_UPDATE_CHECK=1
mkdir -p "$HOME"

SCAN='
const fs = require("fs");
const path = require("path");
const [root, pluginRoot, home] = process.argv.slice(1);
const top = new Set(fs.readdirSync(root).filter(n => !n.startsWith(".")));
const docsDir = path.join(root, "docs");
const docs = new Set(fs.existsSync(docsDir)
  ? fs.readdirSync(docsDir).filter(n => n.endsWith(".md") && fs.statSync(path.join(docsDir, n)).isFile())
  : []);
const surfaces = [];
const walk = dir => {
  if (!fs.existsSync(dir)) return;
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.name.endsWith(".md")) surfaces.push(p);
  }
};
["skills", "agents/prompts", "agents/ide", "steering"].forEach(d => walk(path.join(root, d)));
if (fs.existsSync(path.join(root, "POWER.md"))) surfaces.push(path.join(root, "POWER.md"));
let docRefs = 0, tokens = 0;
const out = [];
for (const file of surfaces.sort()) {
  const rel = path.relative(root, file).split(path.sep).join("/");
  let inTable = false, tableAnchored = false;
  fs.readFileSync(file, "utf8").split("\n").forEach((raw, i) => {
    const line = raw.replace(/\r$/, "");
    const row = /^\s*\|/.test(line);
    if (row && !inTable) tableAnchored = /plugin root/i.test(line);
    inTable = row;
    const anchored = /plugin root/i.test(line) || (row && tableAnchored);
    const where = rel + ":" + (i + 1);
    for (const m of line.matchAll(/(?<![\w.\/-])docs\/([\w.-]+\.md)(?![\w.\/-])/g)) {
      if (!docs.has(m[1])) continue;
      docRefs++;
      if (!anchored) out.push(where + ": docs/" + m[1] + " is cited without naming the plugin root");
    }
    if (!anchored) return;
    for (const span of line.matchAll(/`([^`]+)`/g)) {
      for (const word of span[1].split(/\s+/)) {
        const tok = word.replace(/[),.;]+$/, "").replace(/:\d+$/, "");
        if (!tok || /[<>*{}$"\x27()\[\]…]/.test(tok)) continue;
        let target;
        if (tok.startsWith("~/")) target = path.join(home, tok.slice(2));
        else if (top.has(tok.split("/")[0])) target = path.join(pluginRoot, tok);
        else continue;
        tokens++;
        if (!fs.existsSync(target)) out.push(where + ": " + tok + " does not exist in an installed session");
      }
    }
  });
}
for (const v of out) console.log("VIOLATION " + v);
console.log("SUMMARY docs=" + docRefs + " tokens=" + tokens);
'
scan() { node -e "$SCAN" "$@"; }

if bash "$ROOT/install.sh" --scope user --no-default >/dev/null 2>&1; then
  ok "install.sh installs into a sandbox HOME"
else
  bad "install.sh failed in a sandbox HOME"
fi

OUT="$(scan "$ROOT" "$HOME/.kiro/zensu" "$HOME")"
VIOLATIONS="$(printf '%s\n' "$OUT" | sed -n 's/^VIOLATION //p')"
if [ -z "$VIOLATIONS" ]; then
  ok "every plugin file a skill, agent prompt, steering file or POWER.md cites is reachable in an installed session"
else
  printf '%s\n' "$VIOLATIONS" | sed 's/^/      /'
  bad "a shipped surface cites a plugin file that an installed session cannot open"
fi

DOCS="$(printf '%s\n' "$OUT" | sed -n 's/^SUMMARY docs=\([0-9]*\) tokens=[0-9]*$/\1/p')"
TOKENS="$(printf '%s\n' "$OUT" | sed -n 's/^SUMMARY docs=[0-9]* tokens=\([0-9]*\)$/\1/p')"
if [ "${DOCS:-0}" -gt 0 ] && [ "${TOKENS:-0}" -gt 0 ]; then
  ok "the scan checked $DOCS plugin-doc citations and $TOKENS plugin-root paths"
else
  bad "the scan checked nothing (docs=${DOCS:-?} tokens=${TOKENS:-?})"
fi

HEADER="$(grep -m1 '^| Question type |' "$ROOT/skills/zensu-help/SKILL.md")"
if printf '%s' "$HEADER" | grep -qi 'plugin root'; then
  ok "zensu-help resolves its routing-table sources at the plugin root"
else
  bad "zensu-help's routing-table header does not name the plugin root"
fi

FIX="$TMP/fixture"
mkdir -p "$FIX/root/docs" "$FIX/root/skills/demo" "$FIX/plugin/docs" "$FIX/home/.kiro/skills"
printf 'shipped\n' > "$FIX/root/docs/shipped.md"
printf 'unshipped\n' > "$FIX/root/docs/unshipped.md"
printf 'readme\n' > "$FIX/root/README.md"
printf 'changes\n' > "$FIX/root/CHANGELOG.md"
printf 'shipped\n' > "$FIX/plugin/docs/shipped.md"
printf 'readme\n' > "$FIX/plugin/README.md"
cat > "$FIX/root/skills/demo/SKILL.md" <<'EOF'
Read `docs/shipped.md` under the plugin root.
Read `docs/shipped.md` first.
Read `docs/unshipped.md` under the plugin root.
Glob the project's `docs/*.md` and `docs/auth.md`.

| Question | Source (relative to the plugin root) |
|---|---|
| Changes | `CHANGELOG.md` |
| Overview | `README.md` |

| Question | Source |
|---|---|
| Guide | `docs/shipped.md` |

Open `~/.kiro/skills/missing/SKILL.md` and `~/.kiro/skills/` under the plugin root.
EOF
FOUND="$(scan "$FIX/root" "$FIX/plugin" "$FIX/home" | sed -n 's/^VIOLATION skills\/demo\/SKILL\.md:\([0-9]*\):.*/\1/p' | tr '\n' ' ')"
if [ "$FOUND" = "2 3 8 13 15 " ]; then
  ok "the scan flags planted unanchored or unshipped citations and passes anchored, shipped ones"
else
  bad "the planted fixture yielded violations on lines [$FOUND], expected [2 3 8 13 15 ]"
fi

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
