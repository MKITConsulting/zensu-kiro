#!/usr/bin/env node
"use strict";

// Resolve one existing shell anchor to the native filesystem namespace. The
// raw value arrives through the environment so MSYS cannot rewrite it as a
// command-line argument. On Windows the converter is the cygpath.exe paired
// with the running Git Bash, never a PATH lookup, and Bash independently binds
// the result back to the same physical directory.
// HOME and workspace anchors are trusted to remain stable for one command;
// concurrent junction/symlink retargeting is outside the installer contract.
const childProcess = require("child_process");
const fs = require("fs");
const path = require("path");

const fail = message => { process.stderr.write(`${message}\n`); process.exit(3); };
const raw = process.env.ZENSU_KIRO_ANCHOR_RAW || "";
if (!raw) fail("anchor is empty");
if (/[\0\r\n\t]/.test(raw)) fail("anchor contains control characters");

const oneLine = (stdout, label) => {
  let value = typeof stdout === "string" ? stdout : "";
  if (value.endsWith("\r\n")) value = value.slice(0, -2);
  else if (value.endsWith("\n")) value = value.slice(0, -1);
  if (!value || /[\0\r\n\t]/.test(value)) fail(`${label} returned empty or multiline output`);
  return value;
};

const timeout = (() => {
  const value = process.env.NODE_ENV === "test" ? process.env.ZENSU_KIRO_TEST_CONVERTER_TIMEOUT_MS : "";
  return /^[1-9][0-9]{0,3}$/.test(value || "") ? Number(value) : 5000;
})();

const checkedExecutable = (value, label) => {
  if (!value || !path.win32.isAbsolute(value) || /[\0\r\n\t]/.test(value)) fail(`${label} is unavailable or unsafe`);
  let stat;
  try { stat = fs.lstatSync(value); } catch (_) { fail(`${label} is unavailable or unsafe`); }
  if (stat.isSymbolicLink() || !stat.isFile()) fail(`${label} is unavailable or unsafe`);
  return value;
};

const run = (executable, args, label) => {
  const result = childProcess.spawnSync(executable, args, { encoding: "utf8", windowsHide: true, timeout });
  if (result.error || result.status !== 0) fail(`${label} failed or timed out`);
  return oneLine(result.stdout, label);
};

if (process.platform !== "win32") {
  if (!path.isAbsolute(raw)) fail("anchor is not absolute");
  if (path.resolve(raw) !== raw) fail("anchor is not canonical");
  let stat;
  try { stat = fs.statSync(raw); } catch (_) { fail("anchor is missing"); }
  if (!stat.isDirectory()) fail("anchor is not a directory");
  process.stdout.write(fs.realpathSync(raw));
  process.exit(0);
}

if (raw.startsWith("/") && !raw.startsWith("//")) {
  if (raw.includes("\\")) fail("anchor contains a Windows separator in MSYS syntax");
  const components = raw === "/" ? [] : raw.split("/").slice(1);
  if (components.some(component => !component || component === "." || component === ".." ||
      component.includes(":") || /[. ]$/.test(component))) {
    fail("anchor contains a non-canonical or Windows-aliased component");
  }
} else {
  if (!path.win32.isAbsolute(raw)) fail("anchor is not absolute");
  const root = path.win32.parse(raw).root;
  const remainder = raw.slice(root.length);
  const components = remainder ? remainder.split(/[\\/]/) : [];
  if (components.some(component => !component || component === "." || component === ".." ||
      component.includes(":") || /[. ]$/.test(component))) {
    fail("anchor contains a non-canonical or Windows-aliased component");
  }
}

const bash = checkedExecutable(process.env.ZENSU_KIRO_TRUSTED_BASH_NATIVE || "", "trusted Git Bash executable");
let converter = process.env.ZENSU_KIRO_TRUSTED_CYGPATH_NATIVE || "";
let prefix = [];
if (process.env.NODE_ENV === "test" && process.env.ZENSU_KIRO_TEST_CYGPATH_NATIVE) {
  converter = process.env.ZENSU_KIRO_TEST_CYGPATH_NATIVE;
  if (process.env.ZENSU_KIRO_TEST_CYGPATH_SCRIPT_NATIVE) prefix = [process.env.ZENSU_KIRO_TEST_CYGPATH_SCRIPT_NATIVE];
}
converter = checkedExecutable(converter, "trusted cygpath executable");
const converted = run(converter, [...prefix, "-am", raw], "Git Bash path conversion");
if (!path.win32.isAbsolute(converted)) fail("Git Bash path conversion returned a relative path");

const physical = value => {
  const result = run(bash,
    ["--noprofile", "--norc", "-c", 'cd -P -- "$1" && pwd -W', "zensu-anchor", value],
    "Git Bash anchor verification");
  if (!path.win32.isAbsolute(result)) fail("Git Bash anchor verification returned a relative path");
  return path.win32.resolve(result).toLowerCase();
};
const native = path.win32.resolve(converted);
if (physical(raw) !== physical(native)) fail("Git Bash path conversion returned an unrelated anchor");
let stat;
try { stat = fs.statSync(native); } catch (_) { fail("converted anchor is missing"); }
if (!stat.isDirectory()) fail("converted anchor is not a directory");
// Preserve the logical native spelling (including a verified junction or
// symlink anchor). Consumers separately realpath it for filesystem access.
process.stdout.write(native);
