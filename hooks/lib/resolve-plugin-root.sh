#!/bin/bash
# Resolve Kiro's deliberately fixed Zensu runtime and fail closed when the
# installed VERSION/protocol/manifest or complete runtime closure no longer agree.
set -u

ROOT="$HOME/.kiro/zensu"
[ "$#" -eq 1 ] && [ -n "$1" ] || {
  echo "FATAL: a scope protocol version is required to validate the Zensu Kiro runtime" >&2
  exit 1
}
EXPECTED_PROTOCOL="$1"
command -v node >/dev/null 2>&1 || {
  echo "FATAL: node is required to validate the Zensu Kiro runtime" >&2
  exit 1
}
configure_windows_native_tools() {
  case "${OSTYPE:-}" in
    msys*|cygwin*)
      case "${BASH:-}" in /*) ;; *) return 1 ;; esac
      # Keep logical anchors raw in native Node while retaining normal MSYS
      # argv conversion for script/executable paths.
      local raw_name
      if [ "${MSYS2_ENV_CONV_EXCL:-}" != "*" ]; then
        for raw_name in ZENSU_KIRO_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_RAW ZENSU_KIRO_WORKSPACE_ANCHOR_RAW ZENSU_KIRO_TEST_ANCHOR_RAW ZENSU_KIRO_ROOT ZENSU_KIRO_RENDER_HOME_RAW; do
          case ";${MSYS2_ENV_CONV_EXCL:-};" in
            *";$raw_name;"*) ;;
            *) MSYS2_ENV_CONV_EXCL="${MSYS2_ENV_CONV_EXCL:+${MSYS2_ENV_CONV_EXCL};}$raw_name" ;;
          esac
        done
      fi
      export MSYS2_ENV_CONV_EXCL
      local cygpath_posix="${BASH%/*}/cygpath.exe"
      local bash_posix="$BASH"
      case "$bash_posix" in *.exe) ;; *) [ -x "${bash_posix}.exe" ] && bash_posix="${bash_posix}.exe" ;; esac
      [ -x "$cygpath_posix" ] || return 1
      ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE="$("$cygpath_posix" -m "$cygpath_posix" 2>/dev/null)" || return 1
      ZENSU_KIRO_TRUSTED_BASH_NATIVE="$("$cygpath_posix" -m "$bash_posix" 2>/dev/null)" || return 1
      case "$ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE$ZENSU_KIRO_TRUSTED_BASH_NATIVE" in *[$'\r\n\t']*|'') return 1 ;; esac
      export ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE ZENSU_KIRO_TRUSTED_BASH_NATIVE
      ;;
  esac
}
configure_windows_native_tools || {
  echo "FATAL: trusted Git Bash path tools are unavailable" >&2
  exit 1
}
NATIVE_ANCHOR_HELPER="$ROOT/hooks/lib/resolve-native-anchor.js"
[ -f "$NATIVE_ANCHOR_HELPER" ] || { echo "FATAL: native anchor resolver is missing" >&2; exit 1; }
ZENSU_KIRO_HOME_ANCHOR_RAW="${HOME:-}"
ZENSU_KIRO_HOME_ANCHOR_NATIVE="$(ZENSU_KIRO_ANCHOR_RAW="$ZENSU_KIRO_HOME_ANCHOR_RAW" node "$NATIVE_ANCHOR_HELPER" 2>/dev/null)" || {
  echo "FATAL: HOME native anchor resolution failed" >&2; exit 1;
}
export ZENSU_KIRO_HOME_ANCHOR_RAW ZENSU_KIRO_HOME_ANCHOR_NATIVE

ZENSU_KIRO_ROOT="$ROOT" ZENSU_KIRO_EXPECTED_PROTOCOL="$EXPECTED_PROTOCOL" node <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const root = process.env.ZENSU_KIRO_ROOT || "";
const fail = message => { process.stderr.write(`FATAL: invalid Zensu Kiro runtime — ${message}\n`); process.exit(1); };
const fold = value => process.platform === "win32" ? value.toLowerCase() : value;
const analyzePath = (value, label) => {
  if (typeof value !== "string" || !value || /[\0\r\n\t]/.test(value)) fail(`${label} is unavailable or unsafe`);
  if (process.platform === "win32" && value.startsWith("/") && !value.startsWith("//")) {
    if (!path.posix.isAbsolute(value)) fail(`${label} is not absolute`);
    if (value.includes("\\")) fail(`${label} contains a Windows separator in MSYS syntax`);
    const components = value === "/" ? [] : value.split("/").slice(1);
    if (components.some(component => !component || component === "." || component === ".." ||
        component.includes(":") || /[. ]$/.test(component))) {
      fail(`${label} contains a non-canonical or Windows-aliased component`);
    }
    return { api: path.posix, kind: "msys", value: path.posix.resolve(value) };
  }
  const api = process.platform === "win32" ? path.win32 : path;
  if (!api.isAbsolute(value)) fail(`${label} is not absolute`);
  if (process.platform === "win32") {
    const parsedRoot = path.win32.parse(value).root;
    const remainder = value.slice(parsedRoot.length);
    const components = remainder ? remainder.split(/[\\/]/) : [];
    if (components.some(component => !component || component === "." || component === ".." ||
        component.includes(":") || /[. ]$/.test(component))) {
      fail(`${label} contains a non-canonical or Windows-aliased component`);
    }
  }
  return { api, kind: "native", value: api.resolve(value) };
};
const relativeWithin = (parent, child) => {
  if (parent.kind !== child.kind) return null;
  const relative = parent.api.relative(parent.value, child.value);
  if (relative === "") return "";
  if (relative === ".." || relative.startsWith(`..${parent.api.sep}`) || parent.api.isAbsolute(relative)) return null;
  return relative;
};
const safeParts = (relative, source, label) => {
  if (!relative) return [];
  const parts = relative.split(source.api.sep);
  if (parts.some(part => !part || part === "." || part === ".." ||
      (process.platform === "win32" && (part.includes("\\") || part.includes(":") || /[. ]$/.test(part))))) {
    fail(`${label} contains an unsafe relative component`);
  }
  return parts;
};
const mappingSpecs = [
  ["ZENSU_KIRO_HOME_ANCHOR_RAW", "ZENSU_KIRO_HOME_ANCHOR_NATIVE"],
  ...(process.env.NODE_ENV === "test" ? [["ZENSU_KIRO_TEST_ANCHOR_RAW", "ZENSU_KIRO_TEST_ANCHOR_NATIVE"]] : [])
];
const mappings = mappingSpecs.flatMap(([rawName, nativeName]) => {
  const raw = process.env[rawName] || "";
  const native = process.env[nativeName] || "";
  if (!raw && !native) return [];
  if (!raw || !native) fail("trusted anchor mapping is incomplete");
  const rawPath = analyzePath(raw, "raw trusted anchor");
  const nativePath = analyzePath(native, "native trusted anchor");
  if (process.platform === "win32" && nativePath.kind !== "native") fail("native trusted anchor is not native Windows syntax");
  let stat;
  try { stat = fs.statSync(nativePath.value); } catch (_) { fail("native trusted anchor is missing"); }
  if (!stat.isDirectory()) fail("native trusted anchor is not a directory");
  const realNative = fs.realpathSync(nativePath.value);
  return [{ raw: rawPath, native: nativePath, physical: analyzePath(realNative, "physical trusted anchor"), realNative }];
});
const anchorCache = new Map();
const anchorContext = anchorValue => {
  const anchor = analyzePath(anchorValue, "anchor");
  const cacheKey = `${anchor.kind}:${anchor.value}`;
  if (anchorCache.has(cacheKey)) return anchorCache.get(cacheKey);
  const candidates = [];
  for (const mapping of mappings) {
    const rawRelative = relativeWithin(mapping.raw, anchor);
    if (rawRelative !== null) candidates.push({ mapping, relative: rawRelative, source: mapping.raw });
    const nativeRelative = relativeWithin(mapping.native, anchor);
    if (nativeRelative !== null) candidates.push({ mapping, relative: nativeRelative, source: mapping.native });
    const physicalRelative = relativeWithin(mapping.physical, anchor);
    if (physicalRelative !== null) candidates.push({ mapping, relative: physicalRelative, source: mapping.physical });
  }
  candidates.sort((left, right) => right.source.value.length - left.source.value.length);
  let context;
  if (candidates.length) {
    const { mapping, relative, source } = candidates[0];
    const parts = safeParts(relative, source, "anchor");
    const logicalNative = path.resolve(mapping.native.value, ...parts);
    const logicalRelative = path.relative(mapping.native.value, logicalNative);
    if (logicalRelative === ".." || logicalRelative.startsWith(`..${path.sep}`) || path.isAbsolute(logicalRelative)) {
      fail("anchor escapes its logical native mapping");
    }
    const native = path.resolve(mapping.realNative, ...parts);
    const nativeRelative = path.relative(mapping.realNative, native);
    if (nativeRelative === ".." || nativeRelative.startsWith(`..${path.sep}`) || path.isAbsolute(nativeRelative)) {
      fail("anchor escapes its native mapping");
    }
    let stat;
    try { stat = fs.statSync(native); } catch (_) { fail("anchor is missing"); }
    if (!stat.isDirectory()) fail("anchor is unsafe");
    context = {
      raw: analyzePath(mapping.raw.api.resolve(mapping.raw.value, ...parts), "raw anchor"),
      nativeLogical: analyzePath(logicalNative, "native anchor"),
      nativePhysical: analyzePath(native, "physical native anchor"),
      native: fs.realpathSync(native)
    };
  } else if (process.platform !== "win32") {
    let stat;
    try { stat = fs.statSync(anchor.value); } catch (_) { fail("anchor is missing"); }
    if (!stat.isDirectory()) fail("anchor is unsafe");
    const native = fs.realpathSync(anchor.value);
    context = { raw: anchor, nativeLogical: analyzePath(native, "native anchor"), nativePhysical: analyzePath(native, "physical native anchor"), native };
  } else {
    fail("anchor is not covered by a trusted raw/native mapping");
  }
  anchorCache.set(cacheKey, context);
  return context;
};
const deriveChild = (context, value, label) => {
  const child = analyzePath(value, label);
  let relative = relativeWithin(context.raw, child);
  let source = context.raw;
  if (relative === null) {
    relative = relativeWithin(context.nativeLogical, child);
    source = context.nativeLogical;
  }
  if (relative === null) {
    relative = relativeWithin(context.nativePhysical, child);
    source = context.nativePhysical;
  }
  if (relative === null) fail(`${label} escapes HOME`);
  const parts = safeParts(relative, source, label);
  const target = path.resolve(context.native, ...parts);
  const nativeRelative = path.relative(context.native, target);
  if (nativeRelative === ".." || nativeRelative.startsWith(`..${path.sep}`) || path.isAbsolute(nativeRelative)) {
    fail(`${label} escapes its native anchor`);
  }
  return { child, parts, target };
};
const assertCanonicalRawPath = (value, label) => {
  if (value.endsWith("/") || (process.platform === "win32" && value.endsWith("\\"))) {
    fail(`${label} has a trailing separator`);
  }
  const analyzed = analyzePath(value, label);
  if (process.platform === "win32" && analyzed.kind === "msys") {
    if (path.posix.normalize(value) !== value) fail(`${label} is not canonical`);
  } else if (process.platform === "win32") {
    const windowsSpelling = value.replace(/\//g, "\\");
    if (fold(path.win32.normalize(windowsSpelling)) !== fold(windowsSpelling)) fail(`${label} is not canonical`);
  } else if (analyzed.value !== value) {
    fail(`${label} is not canonical`);
  }
  return analyzed;
};
const assertExactSpelling = (context, derived, label) => {
  let cursor = context.native;
  for (const part of derived.parts) {
    let names;
    try { names = fs.readdirSync(cursor); } catch (_) { fail(`${label} parent is unreadable`); }
    if (!names.includes(part)) {
      // Missing non-runtime manifest targets are tolerated just as before; a
      // differently cased alias on a case-insensitive volume is not.
      if (fs.existsSync(path.join(cursor, part))) fail(`${label} does not match filesystem spelling`);
      break;
    }
    cursor = path.join(cursor, part);
  }
};
const keyPath = rel => root.replace(/[\\/]+$/, "") + "/" + rel;
const regular = (file, label, max) => {
  let st;
  try { st = fs.lstatSync(file); } catch (_) { fail(`${label} is missing`); }
  if (st.isSymbolicLink() || !st.isFile() || st.size <= 0 || st.size > max) fail(`${label} is not a bounded regular file`);
  return st;
};
const hash = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");

if (!root || /[\0\r\n]/.test(root)) fail("fixed root is unavailable or unsafe");
const home = process.env.ZENSU_KIRO_HOME_ANCHOR_RAW || "";
if (!home || /[\0\r\n]/.test(home)) fail("HOME is unavailable or unsafe");
const homeContext = anchorContext(home);
const canonicalHome = homeContext.native;
const rootDerived = deriveChild(homeContext, root, "fixed root");
if (rootDerived.parts.length !== 2 || rootDerived.parts[0] !== ".kiro" || rootDerived.parts[1] !== "zensu") {
  fail("fixed root is not HOME/.kiro/zensu");
}
let cursor = canonicalHome;
const installLock = path.join(canonicalHome, ".zensu-kiro-install.lock");
const recoveryLock = `${installLock}.recovery`;
const recoveryClaimPrefix = `${path.basename(recoveryLock)}.reclaim.`;
const expectedLockPid = Number(process.env.ZENSU_KIRO_LOCK_OWNER_PID || "");
const expectedLockToken = process.env.ZENSU_KIRO_LOCK_TOKEN || "";
const assertInstallStable = () => {
  let recoveryClaims;
  try { recoveryClaims = fs.readdirSync(canonicalHome).filter(name => name.startsWith(recoveryClaimPrefix)); }
  catch (_) { fail("cannot inspect install recovery claims"); }
  if (recoveryClaims.length) fail("installation recovery claim is in progress or incomplete");
  let recoveryStat = null;
  try { recoveryStat = fs.lstatSync(recoveryLock); } catch (error) { if (!error || error.code !== "ENOENT") fail("cannot inspect install recovery lock"); }
  if (recoveryStat) fail("installation recovery is in progress or incomplete");
  let stat;
  try { stat = fs.lstatSync(installLock); }
  catch (error) { if (error && error.code === "ENOENT") return; fail("cannot inspect install lock"); }
  if (stat.isSymbolicLink() || !stat.isFile() || stat.size <= 0 || stat.size > 4096) fail("install lock is unsafe");
  let owner;
  try { owner = JSON.parse(fs.readFileSync(installLock, "utf8")); } catch (_) { fail("install lock metadata is invalid"); }
  if (!owner || owner.schemaVersion !== 1 || owner.pid !== expectedLockPid || owner.token !== expectedLockToken ||
      !Number.isSafeInteger(owner.pid) || owner.pid <= 0 || !/^[a-f0-9]{64}$/.test(owner.token || "")) {
    fail("installation is in progress or incomplete");
  }
};
assertInstallStable();
for (const component of [".kiro", "zensu"]) {
  let names;
  try { names = fs.readdirSync(cursor); } catch (_) { fail(`${component} runtime parent is unreadable`); }
  if (!names.includes(component)) fail(`${component} runtime component does not match filesystem spelling`);
  cursor = path.join(cursor, component);
  let stat;
  try { stat = fs.lstatSync(cursor); } catch (_) { fail(`${component} runtime component is missing`); }
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`${component} runtime component is not a real directory`);
}
const canonicalRoot = fs.realpathSync(cursor);
const fsPath = rel => path.join(canonicalRoot, ...rel.split("/"));

regular(fsPath("VERSION"), "VERSION", 1024);
regular(fsPath("PROTOCOL_VERSION"), "PROTOCOL_VERSION", 1024);
regular(fsPath("manifest.json"), "manifest", 1024 * 1024);
const manifestBytes = fs.readFileSync(fsPath("manifest.json"));
let manifest;
try { manifest = JSON.parse(manifestBytes.toString("utf8")); }
catch (_) { fail("manifest is invalid JSON"); }
if (!manifest || Array.isArray(manifest) || typeof manifest.version !== "string" ||
    !manifest.files || Array.isArray(manifest.files) || typeof manifest.files !== "object") {
  fail("manifest schema is invalid");
}
const version = fs.readFileSync(fsPath("VERSION"), "utf8").trim();
const versionMatch = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.exec(version);
const invalidPrerelease = versionMatch && versionMatch[4] && versionMatch[4].split(".").some(id => /^\d+$/.test(id) && id.length > 1 && id.startsWith("0"));
if (!versionMatch || invalidPrerelease || manifest.version !== version) {
  fail("VERSION and manifest version disagree");
}
const protocol = fs.readFileSync(fsPath("PROTOCOL_VERSION"), "utf8").trim();
const expectedProtocol = process.env.ZENSU_KIRO_EXPECTED_PROTOCOL || "";
if (!/^[1-9][0-9]*$/.test(protocol) || expectedProtocol !== protocol) {
  fail("scope/runtime protocol versions are incompatible; reinstall this scope");
}

const canonicalKey = value => {
  const derived = deriveChild(homeContext, value, "manifest path");
  assertExactSpelling(homeContext, derived, "manifest path");
  return fold(derived.target);
};
const manifestHashes = new Map();
for (const [key, value] of Object.entries(manifest.files)) {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) fail("manifest contains an invalid file hash");
  assertCanonicalRawPath(key, "manifest path");
  const canonical = canonicalKey(key);
  if (manifestHashes.has(canonical)) fail("manifest contains duplicate canonical paths");
  manifestHashes.set(canonical, value);
}
const recordedHash = key => manifestHashes.get(canonicalKey(key));
const expectedRuntime = /* zensu-runtime-inventory:start */ [
  "VERSION",
  "PROTOCOL_VERSION",
  "hooks/kiro/kiro-shim.sh",
  "hooks/lib/resolve-plugin-root.sh",
  "hooks/lib/resolve-native-anchor.js",
  "hooks/lib/capture-native-shell-pid.sh",
  "hooks/lib/kiro-runtime-lock.js",
  "hooks/lib/resolve-session-id.js",
  "hooks/lib/zensu-cli-map.sh",
  "hooks/lib/zensu-config.sh",
  "hooks/lib/zensu-log.sh",
  "hooks/lib/zensu-mcp-tools.sh",
  "hooks/lib/zensu-runtime.sh",
  "hooks/lib/zensu-session.sh",
  "hooks/lib/zensu-tdd-phase.sh",
  "hooks/post-bash-witness.sh",
  "hooks/post-review-tdd-delegate.sh",
  "hooks/pre-bash-zensu-gate.sh",
  "hooks/pre-edit-tdd-reminder.sh",
  "hooks/session-start-banner.sh",
  "hooks/session-start-capture-sid.sh",
  "hooks/session-start-primer.sh",
  "hooks/session-start-pulse.sh",
  "hooks/stop-chain-enforcer.sh",
  "hooks/user-prompt-context-nudge.sh",
  "hooks/user-prompt-intent-router.sh",
  "hooks/user-prompt-tdd-reminder.sh"
] /* zensu-runtime-inventory:end */;
for (const rel of expectedRuntime) {
  const key = keyPath(rel);
  const file = fsPath(rel);
  regular(file, rel, 1024 * 1024);
  const recorded = recordedHash(key);
  if (typeof recorded !== "string" || !/^[a-f0-9]{64}$/.test(recorded)) fail(`${rel} has no valid manifest hash`);
  if (hash(file) !== recorded) fail(`${rel} hash mismatch`);
}

