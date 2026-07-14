#!/usr/bin/env node
"use strict";

// Security-sensitive primitives for install.sh. Paths passed by Git Bash can
// be POSIX-style even though Node is native Windows, so filesystem operations
// normalize /c/... while manifest keys retain the shell spelling used at
// publication. HOME/workspace are trusted anchors; every component created beneath
// those anchors is checked with lstat and symlinks are rejected.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const runtimeLock = require("../hooks/lib/kiro-runtime-lock.js");

class InstallError extends Error {
  constructor(message, code = 3) {
    super(message);
    this.exitCode = code;
  }
}

const fail = (message, code = 3) => { throw new InstallError(message, code); };
const norm = value => process.platform === "win32"
  ? value.replace(/^\/([A-Za-z])(\/|$)/, (_m, drive, slash) => `${drive.toUpperCase()}:${slash || ""}`)
  : value;
const fold = value => process.platform === "win32" ? value.toLowerCase() : value;
const absolute = (value, label) => {
  if (typeof value !== "string" || !value || /[\0\r\n\t]/.test(value)) fail(`${label} is empty or contains control characters`);
  const converted = norm(value);
  if (!path.isAbsolute(converted)) fail(`${label} is not absolute`);
  return path.resolve(converted);
};
const within = (root, target) => {
  const rel = path.relative(root, target);
  return rel === "" || (!rel.startsWith(`..${path.sep}`) && rel !== ".." && !path.isAbsolute(rel));
};
const exists = file => {
  try { fs.lstatSync(file); return true; } catch (error) {
    if (error && error.code === "ENOENT") return false;
    throw error;
  }
};
const hashBuffer = value => crypto.createHash("sha256").update(value).digest("hex");
const hashFileDescriptor = fd => {
  const digest = crypto.createHash("sha256");
  const buffer = Buffer.allocUnsafe(64 * 1024);
  let position = 0;
  for (;;) {
    const count = fs.readSync(fd, buffer, 0, buffer.length, position);
    if (count === 0) break;
    digest.update(buffer.subarray(0, count));
    position += count;
  }
  return digest.digest("hex");
};
const sameIdentity = (left, right) => left.dev === right.dev && left.ino === right.ino;
const manifestKey = value => fold(absolute(value, "manifest path"));

function testBarrier(name) {
  if (process.env.NODE_ENV !== "test" || !process.env.ZENSU_INSTALL_TEST_BARRIER_DIR) return;
  const directory = absolute(process.env.ZENSU_INSTALL_TEST_BARRIER_DIR, "test barrier directory");
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) fail("test barrier directory is unsafe");
  fs.writeFileSync(path.join(directory, `${name}.reached`), "reached\n", { flag: "wx", mode: 0o600 });
  const release = path.join(directory, `${name}.release`);
  const deadline = Date.now() + 15000;
  const waitArray = new Int32Array(new SharedArrayBuffer(4));
  while (!exists(release)) {
    if (Date.now() >= deadline) fail(`test barrier timed out: ${name}`);
    Atomics.wait(waitArray, 0, 0, 20);
  }
}

function resolveGuarded(rootValue, targetValue, anchorValue) {
  const anchor = absolute(anchorValue, "anchor");
  const root = absolute(rootValue, "allowed root");
  const target = absolute(targetValue, "target path");
  if (!within(anchor, root)) fail("allowed root escapes its trusted anchor");
  if (!within(root, target)) fail(`path escapes allowed root: ${targetValue}`);

  let anchorStat;
  try { anchorStat = fs.statSync(anchor); } catch (_) { fail("trusted anchor is missing"); }
  if (!anchorStat.isDirectory()) fail("trusted anchor is not a directory");
  const realAnchor = fs.realpathSync(anchor);
  const actualRoot = path.resolve(realAnchor, path.relative(anchor, root));
  const actualTarget = path.resolve(realAnchor, path.relative(anchor, target));
  if (!within(actualRoot, actualTarget)) fail(`canonical path escapes allowed root: ${targetValue}`);

  const relative = path.relative(realAnchor, actualTarget);
  let cursor = realAnchor;
  for (const part of relative.split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, part);
    if (!exists(cursor)) continue;
    const stat = fs.lstatSync(cursor);
    if (stat.isSymbolicLink()) fail(`symlink component refused: ${targetValue}`);
  }
  return { root: actualRoot, target: actualTarget, anchor: realAnchor };
}

