#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$ROOT/install.sh"
RESOLVER_SRC="$ROOT/hooks/lib/resolve-plugin-root.sh"
INVENTORY="$ROOT/runtime-files.txt"
ANCHOR_HELPER="$ROOT/hooks/lib/resolve-native-anchor.js"
CYGPATH_POSIX=""
case "${OSTYPE:-}" in
  msys*|cygwin*)
    if [ "${MSYS2_ENV_CONV_EXCL:-}" != "*" ]; then
      for RAW_ENV_NAME in ZENSU_KIRO_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_RAW ZENSU_KIRO_WORKSPACE_ANCHOR_RAW ZENSU_KIRO_TEST_ANCHOR_RAW ZENSU_KIRO_ROOT; do
        case ";${MSYS2_ENV_CONV_EXCL:-};" in
          *";$RAW_ENV_NAME;"*) ;;
          *) MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+${MSYS2_ENV_CONV_EXCL};}$RAW_ENV_NAME" ;;
        esac
      done
    fi
    export MSYS2_ENV_CONV_EXCL
    CYGPATH_POSIX="${BASH%/*}/cygpath.exe"
    BASH_POSIX="$BASH"; case "$BASH_POSIX" in *.exe) ;; *) [ -x "${BASH_POSIX}.exe" ] && BASH_POSIX="${BASH_POSIX}.exe" ;; esac
    ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE="$("$CYGPATH_POSIX" -m "$CYGPATH_POSIX")"
    ZENSU_KIRO_TRUSTED_BASH_NATIVE="$("$CYGPATH_POSIX" -m "$BASH_POSIX")"
    export ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE ZENSU_KIRO_TRUSTED_BASH_NATIVE
    ;;
esac

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$*"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$*"; }

command -v node >/dev/null 2>&1 || { echo "node required"; exit 1; }

if [ -f "$RESOLVER_SRC" ] && bash -n "$RESOLVER_SRC" 2>/dev/null; then
  ok "K1 fixed-runtime resolver exists and parses"
else
  bad "K1 fixed-runtime resolver exists and parses"
fi

if [ -f "$INVENTORY" ] && [ -f "$ROOT/scripts/install-support.js" ] && [ ! -e "$ROOT/hooks/lib/install-support.js" ] && \
   node "$ROOT/scripts/sync-runtime-inventory.js" --check && \
   ROOT="$ROOT" node - <<'NODE'
const fs=require("fs"), path=require("path"), root=process.env.ROOT;
const inventory=fs.readFileSync(path.join(root,"runtime-files.txt"),"utf8").split(/\r?\n/).filter(Boolean);
if (!inventory.includes("VERSION") || !inventory.includes("PROTOCOL_VERSION")) process.exit(1);
if (inventory.some(rel=>rel==="hooks/lib/install-support.js" || !fs.existsSync(path.join(root,rel)))) process.exit(2);
const resolver=fs.readFileSync(path.join(root,"hooks/lib/resolve-plugin-root.sh"),"utf8");
const match=/\/\* zensu-runtime-inventory:start \*\/\s*(\[[\s\S]*?\])\s*\/\* zensu-runtime-inventory:end \*\//.exec(resolver);
if (!match || JSON.stringify(JSON.parse(match[1]))!==JSON.stringify(inventory)) process.exit(3);
NODE
then
  ok "K1b one declarative inventory drives the installed and embedded runtime closure"
else
  bad "K1b runtime inventory is missing, duplicated, or includes installer-only code"
fi

TMP="$(mktemp -d -t zensu-kiro-root-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
ZENSU_KIRO_TEST_ANCHOR_RAW="$TMP"
ZENSU_KIRO_TEST_ANCHOR_NATIVE="$(ZENSU_KIRO_ANCHOR_RAW="$TMP" node "$ANCHOR_HELPER")" || {
  echo "could not resolve test anchor" >&2; exit 1;
}
export ZENSU_KIRO_TEST_ANCHOR_RAW ZENSU_KIRO_TEST_ANCHOR_NATIVE
node -p 'process.ppid' > "$TMP/native-shell.pid"
LIVE_PID="$(cat "$TMP/native-shell.pid")"
export HOME="$TMP/home with space"
mkdir -p "$HOME/.zensu" "$TMP/workspace with space"
printf '%s\n' '/tmp/legacy-pointer-must-survive' > "$HOME/.zensu/plugin-root"

OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then ok "K2 user install succeeds with a spaced HOME"; else bad "K2 user install rc=$RC: $OUT"; fi

RUNTIME="$HOME/.kiro/zensu"
RESOLVER="$RUNTIME/hooks/lib/resolve-plugin-root.sh"
GOT="$(env HOME="$HOME" bash "$RESOLVER" 1 2>/dev/null)"
if [ "$GOT" = "$RUNTIME" ]; then ok "K3 resolver returns the fixed user runtime"; else bad "K3 resolver got '$GOT'"; fi

if [ -n "$CYGPATH_POSIX" ]; then
  cp "$RUNTIME/manifest.json" "$TMP/manifest-before-case-alias.json"
  MANIFEST="$RUNTIME/manifest.json" node - <<'NODE'
const fs = require("fs");
const file = process.env.MANIFEST;
const manifest = JSON.parse(fs.readFileSync(file, "utf8"));
const key = Object.keys(manifest.files).find(value => /[\\/]hooks[\\/]lib[\\/]zensu-log\.sh$/.test(value));
if (!key) process.exit(1);
const alias = key.replace(/([\\/])hooks([\\/])/, "$1HOOKS$2");
manifest.files[alias] = manifest.files[key];
delete manifest.files[key];
fs.writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`);
NODE
  if env HOME="$HOME" bash "$RESOLVER" 1 >/dev/null 2>&1; then
    bad "K3c resolver accepted a case-aliased manifest path"
  else
    ok "K3c resolver rejects manifest paths that differ from filesystem spelling"
  fi
  cp "$TMP/manifest-before-case-alias.json" "$RUNTIME/manifest.json"
else
  ok "K3c skipped case-alias check (requires native Windows Node under Git Bash)"
fi
if env HOME="$HOME" bash "$RESOLVER" >/dev/null 2>&1; then
  bad "K3b resolver accepted a caller without a scope protocol binding"
else
  ok "K3b resolver requires an explicit compatible scope protocol"
fi

OPTIONAL_SKILL="$HOME/.kiro/skills/zensu-help/SKILL.md"
rm -f "$OPTIONAL_SKILL"
GOT="$(env HOME="$HOME" bash "$RESOLVER" 1 2>/dev/null)"
if [ "$GOT" = "$RUNTIME" ]; then
  ok "K3d resolver tolerates a missing optional non-runtime manifest target"
else
  bad "K3d missing optional skill incorrectly invalidated the runtime"
fi
bash "$INSTALL" --scope user --no-default >/dev/null 2>&1

if [ "$(cat "$HOME/.zensu/plugin-root" 2>/dev/null)" = '/tmp/legacy-pointer-must-survive' ]; then
  ok "K4 installer ignores and preserves the legacy pointer"
else
  bad "K4 installer rewrote the legacy pointer"
fi

AGENT="$HOME/.kiro/agents/zensu.json"
if AGENT="$AGENT" RUNTIME="$RUNTIME" node - <<'NODE'
const j = require(process.env.AGENT);
const hooks = Object.values(j.hooks || {}).flat();
if (!hooks.length) process.exit(1);
const prefix = `bash "${process.env.RUNTIME}/hooks/kiro/kiro-shim.sh" 1 `;
if (!hooks.every(h => typeof h.command === "string" && h.command.startsWith(prefix))) process.exit(2);
NODE
then
  ok "K5 rendered agent hook commands quote the spaced runtime path"
else
  bad "K5 rendered agent hook commands are not path-safe"
fi

SHIM_BARRIER="$TMP/shim-lock-barrier"; mkdir -p "$SHIM_BARRIER"
(
  printf '{"session_id":"runtime-lock-first","cwd":"%s"}' "$TMP" | \
    env HOME="$HOME" NODE_ENV=test ZENSU_KIRO_SHIM_TEST_BARRIER_DIR="$SHIM_BARRIER" \
      bash "$RUNTIME/hooks/kiro/kiro-shim.sh" 1 session-start-banner.sh > "$TMP/parallel-hook-first.out" 2>/dev/null
) & FIRST_SHIM_PID=$!
i=0; while [ ! -e "$SHIM_BARRIER/runtime-lock.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
PARALLEL_OK=1
if [ -e "$SHIM_BARRIER/runtime-lock.reached" ] && [ -f "$HOME/.zensu-kiro-install.lock" ] && [ ! -L "$HOME/.zensu-kiro-install.lock" ]; then
  printf '{"session_id":"runtime-lock-second","cwd":"%s"}' "$TMP" | \
    env HOME="$HOME" bash "$RUNTIME/hooks/kiro/kiro-shim.sh" 1 session-start-banner.sh > "$TMP/parallel-hook-second.out" 2>/dev/null &
  SECOND_SHIM_PID=$!
  sleep 0.2
  kill -0 "$SECOND_SHIM_PID" 2>/dev/null || PARALLEL_OK=0
  [ ! -s "$TMP/parallel-hook-second.out" ] || PARALLEL_OK=0
  : > "$SHIM_BARRIER/runtime-lock.release"
  wait "$FIRST_SHIM_PID" || PARALLEL_OK=0
  wait "$SECOND_SHIM_PID" || PARALLEL_OK=0
else
  PARALLEL_OK=0
  kill "$FIRST_SHIM_PID" 2>/dev/null || true
  wait "$FIRST_SHIM_PID" 2>/dev/null || true
fi
if [ "$PARALLEL_OK" -eq 1 ] && [ -s "$TMP/parallel-hook-first.out" ] && \
   [ -s "$TMP/parallel-hook-second.out" ] && [ ! -e "$HOME/.zensu-kiro-install.lock" ]; then
  ok "K5b second dispatch blocks while first owns the runtime lock, then both complete"
else
  bad "K5b shim dispatches did not demonstrably serialize on the runtime lock"
fi

RESOLVER_CLAIM_TOKEN="$(printf 'a%.0s' {1..64})"
RESOLVER_CLAIM="$HOME/.zensu-kiro-install.lock.recovery.reclaim.$RESOLVER_CLAIM_TOKEN"
printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z","targetFingerprint":"resolver-fixture"}\n' \
  "$LIVE_PID" "$RESOLVER_CLAIM_TOKEN" > "$RESOLVER_CLAIM"
if env HOME="$HOME" bash "$RESOLVER" 1 >/dev/null 2>&1; then
  bad "K5c resolver ignored an active recovery election claim"
else
  ok "K5c resolver fails closed while a recovery election claim exists"
fi
rm -f "$RESOLVER_CLAIM"

ZLOG="$RUNTIME/hooks/lib/zensu-log.sh"
printf '%s\n' '# tampered fixture' >> "$ZLOG"
if env HOME="$HOME" bash "$RESOLVER" 1 >/dev/null 2>&1; then
  bad "K6 resolver accepted a runtime helper whose manifest hash changed"
else
  ok "K6 resolver rejects a runtime helper whose manifest hash changed"
fi
SHIM_OUT="$(printf '{"session_id":"integrity-dispatch","cwd":"%s"}' "$TMP" | \
  env HOME="$HOME" bash "$RUNTIME/hooks/kiro/kiro-shim.sh" 1 session-start-banner.sh 2>/dev/null)"
if [ -z "$SHIM_OUT" ]; then
  ok "K6b automatic hooks refuse dispatch while runtime integrity is invalid"
else
  bad "K6b automatic hook bypassed the complete runtime resolver"
fi
printf '{"tool_name":"shell","tool_input":{"command":"true"}}' | \
  env HOME="$HOME" bash "$RUNTIME/hooks/kiro/kiro-shim.sh" 1 pre-bash-zensu-gate.sh > "$TMP/security-shim.out" 2> "$TMP/security-shim.err"
SECURITY_SHIM_RC=$?
if [ "$SECURITY_SHIM_RC" -eq 2 ] && grep -qi 'runtime' "$TMP/security-shim.err"; then
  ok "K6c invalid runtime fails closed for security preToolUse hooks"
else
  bad "K6c invalid runtime silently disabled a security preToolUse hook (rc=$SECURITY_SHIM_RC)"
fi

bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1
GOT="$(env HOME="$HOME" bash "$RESOLVER" 1 2>/dev/null)"
if [ "$GOT" = "$RUNTIME" ]; then ok "K7 forced repair restores a valid runtime"; else bad "K7 repair did not restore runtime"; fi

# Resolver validation is coupled to the install transaction. A concurrent
# writer appearing between validation passes must make resolution fail closed.
VALIDATION_BARRIER="$TMP/runtime-validation-barrier"; mkdir -p "$VALIDATION_BARRIER"
env HOME="$HOME" NODE_ENV=test ZENSU_KIRO_TEST_BARRIER_DIR="$VALIDATION_BARRIER" \
  bash "$RESOLVER" 1 > "$TMP/runtime-validation.out" 2>&1 & VALIDATION_PID=$!
i=0; while [ ! -e "$VALIDATION_BARRIER/runtime-validation.reached" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i+1)); done
if [ -e "$VALIDATION_BARRIER/runtime-validation.reached" ]; then
  printf '{"schemaVersion":1,"pid":%s,"token":"%s","createdAt":"2026-01-01T00:00:00.000Z"}\n' \
    "$LIVE_PID" "$(printf 'b%.0s' {1..64})" > "$HOME/.zensu-kiro-install.lock"
  : > "$VALIDATION_BARRIER/runtime-validation.release"
  wait "$VALIDATION_PID"; VALIDATION_RC=$?
  rm -f "$HOME/.zensu-kiro-install.lock"
  if [ "$VALIDATION_RC" -ne 0 ]; then
    ok "K7b resolver detects an installer entering during validation"
  else
    bad "K7b resolver returned a root across a concurrent install transaction"
  fi
else
  bad "K7b runtime validation barrier was not reached"
  kill "$VALIDATION_PID" 2>/dev/null || true
fi

# Files removed from a new runtime inventory are reconciled from the prior
# manifest instead of remaining as unrecorded hooks that brick validation.
OBSOLETE="$RUNTIME/hooks/obsolete-runtime.sh"
printf '#!/bin/bash\necho obsolete\n' > "$OBSOLETE"; chmod 755 "$OBSOLETE"
MANIFEST="$RUNTIME/manifest.json" OBSOLETE="$OBSOLETE" node - <<'NODE'
const fs=require("fs"),crypto=require("crypto"),p=process.env.MANIFEST;
const m=JSON.parse(fs.readFileSync(p));
m.files[process.env.OBSOLETE]=crypto.createHash("sha256").update(fs.readFileSync(process.env.OBSOLETE)).digest("hex");
fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
NODE
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ ! -e "$OBSOLETE" ] && \
   [ "$(env HOME="$HOME" bash "$RUNTIME/hooks/lib/resolve-plugin-root.sh" 1 2>/dev/null)" = "$RUNTIME" ]; then
  ok "K7c upgrade removes obsolete unmodified runtime files transactionally"
else
  bad "K7c obsolete managed runtime file survived upgrade (rc=$RC)"
  rm -f "$OBSOLETE"
  bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1 || true
fi

printf '#!/bin/bash\necho managed-old\n' > "$OBSOLETE"; chmod 755 "$OBSOLETE"
MANIFEST="$RUNTIME/manifest.json" OBSOLETE="$OBSOLETE" node - <<'NODE'
const fs=require("fs"),crypto=require("crypto"),p=process.env.MANIFEST;
const m=JSON.parse(fs.readFileSync(p));
m.files[process.env.OBSOLETE]=crypto.createHash("sha256").update(fs.readFileSync(process.env.OBSOLETE)).digest("hex");
fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
NODE
printf '#!/bin/bash\necho user-modified\n' > "$OBSOLETE"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && grep -q 'obsolete runtime is user-modified' <<< "$OUT" && \
   grep -q 'user-modified' "$OBSOLETE"; then
  ok "K7d upgrade preserves modified obsolete runtime with actionable repair error"
else
  bad "K7d modified obsolete runtime was removed or lacked actionable guidance"
fi
bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1

MANIFEST="$RUNTIME/manifest.json"
MANIFEST="$MANIFEST" node -e 'const fs=require("fs");const p=process.env.MANIFEST;const m=JSON.parse(fs.readFileSync(p));m.version="9.0.0";fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");'
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qi 'downgrade'; then
  ok "K8 installer refuses an older checkout over a newer runtime"
else
  bad "K8 unsafe downgrade was not refused (rc=$RC)"
fi

if bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1; then
  ok "K9 --force explicitly permits replacing the newer runtime"
else
  bad "K9 --force could not override downgrade guard"
fi

WS="$TMP/workspace with space"
( cd "$WS" && bash "$INSTALL" --scope workspace --no-default >/dev/null 2>&1 )
if [ -f "$WS/.kiro/zensu-manifest.json" ] && [ "$(cat "$HOME/.zensu/plugin-root")" = '/tmp/legacy-pointer-must-survive' ]; then
  ok "K10 workspace install shares fixed runtime without creating a locator"
else
  bad "K10 workspace install contract failed"
fi
if [ "$(env HOME="$HOME" bash "$RESOLVER" 1 2>/dev/null)" = "$RUNTIME" ]; then
  ok "K10b workspace install leaves the fixed user resolver authoritative"
else
  bad "K10b workspace install changed fixed-root resolution"
fi
WS_AGENT="$WS/.kiro/agents/zensu.json"
if AGENT="$WS_AGENT" RUNTIME="$RUNTIME" node - <<'NODE'
const j=JSON.parse(require("fs").readFileSync(process.env.AGENT,"utf8"));
const hooks=Object.values(j.hooks||{}).flat();
const prefix=`bash "${process.env.RUNTIME}/hooks/kiro/kiro-shim.sh" 1 `;
if (!hooks.length || !hooks.every(h=>typeof h.command==="string" && h.command.startsWith(prefix))) process.exit(1);
NODE
then
  ok "K10c workspace agents still target the fixed user runtime"
else
  bad "K10c workspace agents target workspace or locator state"
fi

if ROOT="$ROOT" node - <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.env.ROOT;
const targets = ["install.sh", "hooks", "skills", "agents", "steering", "docs", "README.md", "POWER.md"];
const hits = [];
function scan(p) {
  const st = fs.statSync(p);
  if (st.isDirectory()) { for (const name of fs.readdirSync(p)) scan(path.join(p, name)); return; }
  if (!/\.(?:sh|js|json|md)$/.test(p)) return;
  if (fs.readFileSync(p, "utf8").includes(".zensu/plugin-root")) hits.push(path.relative(root, p));
}
for (const rel of targets) { const p=path.join(root,rel); if (fs.existsSync(p)) scan(p); }
for (const rel of ["skills", "agents", "steering", "docs"]) {
  const base = path.join(root, rel);
  const scanCommands = p => {
    const st = fs.statSync(p);
    if (st.isDirectory()) { for (const name of fs.readdirSync(p)) scanCommands(path.join(p, name)); return; }
    if (!/\.(?:md|json|yaml)$/.test(p)) return;
    const text = fs.readFileSync(p, "utf8");
    if (/\{PLUGIN_ROOT\}|CLAUDE_PLUGIN_ROOT|CODEX_PLUGIN_ROOT/.test(text)) hits.push(`${path.relative(root,p)}:unsafe-model-root`);
    if (p.endsWith(".md")) {
      for (const match of text.matchAll(/```(?:bash|sh)\s*\n([\s\S]*?)```/g)) {
        const block=match[1];
        if (/\$(?:ROOT|PLUGIN_ROOT|ZENSU_KIRO_ROOT)\b|\$\{(?:ROOT|PLUGIN_ROOT|ZENSU_KIRO_ROOT)\b/.test(block) &&
            !/resolve-plugin-root\.sh\" 1/.test(block)) hits.push(`${path.relative(root,p)}:shell-block-reuses-root`);
      }
    }
  };
  if (fs.existsSync(base)) scanCommands(base);
}
for (const rel of ["hooks/session-start-primer.sh", "hooks/post-review-tdd-delegate.sh", "hooks/stop-chain-enforcer.sh", "hooks/pre-edit-tdd-reminder.sh"]) {
  const text = fs.readFileSync(path.join(root, rel), "utf8");
  if (/\{PLUGIN_ROOT\}|root\s*\+\s*["\x27]\/hooks\/|bash\s+\$\{?CLAUDE_PLUGIN_ROOT/.test(text)) hits.push(`${rel}:unsafe-generated-root`);
}
if (hits.length) { process.stderr.write(`active legacy plugin-root references: ${hits.join(", ")}\n`); process.exit(1); }
NODE
then
  ok "K11 active installer, hooks, skills, agents, steering, and docs contain no legacy pointer consumer"
else
  bad "K11 active surfaces still reference the legacy pointer"
fi

if ROOT="$ROOT" node - <<'NODE'
const fs=require("fs"), path=require("path"), root=process.env.ROOT;
const provider=fs.readFileSync(path.join(root,"tests/promptfoo/providers/kiro-cli.mjs"),"utf8");
const assertion=fs.readFileSync(path.join(root,"tests/promptfoo/asserts/fixed-runtime.mjs"),"utf8");
if (!provider.includes("fixed-runtime-closure.mjs") || !assertion.includes("fixed-runtime-closure.mjs")) process.exit(1);
const shared=fs.readFileSync(path.join(root,"tests/promptfoo/fixed-runtime-closure.mjs"),"utf8");
if (!shared.includes("runtime-files.txt")) process.exit(2);
NODE
then
  ok "K11b promptfoo provider and assertion share the declarative runtime closure"
else
  bad "K11b promptfoo runtime artifacts drift from the resolver inventory"
fi

# Critical integrity checks are independent: the resolver must reject its own
# changed bytes, a VERSION hash mismatch, invalid manifest JSON, and symlinked
# critical files. Each case is repaired in isolation by the installer.
printf '\n# self tamper\n' >> "$RESOLVER"
if env HOME="$HOME" bash "$RESOLVER" 1 >/dev/null 2>&1; then
  bad "K12 resolver accepted its own manifest hash mismatch"
else
  ok "K12 resolver rejects its own manifest hash mismatch"
fi
bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1
RESOLVER="$RUNTIME/hooks/lib/resolve-plugin-root.sh"

printf '0.2.0+tampered\n' > "$RUNTIME/VERSION"
if env HOME="$HOME" bash "$RESOLVER" 1 >/dev/null 2>&1; then
  bad "K13 resolver accepted a VERSION hash/version mismatch"
else
  ok "K13 resolver rejects VERSION hash/version mismatch"
fi
bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1

# A manifest key must use canonical path spelling. An alias that normalizes
# from the runtime tree into the agents tree must fail before reconciliation;
# otherwise raw shell classification could delete the real agent as an
# "obsolete runtime" file.
ALIAS_MANIFEST="$TMP/manifest-before-alias.json"
cp "$RUNTIME/manifest.json" "$ALIAS_MANIFEST"
ALIAS_AGENT="$HOME/.kiro/agents/zensu.json"
ALIAS_KEY="$RUNTIME/../agents/zensu.json"
MANIFEST="$RUNTIME/manifest.json" AGENT="$ALIAS_AGENT" ALIAS_KEY="$ALIAS_KEY" node - <<'NODE'
const fs=require("fs"),p=process.env.MANIFEST;
const m=JSON.parse(fs.readFileSync(p,"utf8"));
const hash=m.files[process.env.AGENT];
if (!hash) process.exit(1);
delete m.files[process.env.AGENT];
m.files[process.env.ALIAS_KEY]=hash;
fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
NODE
ALIAS_MANIFEST_BYTES="$(cat "$RUNTIME/manifest.json")"
OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && [ -f "$ALIAS_AGENT" ] && \
   [ "$(cat "$RUNTIME/manifest.json")" = "$ALIAS_MANIFEST_BYTES" ] && \
   printf '%s' "$OUT" | grep -q 'manifest path is not canonical'; then
  ok "K13b non-canonical manifest aliases fail before runtime reconciliation"
else
  bad "K13b aliased manifest provenance deleted or republished a canonical agent"
fi
cp "$ALIAS_MANIFEST" "$RUNTIME/manifest.json"

# Standard macOS volumes are case-insensitive even though Bash patterns are
# case-sensitive. If an uppercase alias resolves to the real lowercase hook,
# preflight must reject that spelling before obsolete-runtime reconciliation.
CASE_HOOK="$RUNTIME/hooks/lib/zensu-log.sh"
CASE_ALIAS="$RUNTIME/HOOKS/lib/zensu-log.sh"
if [ -e "$CASE_ALIAS" ]; then
  CASE_MANIFEST="$TMP/manifest-before-case-alias.json"
  cp "$RUNTIME/manifest.json" "$CASE_MANIFEST"
  MANIFEST="$RUNTIME/manifest.json" HOOK="$CASE_HOOK" ALIAS_KEY="$CASE_ALIAS" node - <<'NODE'
const fs=require("fs"),p=process.env.MANIFEST;
const m=JSON.parse(fs.readFileSync(p,"utf8"));
const hash=m.files[process.env.HOOK];
if (!hash) process.exit(1);
delete m.files[process.env.HOOK];
m.files[process.env.ALIAS_KEY]=hash;
fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
NODE
  CASE_MANIFEST_BYTES="$(cat "$RUNTIME/manifest.json")"
  OUT="$(bash "$INSTALL" --scope user --no-default 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && [ -f "$CASE_HOOK" ] && \
     [ "$(cat "$RUNTIME/manifest.json")" = "$CASE_MANIFEST_BYTES" ] && \
     printf '%s' "$OUT" | grep -q 'manifest path does not match filesystem spelling'; then
    ok "K13c case-insensitive manifest aliases fail before runtime reconciliation"
  else
    bad "K13c case alias deleted or republished the canonical runtime hook"
  fi
  cp "$CASE_MANIFEST" "$RUNTIME/manifest.json"
else
  ok "K13c skipped: filesystem is case-sensitive (case alias cannot target canonical hook)"
fi

printf '{not-json\n' > "$RUNTIME/manifest.json"
if env HOME="$HOME" bash "$RESOLVER" 1 >/dev/null 2>&1; then
  bad "K14 resolver accepted malformed manifest JSON"
else
  ok "K14 resolver rejects malformed manifest JSON"
fi
MALFORMED_MANIFEST="$(cat "$RUNTIME/manifest.json")"
MALFORMED_OBSOLETE="$RUNTIME/hooks/unrecorded-before-force.sh"
printf '#!/bin/bash\necho stale\n' > "$MALFORMED_OBSOLETE"
OUT="$(bash "$INSTALL" --scope user --no-default --force 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && [ "$(cat "$RUNTIME/manifest.json")" = "$MALFORMED_MANIFEST" ] && \
   [ -f "$MALFORMED_OBSOLETE" ] && printf '%s' "$OUT" | grep -q 'invalid manifest'; then
  ok "K14b --force cannot publish over malformed inventory provenance"
else
  bad "K14b --force replaced malformed provenance or partially reconciled unknown hooks"
fi
rm -f "$MALFORMED_OBSOLETE" "$RUNTIME/manifest.json"
bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1

ZLOG="$RUNTIME/hooks/lib/zensu-log.sh"; ZLOG_REAL="$TMP/zensu-log-real.sh"
cp "$ZLOG" "$ZLOG_REAL"; rm "$ZLOG"
if ln -s "$ZLOG_REAL" "$ZLOG" 2>/dev/null; then
  if env HOME="$HOME" bash "$RESOLVER" 1 >/dev/null 2>&1; then
    bad "K15 resolver accepted a symlinked critical helper"
  else
    ok "K15 resolver rejects a symlinked critical helper"
  fi
else
  ok "K15 skipped: filesystem does not permit symlink fixture"
fi
rm -f "$ZLOG"
bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1
if [ "$(env HOME="$HOME" bash "$RUNTIME/hooks/lib/resolve-plugin-root.sh" 1 2>/dev/null)" = "$RUNTIME" ]; then
  ok "K16 isolated repairs restore a valid runtime"
else
  bad "K16 repair after negative integrity cases failed"
fi

# Every sourced/executed dependency of zensu-log is part of the integrity
# closure, not just the top-level logging script.
for rel in hooks/lib/zensu-config.sh hooks/lib/zensu-session.sh hooks/lib/zensu-tdd-phase.sh hooks/lib/resolve-session-id.js; do
  printf '\n# transitive tamper\n' >> "$RUNTIME/$rel"
  if env HOME="$HOME" bash "$RUNTIME/hooks/lib/resolve-plugin-root.sh" 1 >/dev/null 2>&1; then
    bad "K17 resolver accepted tampered transitive dependency $rel"
  else
    ok "K17 resolver rejects tampered transitive dependency $rel"
  fi
  bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1
done

printf '# unrecorded executable\n' > "$RUNTIME/hooks/lib/unrecorded-runtime.sh"
if env HOME="$HOME" bash "$RUNTIME/hooks/lib/resolve-plugin-root.sh" 1 >/dev/null 2>&1; then
  bad "K18 resolver accepted an unrecorded runtime hook"
else
  ok "K18 resolver rejects an unrecorded runtime hook"
fi
rm -f "$RUNTIME/hooks/lib/unrecorded-runtime.sh"

rm -f "$RUNTIME/hooks/lib/zensu-config.sh"
MANIFEST="$RUNTIME/manifest.json" node -e '
  const fs=require("fs"),p=process.env.MANIFEST,m=JSON.parse(fs.readFileSync(p,"utf8"));
  for (const key of Object.keys(m.files)) if (key.endsWith("/hooks/lib/zensu-config.sh")) delete m.files[key];
  fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
'
if env HOME="$HOME" bash "$RUNTIME/hooks/lib/resolve-plugin-root.sh" 1 >/dev/null 2>&1; then
  bad "K19 resolver accepted a removed dependency plus removed manifest entry"
else
  ok "K19 hard-coded integrity closure fails closed when file and record vanish"
fi
bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1

rm -f "$RUNTIME/hooks/session-start-banner.sh"
MANIFEST="$RUNTIME/manifest.json" node -e '
  const fs=require("fs"),p=process.env.MANIFEST,m=JSON.parse(fs.readFileSync(p,"utf8"));
  for (const key of Object.keys(m.files)) if (key.endsWith("/hooks/session-start-banner.sh")) delete m.files[key];
  fs.writeFileSync(p,JSON.stringify(m,null,2)+"\n");
'
if env HOME="$HOME" bash "$RUNTIME/hooks/lib/resolve-plugin-root.sh" 1 >/dev/null 2>&1; then
  bad "K20 resolver accepted a removed non-library hook plus removed manifest entry"
else
  ok "K20 complete expected-runtime closure catches removed hook and record"
fi
bash "$INSTALL" --scope user --no-default --force >/dev/null 2>&1

printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
