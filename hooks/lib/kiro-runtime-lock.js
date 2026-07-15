#!/usr/bin/env node
"use strict";

// Shared writer/dispatcher lock for the fixed Kiro runtime. Recovery-guard
// reclamation uses unique, self-describing election claims; the canonical
// recovery guard is never renamed, so readers never observe an artificial gap.
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const RECOVERY_CLAIM_QUIET_MS = 50;
const MAX_RECOVERY_CLAIMS = 128;

class RuntimeLockError extends Error {
  constructor(message, exitCode = 3) { super(message); this.exitCode = exitCode; }
}
const fail = (message, exitCode = 3) => { throw new RuntimeLockError(message, exitCode); };
const exists = target => {
  try { fs.lstatSync(target); return true; }
  catch (error) { if (error && error.code === "ENOENT") return false; throw error; }
};
const analyzePath = (value, label) => {
  if (typeof value !== "string" || !value || /[\0\r\n\t]/.test(value)) fail(`${label} is empty or unsafe`);
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
    const root = path.win32.parse(value).root;
    const remainder = value.slice(root.length);
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
const safeDirectChild = (relative, source, label) => {
  if (!relative || relative.includes(source.api.sep)) fail(`${label} must be a direct child of its anchor`);
  if (relative === "." || relative === ".." ||
      (process.platform === "win32" && (relative.includes("\\") || relative.includes(":") || /[. ]$/.test(relative)))) {
    fail(`${label} contains an unsafe component`);
  }
  return relative;
};
const anchorCache = new Map();
function anchorContext(anchorValue) {
  const anchor = analyzePath(anchorValue, "lock anchor");
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
    const parts = relative ? relative.split(source.api.sep) : [];
    if (parts.some(part => !part || part === "." || part === ".." ||
        (process.platform === "win32" && (part.includes("\\") || part.includes(":") || /[. ]$/.test(part))))) {
      fail("lock anchor contains an unsafe component");
    }
    const logicalNative = path.resolve(mapping.native.value, ...parts);
    const logicalRelative = path.relative(mapping.native.value, logicalNative);
    if (logicalRelative === ".." || logicalRelative.startsWith(`..${path.sep}`) || path.isAbsolute(logicalRelative)) {
      fail("lock anchor escapes its logical native mapping");
    }
    const native = path.resolve(mapping.realNative, ...parts);
    const nativeRelative = path.relative(mapping.realNative, native);
    if (nativeRelative === ".." || nativeRelative.startsWith(`..${path.sep}`) || path.isAbsolute(nativeRelative)) {
      fail("lock anchor escapes its native mapping");
    }
    let stat;
    try { stat = fs.statSync(native); } catch (_) { fail("lock anchor is missing"); }
    if (!stat.isDirectory()) fail("lock anchor is unsafe");
    context = {
      raw: analyzePath(mapping.raw.api.resolve(mapping.raw.value, ...parts), "raw lock anchor"),
      nativeLogical: analyzePath(logicalNative, "native lock anchor"),
      nativePhysical: analyzePath(native, "physical native lock anchor"),
      native: fs.realpathSync(native)
    };
  } else if (process.platform !== "win32") {
    let stat;
    try { stat = fs.statSync(anchor.value); } catch (_) { fail("lock anchor is missing"); }
    if (!stat.isDirectory()) fail("lock anchor is unsafe");
    const native = fs.realpathSync(anchor.value);
    context = { raw: anchor, nativeLogical: analyzePath(native, "native lock anchor"), nativePhysical: analyzePath(native, "physical native lock anchor"), native };
  } else {
    fail("lock anchor is not covered by a trusted raw/native mapping");
  }
  anchorCache.set(cacheKey, context);
  return context;
}

