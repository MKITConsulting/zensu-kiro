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

ZENSU_KIRO_ROOT="$ROOT" ZENSU_KIRO_EXPECTED_PROTOCOL="$EXPECTED_PROTOCOL" node <<'NODE'
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const root = process.env.ZENSU_KIRO_ROOT || "";
const norm = p => process.platform === "win32"
  ? p.replace(/^\/([A-Za-z])(\/|$)/, (m, d, s) => d.toUpperCase() + ":" + (s || ""))
  : p;
const keyPath = rel => root.replace(/[\\/]+$/, "") + "/" + rel;
const fsPath = rel => norm(keyPath(rel));
const fail = message => { process.stderr.write(`FATAL: invalid Zensu Kiro runtime — ${message}\n`); process.exit(1); };
const regular = (file, label, max) => {
  let st;
  try { st = fs.lstatSync(file); } catch (_) { fail(`${label} is missing`); }
  if (st.isSymbolicLink() || !st.isFile() || st.size <= 0 || st.size > max) fail(`${label} is not a bounded regular file`);
  return st;
};
const hash = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");

if (!root || /[\0\r\n]/.test(root)) fail("fixed root is unavailable or unsafe");
const home = process.env.HOME || "";
if (!home || /[\0\r\n]/.test(home)) fail("HOME is unavailable or unsafe");
let cursor;
try { cursor = fs.realpathSync(norm(home)); } catch (_) { fail("HOME is missing"); }
const canonicalHome = cursor;
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
  cursor = path.join(cursor, component);
  let stat;
  try { stat = fs.lstatSync(cursor); } catch (_) { fail(`${component} runtime component is missing`); }
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`${component} runtime component is not a real directory`);
}
let canonicalRoot;
try { canonicalRoot = fs.realpathSync(norm(root)); } catch (_) { fail("fixed root is missing"); }
const samePath = process.platform === "win32"
  ? canonicalRoot.toLowerCase() === cursor.toLowerCase()
  : canonicalRoot === cursor;
if (!samePath) fail("fixed root escaped HOME through a symlink component");

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
  const resolved = path.resolve(norm(value));
  return process.platform === "win32" ? resolved.toLowerCase() : resolved;
};
const manifestHashes = new Map();
for (const [key, value] of Object.entries(manifest.files)) {
  if (typeof value !== "string" || !/^[a-f0-9]{64}$/.test(value)) fail("manifest contains an invalid file hash");
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
    const rel = path.relative(norm(root), file).split(path.sep).join("/");
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
  const directory = path.resolve(process.env.ZENSU_KIRO_TEST_BARRIER_DIR);
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
