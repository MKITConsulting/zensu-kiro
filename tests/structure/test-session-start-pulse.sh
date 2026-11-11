#!/usr/bin/env bash
# Exercise the real Kiro shim with disposable HOME/profile directories only.
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node - "$ROOT" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {spawnSync} = require('node:child_process');
const root = process.argv[2];
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-pulse-isolation-'));
const work = path.join(tmp, 'project');
fs.mkdirSync(work);
const baseEnv = {...process.env, GIT_CONFIG_GLOBAL: path.join(tmp, 'no-git-config'),
  GIT_CONFIG_NOSYSTEM: '1', ZENSU_CONFIG_DIR: path.join(tmp, 'empty-cli'),
  ZENSU_API_URL: 'http://127.0.0.1:9', ZENSU_NO_UPDATE_CHECK: '1'};
for (const key of ['KIRO_HOME', 'ZENSU_PLUGIN_ROOT', 'CLAUDE_PLUGIN_ROOT', 'CODEX_PLUGIN_ROOT',
  'CLAUDE_PROJECT_DIR', 'ZENSU_SESSION_KEY', 'CODEX_THREAD_ID']) delete baseEnv[key];
let passed = 0, failed = 0, sequence = 0;
function check(label, test) {
  try { test(); passed++; console.log('  ok   ' + label); }
  catch (error) { failed++; console.error('  FAIL ' + label + ': ' + error.message); }
}
function fixture(pulse) {
  const dir = path.join(tmp, 'case-' + (++sequence));
  const home = path.join(dir, 'home');
  const profile = path.join(dir, 'profile with spaces');
  fs.mkdirSync(home, {recursive: true}); fs.mkdirSync(profile);
  const config = path.join(dir, 'config.json');
  fs.writeFileSync(config, JSON.stringify({hooks: {pulseSession: pulse}}));
  return {home, profile, pointer: path.join(home, '.zensu/plugin-root'),
    env: {...baseEnv, HOME: home, USERPROFILE: home, ZENSU_CONFIG: config}};
}
function run(f, override) {
  const env = {...f.env};
  if (override !== undefined) env.KIRO_HOME = override;
  const result = spawnSync('bash', [path.join(root, 'hooks/kiro/kiro-shim.sh'),
    'session-start-pulse.sh'], {env, cwd: work, input: '{}', encoding: 'utf8', timeout: 10000});
  assert.equal(result.status, 0, result.stderr || result.error?.message);
  return result.stdout;
}
function seed(f) {
  fs.mkdirSync(path.dirname(f.pointer));
  fs.writeFileSync(f.pointer, 'existing global runtime\n');
  fs.utimesSync(f.pointer, new Date('2001-01-01'), new Date('2001-01-01'));
  return {bytes: fs.readFileSync(f.pointer), mtime: fs.statSync(f.pointer).mtimeMs};
}
function unchanged(f, snapshot) {
  assert.deepEqual(fs.readFileSync(f.pointer), snapshot.bytes, 'global pointer bytes changed');
  assert.equal(fs.statSync(f.pointer).mtimeMs, snapshot.mtime, 'global pointer was touched');
}
function assertRuntime(f) {
  let target = fs.readFileSync(f.pointer, 'utf8').trim();
  if (process.platform === 'win32') {
    const result = spawnSync('cygpath', ['-w', target], {encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr); target = result.stdout.trim();
  }
  const identity = p => {
    const value = fs.realpathSync.native(p);
    return process.platform === 'win32' ? value.toLowerCase() : value;
  };
  assert.equal(identity(target), identity(root));
}
try {
  for (const args of [['init', '-q'], ['-c', 'user.name=Fixture', '-c',
    'user.email=fixture@example.test', '-c', 'commit.gpgsign=false', 'commit', '--allow-empty', '-qm', 'Fixture']]) {
    const result = spawnSync('git', args, {cwd: work, env: baseEnv, encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
  }
  for (const pulse of [false, true]) {
    check(`isolated profile preserves pointer bytes and mtime with pulse=${pulse}`, () => {
      const f = fixture(pulse), before = seed(f);
      for (let i = 0; i < 2; i++) { run(f, f.profile); unchanged(f, before); }
    });
    check(`isolated profile does not create global state with pulse=${pulse}`, () => {
      const f = fixture(pulse);
      run(f, f.profile);
      assert(!fs.existsSync(path.join(f.home, '.zensu')), 'global .zensu directory was created');
    });
    check(`normal profile refreshes pointer and remains idempotent with pulse=${pulse}`, () => {
      const f = fixture(pulse); seed(f);
      const output = run(f);
      assertRuntime(f);
      assert.equal(output.includes('pulse session ready'), pulse);
      const before = {bytes: fs.readFileSync(f.pointer), mtime: fs.statSync(f.pointer).mtimeMs};
      run(f); unchanged(f, before);
    });
  }
  check('explicit default KIRO_HOME also preserves the global pointer', () => {
    const f = fixture(false), before = seed(f);
    run(f, path.join(f.home, '.kiro')); unchanged(f, before);
  });
  check('empty KIRO_HOME retains normal pointer initialization', () => {
    const f = fixture(false); run(f, ''); assertRuntime(f);
  });
  if (process.platform !== 'win32') {
    check('isolated profile leaves a symlinked pointer and its target untouched', () => {
      const f = fixture(false), target = path.join(tmp, 'pointer-target');
      fs.writeFileSync(target, 'existing target\n');
      fs.mkdirSync(path.dirname(f.pointer)); fs.symlinkSync(target, f.pointer);
      const before = {bytes: fs.readFileSync(f.pointer), mtime: fs.statSync(f.pointer).mtimeMs};
      run(f, f.profile); unchanged(f, before);
      assert(fs.lstatSync(f.pointer).isSymbolicLink());
      assert.equal(fs.readlinkSync(f.pointer), target);
    });
  }
  console.log(`Result: ${passed} passed, ${failed} failed`);
  process.exitCode = failed ? 1 : 0;
} finally { fs.rmSync(tmp, {recursive: true, force: true}); }
NODE