let hookCount = 0;
let hookBytes = 0;
const verifyHookTree = directory => {
  const dirStat = fs.lstatSync(directory);
  if (dirStat.isSymbolicLink() || !dirStat.isDirectory()) fail("hooks tree contains an unsafe directory");
  for (const name of fs.readdirSync(directory)) {
    const file = path.join(directory, name);
    const stat = fs.lstatSync(file);
    if (stat.isSymbolicLink()) fail("hooks tree contains a symlink");
    if (stat.isDirectory()) { verifyHookTree(file); continue; }
    if (!stat.isFile() || stat.size <= 0 || stat.size > 2 * 1024 * 1024) fail("hooks tree contains an invalid file");
    hookCount += 1;
    hookBytes += stat.size;
    if (hookCount > 512 || hookBytes > 16 * 1024 * 1024) fail("hooks tree exceeds integrity bounds");
    const rel = path.relative(canonicalRoot, file).split(path.sep).join("/");
    const recorded = recordedHash(keyPath(rel));
    if (!recorded) fail(`${rel} is not recorded in the manifest`);
    if (hash(file) !== recorded) fail(`${rel} hash mismatch`);
  }
};
verifyHookTree(fsPath("hooks"));

// A model-side resolver does not hold the writer lock after returning, so take
// a second complete snapshot and require the manifest and lock state to remain
// unchanged. The automatic shim additionally holds this same lock through
// wrapped-hook execution.
const testBarrier = name => {
  if (process.env.NODE_ENV !== "test" || !process.env.ZENSU_KIRO_TEST_BARRIER_DIR) return;
  const directory = anchorContext(process.env.ZENSU_KIRO_TEST_BARRIER_DIR).native;
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail("test barrier directory is unsafe");
  const reached = path.join(directory, `${name}.reached`);
  const release = path.join(directory, `${name}.release`);
  if (!fs.existsSync(reached)) fs.writeFileSync(reached, "reached\n", { flag: "wx", mode: 0o600 });
  const deadline = Date.now() + 15000;
  const waitArray = new Int32Array(new SharedArrayBuffer(4));
  while (!fs.existsSync(release)) {
    if (Date.now() >= deadline) fail(`test barrier timed out: ${name}`);
    Atomics.wait(waitArray, 0, 0, 20);
  }
};
testBarrier("runtime-validation");
assertInstallStable();
if (!fs.readFileSync(fsPath("manifest.json")).equals(manifestBytes)) fail("manifest changed during validation");
for (const rel of expectedRuntime) {
  const file = fsPath(rel);
  regular(file, rel, 1024 * 1024);
  if (hash(file) !== recordedHash(keyPath(rel))) fail(`${rel} changed during validation`);
}
hookCount = 0;
hookBytes = 0;
verifyHookTree(fsPath("hooks"));
assertInstallStable();
if (!fs.readFileSync(fsPath("manifest.json")).equals(manifestBytes)) fail("manifest changed during validation");

process.stdout.write(root);
NODE