function actualLockPath(anchorValue, lockValue) {
  const context = anchorContext(anchorValue);
  const lock = analyzePath(lockValue, "lock path");
  let relative = relativeWithin(context.raw, lock);
  let source = context.raw;
  if (relative === null) {
    relative = relativeWithin(context.nativeLogical, lock);
    source = context.nativeLogical;
  }
  if (relative === null) {
    relative = relativeWithin(context.nativePhysical, lock);
    source = context.nativePhysical;
  }
  if (relative === null) fail("lock path escapes its anchor");
  const component = safeDirectChild(relative, source, "lock path");
  const actual = path.resolve(context.native, component);
  if (path.dirname(actual) !== context.native) fail("lock path escapes its native anchor");
  return actual;
}

function parseLockBytes(bytes) {
  let metadata;
  try { metadata = JSON.parse(bytes.toString("utf8")); } catch (_) { return null; }
  if (!metadata || metadata.schemaVersion !== 1 || !Number.isSafeInteger(metadata.pid) || metadata.pid <= 0 ||
      typeof metadata.token !== "string" || !/^[a-f0-9]{64}$/.test(metadata.token) ||
      typeof metadata.createdAt !== "string") return null;
  return metadata;
}

function ownerAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (error) {
    if (error && error.code === "ESRCH") return false;
    if (error && error.code === "EPERM") return true;
    throw error;
  }
}