function ensureDirectory(rootValue, directoryValue, anchorValue) {
  const resolved = resolveGuarded(rootValue, directoryValue, anchorValue);
  const relative = path.relative(resolved.anchor, resolved.target);
  let cursor = resolved.anchor;
  for (const part of relative.split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, part);
    if (!exists(cursor)) {
      try { fs.mkdirSync(cursor, { mode: 0o755 }); }
      catch (error) {
        if (!error || error.code !== "EEXIST") throw error;
      }
    }
    const stat = fs.lstatSync(cursor);
    if (stat.isSymbolicLink() || !stat.isDirectory()) fail(`non-directory or symlink component refused: ${directoryValue}`);
  }
  return resolved.target;
}

function regularState(rootValue, targetValue, anchorValue) {
  const resolved = resolveGuarded(rootValue, targetValue, anchorValue);
  if (!exists(resolved.target)) return { state: "missing", path: resolved.target };
  const stat = fs.lstatSync(resolved.target);
  if (stat.isSymbolicLink()) fail(`symlink leaf refused: ${targetValue}`);
  return { state: stat.isFile() ? "file" : "other", path: resolved.target };
}

function verifyClaimedFile(claimedPath, targetValue, expectedHash) {
  let fd;
  try {
    fd = fs.openSync(claimedPath, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const before = fs.fstatSync(fd);
    if (!before.isFile()) fail(`target changed type: ${targetValue}`);
    const digest = hashFileDescriptor(fd);
    const after = fs.fstatSync(fd);
    const leaf = fs.lstatSync(claimedPath);
    if (leaf.isSymbolicLink() || !leaf.isFile() || !sameIdentity(before, after) || !sameIdentity(after, leaf) ||
        before.size !== after.size || before.mtimeMs !== after.mtimeMs) {
      fail(`target changed during verification: ${targetValue}`);
    }
    if (digest !== expectedHash) fail(`target hash changed since inspection: ${targetValue}`);
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function restoreClaim(claimedPath, targetPath, targetValue) {
  if (exists(targetPath)) fail(`target changed after claim; preserved prior bytes at ${claimedPath}`);
  const stat = fs.lstatSync(claimedPath);
  try {
    if (stat.isFile() && !stat.isSymbolicLink()) {
      fs.linkSync(claimedPath, targetPath);
      fs.unlinkSync(claimedPath);
    } else {
      fs.renameSync(claimedPath, targetPath);
    }
  } catch (_) {
    fail(`could not restore changed target; preserved bytes at ${claimedPath}`);
  }
}

function claimExpectedFile(rootValue, targetValue, anchorValue, expectedHash, replacementHash, barrierName) {
  if (!/^[a-f0-9]{64}$/.test(expectedHash || "")) fail("invalid expected file hash");
  if (!/^[a-f0-9]{64}$/.test(replacementHash || "")) fail("invalid replacement file hash");
  const current = regularState(rootValue, targetValue, anchorValue);
  if (current.state !== "file") fail(`target changed since inspection: ${targetValue}`);
  const parent = resolveGuarded(rootValue, path.dirname(targetValue), anchorValue);
  if (fold(parent.target) !== fold(path.dirname(current.path))) fail("target parent changed before claim");
  testBarrier(barrierName);
  const claimed = `${current.path}.zensu-recovery.${expectedHash}.${replacementHash}.${process.pid}.${crypto.randomBytes(8).toString("hex")}`;
  fs.renameSync(current.path, claimed);
  try {
    verifyClaimedFile(claimed, targetValue, expectedHash);
  } catch (error) {
    restoreClaim(claimed, current.path, targetValue);
    throw error;
  }
  return { target: current.path, claimed };
}

function atomicWrite(rootValue, targetValue, anchorValue, executable, expectedState, expectedHash, content) {
  const logicalTarget = targetValue;
  ensureDirectory(rootValue, path.dirname(logicalTarget), anchorValue);
  const current = regularState(rootValue, logicalTarget, anchorValue);
  if (current.state === "other") fail(`write target is not a regular file: ${logicalTarget}`);
  if (process.env.NODE_ENV === "test" && process.env.ZENSU_INSTALL_TEST_FAIL_TARGET &&
      logicalTarget.endsWith(process.env.ZENSU_INSTALL_TEST_FAIL_TARGET)) {
    fail(`injected write failure for ${logicalTarget}`);
  }
  const directory = path.dirname(current.path);
  const mode = executable ? 0o755 : 0o644;
  let temp = "";
  let fd;
  try {
    for (let attempt = 0; attempt < 32; attempt += 1) {
      temp = path.join(directory, `.zensu-install.${process.pid}.${crypto.randomBytes(8).toString("hex")}`);
      try {
        fd = fs.openSync(temp, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY |
          (fs.constants.O_NOFOLLOW || 0), mode);
        break;
      } catch (error) {
        if (!error || error.code !== "EEXIST") throw error;
      }
    }
    if (fd === undefined) fail("could not allocate an exclusive temporary file");
    fs.writeFileSync(fd, content);
    fs.fsyncSync(fd);
    fs.fchmodSync(fd, mode);
    fs.closeSync(fd); fd = undefined;

    const parent = resolveGuarded(rootValue, path.dirname(logicalTarget), anchorValue);
    if (fold(parent.target) !== fold(directory)) fail("write parent changed during publication");
    if (expectedState === "missing") {
      testBarrier("atomic-write");
      try { fs.linkSync(temp, current.path); }
      catch (error) {
        if (error && error.code === "EEXIST") fail(`target changed since inspection: ${logicalTarget}`);
        throw error;
      }
      fs.unlinkSync(temp); temp = "";
      return;
    }
    if (expectedState !== "file") fail("invalid expected file state");
    const claimed = claimExpectedFile(rootValue, logicalTarget, anchorValue, expectedHash, hashBuffer(content), "atomic-write");
    testBarrier("atomic-write-publish");
    try {
      fs.linkSync(temp, claimed.target);
      fs.unlinkSync(temp); temp = "";
      fs.unlinkSync(claimed.claimed);
    } catch (error) {
      if (!exists(claimed.target)) restoreClaim(claimed.claimed, claimed.target, logicalTarget);
      else if (exists(claimed.claimed)) fail(`publication raced; preserved prior bytes at ${claimed.claimed}`);
      throw error;
    }
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
    if (temp) { try { fs.unlinkSync(temp); } catch (_) {} }
  }
}

function safeRemove(rootValue, targetValue, anchorValue, expectedHash) {
  const claimed = claimExpectedFile(rootValue, targetValue, anchorValue, expectedHash, "0".repeat(64), "remove");
  fs.unlinkSync(claimed.claimed);
}

function recoverTarget(rootValue, targetValue, anchorValue) {
  const resolved = resolveGuarded(rootValue, targetValue, anchorValue);
  const parent = path.dirname(resolved.target);
  if (!exists(parent)) return;
  const parentStat = fs.lstatSync(parent);
  if (parentStat.isSymbolicLink() || !parentStat.isDirectory()) fail(`recovery parent is unsafe: ${targetValue}`);
  const prefix = `${path.basename(resolved.target)}.zensu-recovery.`;
  const claims = fs.readdirSync(parent).filter(name => name.startsWith(prefix));
  if (claims.length > 8) fail(`too many recovery artifacts for ${targetValue}`);
  for (const name of claims) {
    const parts = name.slice(prefix.length).split(".");
    if (parts.length !== 4 || !/^[a-f0-9]{64}$/.test(parts[0]) || !/^[a-f0-9]{64}$/.test(parts[1]) ||
        !/^[1-9][0-9]*$/.test(parts[2]) || !/^[a-f0-9]{16}$/.test(parts[3])) {
      fail(`recovery artifact name is invalid for ${targetValue}`);
    }
    const claim = path.join(parent, name);
    const claimStat = fs.lstatSync(claim);
    if (claimStat.isSymbolicLink() || !claimStat.isFile()) fail(`recovery artifact is unsafe for ${targetValue}`);
    if (hashBuffer(fs.readFileSync(claim)) !== parts[0]) fail(`recovery artifact bytes changed for ${targetValue}`);
    if (!exists(resolved.target)) {
      fs.linkSync(claim, resolved.target);
      fs.unlinkSync(claim);
      continue;
    }
    const targetStat = fs.lstatSync(resolved.target);
    if (targetStat.isSymbolicLink() || !targetStat.isFile()) fail(`recovery target is unsafe: ${targetValue}`);
    const targetHash = hashBuffer(fs.readFileSync(resolved.target));
    if (targetHash !== parts[0] && targetHash !== parts[1]) {
      fail(`recovery conflicts with changed target; preserved prior bytes at ${claim}`);
    }
    fs.unlinkSync(claim);
  }
}

function parseSemVer(value) {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/.exec(value || "");
  if (!match) return null;
  const pre = match[4] ? match[4].split(".") : [];
  if (pre.some(identifier => /^\d+$/.test(identifier) && identifier.length > 1 && identifier.startsWith("0"))) return null;
  return { core: [BigInt(match[1]), BigInt(match[2]), BigInt(match[3])], pre };
}

function compareSemVer(left, right) {
  for (let i = 0; i < 3; i += 1) {
    if (left.core[i] !== right.core[i]) return left.core[i] > right.core[i] ? 1 : -1;
  }
  if (!left.pre.length && right.pre.length) return 1;
  if (left.pre.length && !right.pre.length) return -1;
  for (let i = 0; i < Math.max(left.pre.length, right.pre.length); i += 1) {
    if (left.pre[i] === undefined) return -1;
    if (right.pre[i] === undefined) return 1;
    if (left.pre[i] === right.pre[i]) continue;
    const leftNumeric = /^\d+$/.test(left.pre[i]);
    const rightNumeric = /^\d+$/.test(right.pre[i]);
    if (leftNumeric && rightNumeric) return BigInt(left.pre[i]) > BigInt(right.pre[i]) ? 1 : -1;
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    return left.pre[i] > right.pre[i] ? 1 : -1;
  }
  return 0;
}

function readManifest(manifestValue, rootValue, anchorValue) {
  const state = regularState(rootValue, manifestValue, anchorValue);
  if (state.state === "missing") return null;
  if (state.state !== "file") fail("manifest is not a regular file");
  const stat = fs.lstatSync(state.path);
  if (stat.size <= 0 || stat.size > 5 * 1024 * 1024) fail("manifest size is invalid", 5);
  let manifest;
  try { manifest = JSON.parse(fs.readFileSync(state.path, "utf8")); }
  catch (_) { fail("invalid manifest JSON", 5); }
  if (!manifest || Array.isArray(manifest) || typeof manifest.version !== "string" ||
      !manifest.files || Array.isArray(manifest.files) || typeof manifest.files !== "object") {
    fail("invalid manifest schema", 5);
  }
  return { manifest, path: state.path };
}

function validateManifestEntries(manifest, rootValue, anchorValue) {
  const seen = new Map();
  for (const [file, hash] of Object.entries(manifest.files)) {
    if (typeof hash !== "string" || !/^[a-f0-9]{64}$/.test(hash)) fail("invalid manifest file entry", 5);
    const resolved = resolveGuarded(rootValue, file, anchorValue);
    const canonical = manifestKey(file);
    // Classification in install.sh must never see a raw spelling that points
    // somewhere different after normalization (for example
    // `zensu/../agents/...`). Git Bash drive paths remain supported by first
    // converting `/c/...` and normalizing slash direction on native Windows.
    const spelling = process.platform === "win32"
      ? fold(norm(file).replace(/[\\/]/g, path.sep))
      : file;
    if (spelling !== canonical) fail("manifest path is not canonical", 5);
    // On case-insensitive volumes, lstat and even realpath may preserve an
    // alias such as `HOOKS` for an on-disk `hooks` directory. Bash
    // classification remains textual, so accepting that alias could make
    // reconciliation delete the canonical file. Walk directory entries and
    // require the exact stored spelling for every component that currently
    // resolves; on a case-sensitive volume a differently cased component is
    // simply missing and cannot alias/delete the managed target.
    let cursor = resolved.anchor;
    for (const component of path.relative(resolved.anchor, resolved.target).split(path.sep).filter(Boolean)) {
      let entries;
      try { entries = fs.readdirSync(cursor); }
      catch (error) {
        if (error && error.code === "ENOENT") break;
        throw error;
      }
      if (entries.includes(component)) {
        cursor = path.join(cursor, component);
        continue;
      }
      const candidate = path.join(cursor, component);
      if (exists(candidate)) fail("manifest path does not match filesystem spelling", 5);
      break;
    }
    if (seen.has(canonical) && seen.get(canonical) !== file) fail("duplicate canonical manifest path", 5);
    seen.set(canonical, file);
  }
}

function preflight(args) {
  const [manifestValue, installedVersionValue, sourceVersion, rootValue, anchorValue, uninstall] = args;
  const parsed = readManifest(manifestValue, rootValue, anchorValue);
  if (!parsed) return;
  validateManifestEntries(parsed.manifest, rootValue, anchorValue);
  const have = parseSemVer(parsed.manifest.version);
  const want = parseSemVer(sourceVersion);
  if (!have || !want) fail("invalid manifest/source version", 5);
  if (uninstall === "1") return;
  if (compareSemVer(have, want) > 0) fail(`downgrade ${parsed.manifest.version} -> ${sourceVersion}`, 4);
  if (installedVersionValue) {
    const versionState = regularState(rootValue, installedVersionValue, anchorValue);
    if (versionState.state === "other") fail("installed VERSION is not a regular file");
    if (versionState.state === "file") {
      const disk = fs.readFileSync(versionState.path, "utf8").trim();
      if (disk !== parsed.manifest.version) {
        fail(`manifest version ${parsed.manifest.version} disagrees with installed VERSION ${disk}`, 4);
      }
    }
  }
}

function shellDoubleQuoted(value) {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$/g, "\\$").replace(/`/g, "\\`");
}

function renderJson(source, home) {
  if (/[\x00-\x1f\x7f]/.test(home)) fail("HOME contains control characters");
  let value;
  try { value = JSON.parse(fs.readFileSync(source, "utf8")); }
  catch (_) { fail(`agent source is invalid JSON: ${source}`); }
  const walk = (item, key = "") => {
    if (Array.isArray(item)) return item.map(entry => walk(entry, key));
    if (item && typeof item === "object") {
      const rendered = {};
      for (const [childKey, child] of Object.entries(item)) rendered[childKey] = walk(child, childKey);
      return rendered;
    }
    if (typeof item !== "string" || !item.includes("__ZENSU_HOME__")) return item;
    const replacement = key === "command" ? shellDoubleQuoted(home) : home;
    return item.split("__ZENSU_HOME__").join(replacement);
  };
  process.stdout.write(`${JSON.stringify(walk(value), null, 2)}\n`);
}

function manifestLookup(args) {
  const [manifestValue, targetValue, rootValue, anchorValue] = args;
  const parsed = readManifest(manifestValue, rootValue, anchorValue);
  if (!parsed) return;
  validateManifestEntries(parsed.manifest, rootValue, anchorValue);
  const wanted = manifestKey(targetValue);
  for (const [file, hash] of Object.entries(parsed.manifest.files)) {
    if (manifestKey(file) === wanted) {
      process.stdout.write(hash);
      return;
    }
  }
}

function manifestLines(args) {
  const [manifestValue, rootValue, anchorValue] = args;
  const parsed = readManifest(manifestValue, rootValue, anchorValue);
  if (!parsed) return;
  validateManifestEntries(parsed.manifest, rootValue, anchorValue);
  for (const [file, hash] of Object.entries(parsed.manifest.files)) process.stdout.write(`${file}\t${hash}\n`);
}

function writeManifest(args) {
  const [manifestValue, listValue, version, rootValue, anchorValue] = args;
  if (!parseSemVer(version)) fail("source VERSION is invalid");
  const lines = fs.readFileSync(norm(listValue), "utf8").split("\n").filter(Boolean);
  const files = {};
  const seen = new Map();
  for (const line of lines) {
    const index = line.indexOf("\t");
    if (index <= 0) fail("invalid installer list entry");
    const file = line.slice(0, index);
    const hash = line.slice(index + 1);
    if (!/^[a-f0-9]{64}$/.test(hash)) fail("invalid installer list hash");
    resolveGuarded(rootValue, file, anchorValue);
    const canonical = manifestKey(file);
    if (seen.has(canonical) && seen.get(canonical) !== file) fail("duplicate canonical installer path");
    seen.set(canonical, file);
    files[file] = hash;
  }
  const prior = regularState(rootValue, manifestValue, anchorValue);
  if (prior.state === "other") fail("manifest target is not a regular file");
  let expectedHash = "-";
  if (prior.state === "file") expectedHash = hashBuffer(fs.readFileSync(prior.path));
  atomicWrite(rootValue, manifestValue, anchorValue, false, prior.state, expectedHash,
    Buffer.from(`${JSON.stringify({ version, files }, null, 2)}\n`));
}

function acquireLock(args) {
  try { process.stdout.write(runtimeLock.acquireLock(args[0], args[1], args[2])); }
  catch (error) { fail(error.message || String(error), error.exitCode || 3); }
}

function releaseLock(args) {
  try { runtimeLock.releaseLock(args[0], args[1], args[2], args[3]); }
  catch (error) { fail(error.message || String(error), error.exitCode || 3); }
}

function main() {
  const [command, ...args] = process.argv.slice(2);
  switch (command) {
    case "validate-base": {
      const value = args[0] || "";
      if (/[\x00-\x1f\x7f]/.test(value)) fail("base path contains control characters");
      const base = absolute(value, "base path");
      const stat = fs.statSync(base);
      if (!stat.isDirectory()) fail("base path is not a directory");
      break;
    }
    case "guard": resolveGuarded(args[0], args[1], args[2]); break;
    case "state": process.stdout.write(regularState(args[0], args[1], args[2]).state); break;
    case "atomic-write": atomicWrite(args[0], args[1], args[2], args[3] === "1", args[4], args[5], fs.readFileSync(0)); break;
    case "recover-target": recoverTarget(args[0], args[1], args[2]); break;
    case "remove": safeRemove(args[0], args[1], args[2], args[3]); break;
    case "mkdir": ensureDirectory(args[0], args[1], args[2]); break;
    case "preflight": preflight(args); break;
    case "render-json": renderJson(args[0], args[1]); break;
    case "manifest-lookup": manifestLookup(args); break;
    case "manifest-lines": manifestLines(args); break;
    case "write-manifest": writeManifest(args); break;
    case "acquire-lock": acquireLock(args); break;
    case "release-lock": releaseLock(args); break;
    default: fail(`unknown install-support command: ${command || "<empty>"}`);
  }
}

try { main(); }
catch (error) {
  const message = error instanceof InstallError ? error.message : (error && error.message) || String(error);
  process.stdout.write(message);
  process.exit(error instanceof InstallError ? error.exitCode : 3);
}
