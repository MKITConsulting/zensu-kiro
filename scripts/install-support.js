#!/usr/bin/env node
"use strict";

// Security-sensitive primitives for install.sh. Paths passed by Git Bash can
// be POSIX-style even though Node is native Windows. Bash resolves each trusted
// anchor once and exports its raw + native identities; every child is then
// derived from validated relative components without converting untrusted
// manifest keys. Existing components are checked with lstat and reject links.

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
const fold = value => process.platform === "win32" ? value.toLowerCase() : value;
const analyzePath = (value, label, code = 3) => {
  if (typeof value !== "string" || !value || /[\0\r\n\t]/.test(value)) fail(`${label} is empty or contains control characters`, code);
  if (process.platform === "win32" && value.startsWith("/") && !value.startsWith("//")) {
    if (!path.posix.isAbsolute(value)) fail(`${label} is not absolute`, code);
    if (value.includes("\\")) fail(`${label} contains a Windows separator in MSYS syntax`, code);
    const components = value === "/" ? [] : value.split("/").slice(1);
    if (components.some(component => !component || component === "." || component === ".." ||
        component.includes(":") || /[. ]$/.test(component))) {
      fail(`${label} contains a non-canonical or Windows-aliased component`, code);
    }
    return { api: path.posix, kind: "msys", original: value, value: path.posix.resolve(value) };
  }
  const api = process.platform === "win32" ? path.win32 : path;
  if (!api.isAbsolute(value)) fail(`${label} is not absolute`, code);
  if (process.platform === "win32") {
    const root = path.win32.parse(value).root;
    const remainder = value.slice(root.length);
    const components = remainder ? remainder.split(/[\\/]/) : [];
    if (components.some(component => !component || component === "." || component === ".." ||
        component.includes(":") || /[. ]$/.test(component))) {
      fail(`${label} contains a non-canonical or Windows-aliased component`, code);
    }
  }
  return { api, kind: "native", original: value, value: api.resolve(value) };
};
const relativeWithin = (parent, child) => {
  if (parent.kind !== child.kind) return null;
  const rel = parent.api.relative(parent.value, child.value);
  if (rel === "") return "";
  if (rel === ".." || rel.startsWith(`..${parent.api.sep}`) || parent.api.isAbsolute(rel)) {
    return null;
  }
  return rel;
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
const mappingSpecs = [
  ["ZENSU_KIRO_HOME_ANCHOR_RAW", "ZENSU_KIRO_HOME_ANCHOR_NATIVE"],
  ["ZENSU_KIRO_WORKSPACE_ANCHOR_RAW", "ZENSU_KIRO_WORKSPACE_ANCHOR_NATIVE"],
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

function safeParts(relative, source, label) {
  if (!relative) return [];
  const parts = relative.split(source.api.sep);
  if (parts.some(part => !part || part === "." || part === ".." ||
      (process.platform === "win32" && (part.includes("\\") || part.includes(":") || /[. ]$/.test(part))))) {
    fail(`${label} contains an unsafe relative component`);
  }
  return parts;
}

function contextFromMapping(mapping, anchor, relative, source) {
  const parts = safeParts(relative, source, "anchor");
  const rawValue = mapping.raw.api.resolve(mapping.raw.value, ...parts);
  const nativeLogicalValue = path.resolve(mapping.native.value, ...parts);
  const logicalEscape = path.relative(mapping.native.value, nativeLogicalValue);
  if (logicalEscape === ".." || logicalEscape.startsWith(`..${path.sep}`) || path.isAbsolute(logicalEscape)) fail("anchor escaped its logical native mapping");
  const nativeValue = path.resolve(mapping.realNative, ...parts);
  const physicalEscape = path.relative(mapping.realNative, nativeValue);
  if (physicalEscape === ".." || physicalEscape.startsWith(`..${path.sep}`) || path.isAbsolute(physicalEscape)) fail("anchor escaped its physical native mapping");
  let stat;
  try { stat = fs.statSync(nativeValue); } catch (_) { fail("trusted anchor is missing"); }
  if (!stat.isDirectory()) fail("trusted anchor is not a directory");
  return {
    raw: analyzePath(rawValue, "raw anchor"),
    nativeLogical: analyzePath(nativeLogicalValue, "native anchor"),
    nativePhysical: analyzePath(nativeValue, "physical native anchor"),
    native: fs.realpathSync(nativeValue),
    source: anchor
  };
}

const anchorCache = new Map();
function anchorContext(anchorValue) {
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
    const selected = candidates[0];
    context = contextFromMapping(selected.mapping, anchor, selected.relative, selected.source);
  } else if (process.platform !== "win32") {
    let stat;
    try { stat = fs.statSync(anchor.value); } catch (_) { fail("trusted anchor is missing"); }
    if (!stat.isDirectory()) fail("trusted anchor is not a directory");
    const native = fs.realpathSync(anchor.value);
    context = { raw: anchor, nativeLogical: analyzePath(native, "native anchor"), nativePhysical: analyzePath(native, "physical native anchor"), native, source: anchor };
  } else {
    fail("anchor is not covered by a trusted raw/native mapping");
  }
  anchorCache.set(cacheKey, context);
  return context;
}

function deriveChild(context, value, label) {
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
  if (relative === null) fail(`${label} escapes its trusted anchor`);
  const parts = safeParts(relative, source, label);
  const target = path.resolve(context.native, ...parts);
  const nativeRelative = path.relative(context.native, target);
  if (nativeRelative === ".." || nativeRelative.startsWith(`..${path.sep}`) || path.isAbsolute(nativeRelative)) {
    fail(`${label} escapes its native anchor`);
  }
  return { logical: child, target };
}

const logicalDirname = value => {
  const analyzed = analyzePath(value, "path");
  return analyzed.api.dirname(analyzed.original);
};

function assertCanonicalRawPath(value, label, code) {
  if (value.endsWith("/") || (process.platform === "win32" && value.endsWith("\\"))) {
    fail(`${label} has a trailing separator`, code);
  }
  const analyzed = analyzePath(value, label, code);
  let canonical;
  if (process.platform === "win32" && analyzed.kind === "msys") {
    canonical = path.posix.normalize(value) === value;
  } else if (process.platform === "win32") {
    const windowsSpelling = value.replace(/\//g, "\\");
    canonical = fold(path.win32.normalize(windowsSpelling)) === fold(windowsSpelling);
  } else {
    canonical = analyzed.value === value;
  }
  if (!canonical) fail(`${label} is not canonical`, code);
  return analyzed;
}

function testBarrier(name) {
  if (process.env.NODE_ENV !== "test" || !process.env.ZENSU_INSTALL_TEST_BARRIER_DIR) return;
  const directory = anchorContext(process.env.ZENSU_INSTALL_TEST_BARRIER_DIR).native;
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
  const context = anchorContext(anchorValue);
  const root = deriveChild(context, rootValue, "allowed root");
  const target = deriveChild(context, targetValue, "target path");
  const targetFromRoot = path.relative(root.target, target.target);
  if (targetFromRoot === ".." || targetFromRoot.startsWith(`..${path.sep}`) || path.isAbsolute(targetFromRoot)) {
    fail(`path escapes allowed root: ${targetValue}`);
  }
  const relative = path.relative(context.native, target.target);
  let cursor = context.native;
  for (const part of relative.split(path.sep).filter(Boolean)) {
    cursor = path.join(cursor, part);
    if (!exists(cursor)) continue;
    const stat = fs.lstatSync(cursor);
    if (stat.isSymbolicLink()) fail(`symlink component refused: ${targetValue}`);
  }
  return { root: root.target, target: target.target, anchor: context.native };
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
  const parent = resolveGuarded(rootValue, logicalDirname(targetValue), anchorValue);
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
  ensureDirectory(rootValue, logicalDirname(logicalTarget), anchorValue);
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

    const parent = resolveGuarded(rootValue, logicalDirname(logicalTarget), anchorValue);
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
    const logicalFile = assertCanonicalRawPath(file, "manifest path", 5);
    const resolved = resolveGuarded(rootValue, file, anchorValue);
    const canonical = fold(resolved.target);
    // Classification in install.sh must never see a raw spelling that points
    // somewhere different after normalization (for example
    // `zensu/../agents/...`). Git Bash paths keep their POSIX spelling here;
    // the separately derived native identity comes from the bound anchor.
    let canonicalSpelling;
    if (process.platform === "win32" && file.startsWith("/") && !file.startsWith("//")) {
      canonicalSpelling = path.posix.normalize(file) === file;
    } else if (process.platform === "win32") {
      const windowsSpelling = file.replace(/\//g, "\\");
      canonicalSpelling = fold(path.win32.normalize(windowsSpelling)) === fold(windowsSpelling);
    } else {
      canonicalSpelling = file === logicalFile.value;
    }
    if (!canonicalSpelling) fail("manifest path is not canonical", 5);
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

function renderJson(home) {
  if (typeof home !== "string" || !home) fail("HOME is unavailable");
  if (/[\x00-\x1f\x7f]/.test(home)) fail("HOME contains control characters");
  let value;
  try { value = JSON.parse(fs.readFileSync(0, "utf8")); }
  catch (_) { fail("agent source is invalid JSON"); }
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
  const wanted = fold(resolveGuarded(rootValue, targetValue, anchorValue).target);
  for (const [file, hash] of Object.entries(parsed.manifest.files)) {
    if (fold(resolveGuarded(rootValue, file, anchorValue).target) === wanted) {
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
  const [manifestValue, version, rootValue, anchorValue] = args;
  if (!parseSemVer(version)) fail("source VERSION is invalid");
  const lines = fs.readFileSync(0, "utf8").split("\n").filter(Boolean);
  const files = {};
  const seen = new Map();
  for (const line of lines) {
    const index = line.indexOf("\t");
    if (index <= 0) fail("invalid installer list entry");
    const file = line.slice(0, index);
    const hash = line.slice(index + 1);
    if (!/^[a-f0-9]{64}$/.test(hash)) fail("invalid installer list hash");
    assertCanonicalRawPath(file, "installer list path", 3);
    const resolved = resolveGuarded(rootValue, file, anchorValue);
    const canonical = fold(resolved.target);
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
      const base = anchorContext(value).native;
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
    case "render-json": renderJson(process.env.ZENSU_KIRO_RENDER_HOME_RAW || ""); break;
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