function inspectLock(actualLock) {
  let stat;
  try { stat = fs.lstatSync(actualLock); }
  catch (error) {
    // A normal owner may release between a contender's observations. Treat
    // that disappearance as an absent lock so acquire can retry/busy-exit,
    // never as an internal rc=3 failure.
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
  if (stat.isSymbolicLink()) fail("install lock path is unsafe");
  if (stat.isDirectory()) {
    let names;
    try { names = fs.readdirSync(actualLock); }
    catch (error) {
      if (error && error.code === "ENOENT") return null;
      throw error;
    }
    if (names.some(name => name !== "owner.json")) fail("legacy install lock contains unexpected files");
    let metadata = null;
    const ownerPath = path.join(actualLock, "owner.json");
    if (names.includes("owner.json")) {
      let ownerStat;
      try { ownerStat = fs.lstatSync(ownerPath); }
      catch (error) {
        if (error && error.code === "ENOENT") return null;
        throw error;
      }
      if (!ownerStat.isSymbolicLink() && ownerStat.isFile() && ownerStat.size > 0 && ownerStat.size <= 4096) {
        try { metadata = parseLockBytes(fs.readFileSync(ownerPath)); }
        catch (error) {
          if (error && error.code === "ENOENT") return null;
          throw error;
        }
      }
    }
    return { legacyDirectory: true, stat, metadata, stale: metadata ? !ownerAlive(metadata.pid) : Date.now() - stat.mtimeMs >= 60000 };
  }
  if (!stat.isFile() || stat.size <= 0 || stat.size > 4096) {
    return { legacyDirectory: false, stat, bytes: null, metadata: null, stale: Date.now() - stat.mtimeMs >= 2000 };
  }
  let bytes;
  try { bytes = fs.readFileSync(actualLock); }
  catch (error) {
    if (error && error.code === "ENOENT") return null;
    throw error;
  }
  const metadata = parseLockBytes(bytes);
  return { legacyDirectory: false, stat, bytes, metadata, stale: metadata ? !ownerAlive(metadata.pid) : Date.now() - stat.mtimeMs >= 2000 };
}

function publishLock(actualLock, metadata) {
  const temp = `${actualLock}.pending.${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  let fd;
  try {
    if (!actualLock.endsWith(".recovery") && process.env.NODE_ENV === "test" &&
        process.env.ZENSU_INSTALL_TEST_FAIL_OWNER_WRITE === "1") {
      fail("injected install lock owner write failure");
    }
    fd = fs.openSync(temp, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY |
      (fs.constants.O_NOFOLLOW || 0), 0o600);
    fs.writeFileSync(fd, `${JSON.stringify(metadata)}\n`);
    fs.fsyncSync(fd);
    fs.closeSync(fd); fd = undefined;
    fs.linkSync(temp, actualLock);
  } finally {
    if (fd !== undefined) { try { fs.closeSync(fd); } catch (_) {} }
    try { fs.unlinkSync(temp); } catch (_) {}
  }
}

function removeStaleLock(actualLock, snapshot) {
  if (snapshot.legacyDirectory) {
    const names = fs.readdirSync(actualLock);
    if (names.some(name => name !== "owner.json")) fail("legacy install lock changed during recovery");
    if (names.includes("owner.json")) fs.unlinkSync(path.join(actualLock, "owner.json"));
    fs.rmdirSync(actualLock);
    return;
  }
  const stat = fs.lstatSync(actualLock);
  if (stat.isSymbolicLink() || !stat.isFile()) fail("stale install lock changed type during recovery");
  const bytes = fs.readFileSync(actualLock);
  if (snapshot.bytes && !bytes.equals(snapshot.bytes)) fail("stale install lock changed during recovery");
  fs.unlinkSync(actualLock);
}

function testBarrier(name) {
  if (process.env.NODE_ENV !== "test" || !process.env.ZENSU_INSTALL_TEST_BARRIER_DIR) return;
  const directory = anchorContext(process.env.ZENSU_INSTALL_TEST_BARRIER_DIR).native;
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail("test barrier directory is unsafe");
  const reached = path.join(directory, `${name}.reached`);
  const release = path.join(directory, `${name}.release`);
  if (!exists(reached)) fs.writeFileSync(reached, "reached\n", { flag: "wx", mode: 0o600 });
  const deadline = Date.now() + 15000;
  const waitArray = new Int32Array(new SharedArrayBuffer(4));
  while (!exists(release)) {
    if (Date.now() >= deadline) fail(`test barrier timed out: ${name}`);
    Atomics.wait(waitArray, 0, 0, 20);
  }
}

function releaseAtPath(actualLock, ownerPid, token) {
  if (!exists(actualLock)) fail("install lock disappeared before release");
  const current = inspectLock(actualLock);
  if (!current || !current.metadata || current.metadata.pid !== ownerPid ||
      current.metadata.token !== token || !/^[a-f0-9]{64}$/.test(token || "")) {
    fail("install lock ownership changed");
  }
  fs.unlinkSync(actualLock);
}

function sameRegularSnapshot(snapshot, moved) {
  return snapshot && moved && !snapshot.legacyDirectory && !moved.legacyDirectory &&
    snapshot.stat && moved.stat && snapshot.stat.dev === moved.stat.dev && snapshot.stat.ino === moved.stat.ino &&
    ((snapshot.bytes === null && moved.bytes === null) ||
      (Buffer.isBuffer(snapshot.bytes) && Buffer.isBuffer(moved.bytes) && snapshot.bytes.equals(moved.bytes)));
}

const sleep = milliseconds => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
const recoveryFingerprint = snapshot => {
  if (!snapshot || snapshot.legacyDirectory || !snapshot.stat) return null;
  const digest = snapshot.bytes === null ? "invalid" : crypto.createHash("sha256").update(snapshot.bytes).digest("hex");
  return `${snapshot.stat.dev}:${snapshot.stat.ino}:${snapshot.stat.size}:${digest}`;
};

function parseRecoveryClaim(bytes, expectedToken) {
  let claim;
  try { claim = JSON.parse(bytes.toString("utf8")); } catch (_) { return null; }
  if (!claim || claim.schemaVersion !== 1 || !Number.isSafeInteger(claim.pid) || claim.pid <= 0 ||
      claim.token !== expectedToken || !/^[a-f0-9]{64}$/.test(claim.token || "") ||
      typeof claim.createdAt !== "string" || typeof claim.targetFingerprint !== "string" ||
      claim.targetFingerprint.length > 512) return null;
  return claim;
}

function removeClaimSnapshot(claimPath, snapshot) {
  let stat;
  try { stat = fs.lstatSync(claimPath); }
  catch (error) {
    if (error && error.code === "ENOENT") return false;
    throw error;
  }
  if (stat.isSymbolicLink() || !stat.isFile() || !snapshot.stat ||
      stat.dev !== snapshot.stat.dev || stat.ino !== snapshot.stat.ino) fail("recovery claim changed during cleanup");
  let bytes;
  try { bytes = fs.readFileSync(claimPath); }
  catch (error) {
    if (error && error.code === "ENOENT") return false;
    throw error;
  }
  if (!Buffer.isBuffer(snapshot.bytes) || !bytes.equals(snapshot.bytes)) fail("recovery claim changed during cleanup");
  try { fs.unlinkSync(claimPath); }
  catch (error) {
    if (error && error.code === "ENOENT") return false;
    throw error;
  }
  return true;
}

function recoveryClaims(recoveryPath) {
  const directory = path.dirname(recoveryPath);
  const prefix = `${path.basename(recoveryPath)}.reclaim.`;
  const names = fs.readdirSync(directory).filter(name => name.startsWith(prefix));
  if (names.length > MAX_RECOVERY_CLAIMS) fail("too many install lock recovery claims");
  const claims = [];
  for (const name of names) {
    const claimPath = path.join(directory, name);
    const token = name.slice(prefix.length);
    let stat;
    try { stat = fs.lstatSync(claimPath); }
    catch (error) {
      // Unique claim names are never reused by the protocol. Another
      // contender removing the same orphan between readdir and lstat is a
      // successful cleanup race, not an internal failure.
      if (error && error.code === "ENOENT") continue;
      throw error;
    }
    // publishLock creates a same-prefix .pending file before writing its bytes.
    // A concurrent reader may observe that bounded regular file at size zero;
    // let the parse/age branch below classify it as retryable initialization
    // instead of turning a normal publication window into a fatal rc=3.
    if (stat.isSymbolicLink() || !stat.isFile() || stat.size > 4096) {
      fail("install lock recovery claim is unsafe");
    }
    let bytes;
    try { bytes = fs.readFileSync(claimPath); }
    catch (error) {
      if (error && error.code === "ENOENT") continue;
      throw error;
    }
    const claim = parseRecoveryClaim(bytes, token);
    const snapshot = { stat, bytes };
    if (!claim) {
      if (Date.now() - stat.mtimeMs < 2000) fail("install lock recovery claim is being initialized", 75);
      removeClaimSnapshot(claimPath, snapshot);
      continue;
    }
    if (!ownerAlive(claim.pid)) {
      removeClaimSnapshot(claimPath, snapshot);
      continue;
    }
    claims.push({ path: claimPath, claim, snapshot });
  }
  return claims;
}

function assertNoRecoveryClaims(recoveryPath) {
  if (recoveryClaims(recoveryPath).length) fail("install lock recovery claim is active", 75);
}

// A recoverer can itself die after publishing the short-lived recovery guard.
// Contenders publish unique claims for the exact stale inode, wait one quiet
// election window, and only the lexicographically first live claimant may
// unlink that unchanged inode. Claims remain visible to readers throughout.
function recoverStaleRecoveryGuard(recoveryPath) {
  const existingClaims = recoveryClaims(recoveryPath);
  if (!exists(recoveryPath)) {
    if (existingClaims.length) fail("install lock recovery claim is active", 75);
    return;
  }
  const snapshot = inspectLock(recoveryPath);
  if (!snapshot) {
    if (existingClaims.length) fail("install lock recovery claim is active", 75);
    return;
  }
  if (snapshot.legacyDirectory) fail("install lock recovery guard is unsafe");
  if (!snapshot.stale) fail(snapshot.metadata ? "install lock recovery is busy" : "install lock recovery is being initialized", 75);
  const targetFingerprint = recoveryFingerprint(snapshot);
  const claimToken = crypto.randomBytes(32).toString("hex");
  const claimPath = `${recoveryPath}.reclaim.${claimToken}`;
  const claimOwner = {
    schemaVersion: 1,
    pid: process.pid,
    token: claimToken,
    createdAt: new Date().toISOString(),
    targetFingerprint
  };
  publishLock(claimPath, claimOwner);
  let ownSnapshot = inspectLock(claimPath);
  try {
    testBarrier("recovery-claim-published");
    sleep(RECOVERY_CLAIM_QUIET_MS);
    const candidates = recoveryClaims(recoveryPath);
    const conflicting = candidates.some(candidate => candidate.claim.targetFingerprint !== targetFingerprint);
    if (conflicting) fail("install lock recovery election targets changed state", 75);
    const elected = candidates.filter(candidate => candidate.claim.targetFingerprint === targetFingerprint)
      .map(candidate => candidate.path).sort()[0];
    if (elected !== claimPath) fail("another install lock recovery claimant won", 75);

    const latest = inspectLock(recoveryPath);
    if (!sameRegularSnapshot(snapshot, latest) || !latest.stale) fail("install lock recovery guard changed", 75);
    fs.unlinkSync(recoveryPath);
  } finally {
    if (exists(claimPath)) removeClaimSnapshot(claimPath, ownSnapshot);
  }
}

function assertRecoveryOwnedAndUnclaimed(recoveryPath, ownerPid, token) {
  assertNoRecoveryClaims(recoveryPath);
  const guard = inspectLock(recoveryPath);
  if (!guard || !guard.metadata || guard.metadata.pid !== ownerPid || guard.metadata.token !== token) {
    fail("install lock recovery ownership changed", 75);
  }
}

function acquireLock(anchorValue, lockValue, ownerValue) {
  const actualLock = actualLockPath(anchorValue, lockValue);
  const ownerPid = Number(ownerValue);
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) fail("invalid install lock owner pid");
  const token = crypto.randomBytes(32).toString("hex");
  const metadata = { schemaVersion: 1, pid: ownerPid, token, createdAt: new Date().toISOString() };
  const recoveryPath = `${actualLock}.recovery`;
  recoverStaleRecoveryGuard(recoveryPath);
  assertNoRecoveryClaims(recoveryPath);
  try { publishLock(actualLock, metadata); return token; }
  catch (error) { if (!error || error.code !== "EEXIST") throw error; }

  const current = inspectLock(actualLock);
  if (!current) fail("install lock recovery raced", 75);
  if (!current.stale) fail(current.metadata ? "install lock is busy" : "install lock is being initialized", 75);
  testBarrier("lock-recovery-snapshot");

  const recoveryToken = crypto.randomBytes(32).toString("hex");
  const recoveryOwner = { schemaVersion: 1, pid: process.pid, token: recoveryToken, createdAt: new Date().toISOString() };
  assertNoRecoveryClaims(recoveryPath);
  try { publishLock(recoveryPath, recoveryOwner); }
  catch (error) {
    if (error && error.code === "EEXIST") fail("install lock recovery is busy", 75);
    throw error;
  }
  try {
    assertRecoveryOwnedAndUnclaimed(recoveryPath, process.pid, recoveryToken);
    const latest = inspectLock(actualLock);
    if (latest && !latest.stale) fail(latest.metadata ? "install lock is busy" : "install lock is being initialized", 75);
    if (latest) {
      assertRecoveryOwnedAndUnclaimed(recoveryPath, process.pid, recoveryToken);
      removeStaleLock(actualLock, latest);
    }
    assertRecoveryOwnedAndUnclaimed(recoveryPath, process.pid, recoveryToken);
    try { publishLock(actualLock, metadata); }
    catch (error) {
      if (error && error.code === "EEXIST") fail("install lock recovery lost publication race", 75);
      throw error;
    }
  } finally {
    releaseAtPath(recoveryPath, process.pid, recoveryToken);
  }
  return token;
}

function releaseLock(anchorValue, lockValue, ownerValue, token) {
  const actualLock = actualLockPath(anchorValue, lockValue);
  const ownerPid = Number(ownerValue);
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) fail("invalid install lock owner pid");
  releaseAtPath(actualLock, ownerPid, token);
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  if (command === "acquire") process.stdout.write(acquireLock(args[0], args[1], args[2]));
  else if (command === "release") releaseLock(args[0], args[1], args[2], args[3]);
  else fail(`unknown runtime-lock command: ${command || "<empty>"}`);
}

if (require.main === module) {
  try { main(); }
  catch (error) {
    process.stdout.write((error && error.message) || String(error));
    process.exit(error instanceof RuntimeLockError ? error.exitCode : 3);
  }
}

module.exports = { RuntimeLockError, acquireLock, releaseLock, inspectLock };
