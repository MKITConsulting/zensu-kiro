#!/usr/bin/env bash
# Exercise persisted installer output under separate user/workspace boundaries.
# Native V3 loading is a separate, opt-in integration check (see the migration guide).
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node - "$ROOT" <<'NODE'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const root = process.argv[2];
const tmp = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'zensu-prompt-scope-')));
const home = path.join(tmp, 'home');
const workspace = path.join(tmp, 'workspace');
fs.mkdirSync(home); fs.mkdirSync(workspace);
const env = {...process.env, HOME: home, USERPROFILE: home,
  KIRO_HOME: path.join(home, '.kiro'),
  ZENSU_CONFIG_DIR: path.join(tmp, 'empty-cli'), ZENSU_API_URL: 'http://127.0.0.1:9',
  ZENSU_NO_UPDATE_CHECK: '1'};
const hash = data => crypto.createHash('sha256').update(data).digest('hex');
const names = ['zensu', 'zensu-plm', 'zensu-code-reviewer', 'zensu-review-aspect'];
// Manifest keys stay POSIX on Git Bash, including virtual mounts such as /tmp.
// Use Git Bash's own mount translation in one batch, cached across lookups.
const nativePaths = new Map();
const native = p => nativePaths.get(p) || p;
// Git Bash and Windows Node can expose different casing and short/long path
// aliases for the same temp directory. Compare actual filesystem identities.
const identity = p => {
  const resolved = fs.realpathSync.native(native(p));
  return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
};
const keyFor = (manifest, target) => {
  const keys = Object.keys(manifest.files);
  if (process.platform === 'win32') {
    const missing = keys.filter(p => p.startsWith('/') && !nativePaths.has(p));
    if (missing.length) {
      const result = spawnSync('cygpath', ['-w', '-f', '-'], {
        env, input: missing.join('\n') + '\n', encoding: 'utf8', timeout: 10000,
      });
      assert.equal(result.status, 0, result.stderr || result.error?.message);
      const translated = result.stdout.trim().split(/\r?\n/);
      assert.equal(translated.length, missing.length);
      missing.forEach((p, i) => nativePaths.set(p, translated[i]));
    }
  }
  const expected = identity(target);
  return keys.find(p => {
    try { return identity(p) === expected; } catch (_) { return false; }
  });
};
const read = p => fs.readFileSync(p);
const json = p => JSON.parse(read(p));
const save = (p, value) => fs.writeFileSync(p, JSON.stringify(value, null, 2) + '\n');
let checks = 0;
function check(label, action) { action(); checks++; console.log('  ok   ' + label); }
function install(scope, extra = [], expected = 0) {
  const result = spawnSync('bash', [path.join(root, 'install.sh'), '--scope', scope,
    '--no-default', ...extra], {cwd: workspace, env, encoding: 'utf8', timeout: 180000});
  assert.equal(result.status, expected, result.stderr || result.error?.message || result.stdout);
  return result.stdout + result.stderr;
}
const scopes = [];
try {
  for (const scope of ['user', 'workspace']) {
    install(scope);
    const boundary = path.join(scope === 'user' ? home : workspace, '.kiro');
    const manifestPath = scope === 'user' ? path.join(home, '.kiro/zensu/manifest.json') :
      path.join(boundary, 'zensu-manifest.json');
    const manifest = json(manifestPath);
    const configs = names.map(n => path.join(boundary, 'agents', n + '.json'));
    const prompts = [];
    for (const [i, name] of names.entries()) {
      check(scope + '/' + name + ': canonical contained prompt and manifest hashes', () => {
        const config = json(configs[i]);
        const filename = (name === 'zensu' ? 'zensu-orchestrator' : name) + '.md';
        assert.equal(config.prompt, 'file://./zensu-prompts/' + filename);
        const relative = config.prompt.slice('file://'.length);
        assert(!path.isAbsolute(relative));
        const target = fs.realpathSync(path.resolve(path.dirname(configs[i]), relative));
        const within = path.relative(fs.realpathSync(boundary), target);
        assert(within && !within.startsWith('..') && !path.isAbsolute(within));
        assert.deepEqual(read(target), read(path.join(root, 'agents/prompts', filename)));
        const promptKey = keyFor(manifest, target);
        assert(promptKey, JSON.stringify({target, manifestPaths: Object.keys(manifest.files)
          .filter(p => p.includes('zensu-prompts'))}));
        assert.equal(manifest.files[promptKey], hash(read(target)));
        assert.equal(manifest.files[keyFor(manifest, configs[i])], hash(read(configs[i])));
        if (name === 'zensu') assert(config.resources.includes(config.prompt));
        prompts.push(target);
      });
    }
    const snapshots = [...configs, ...prompts].map(p => [p, read(p), fs.statSync(p).mtimeMs]);
    install(scope);
    check(scope + ': reinstall is a byte and mtime NOOP', () => {
      for (const [p, bytes, mtime] of snapshots) {
        assert.deepEqual(read(p), bytes); assert.equal(fs.statSync(p).mtimeMs, mtime);
      }
    });
    // Seed legacy installer output with the previous absolute prompt location.
    // Migration metadata below is synthetic: these assertions test ownership,
    // not Kiro's migration algorithm (the native acceptance run covers that).
    const previous = json(manifestPath);
    const runtimeManifest = json(path.join(home, '.kiro/zensu/manifest.json'));
    const runtimePromptKey = keyFor(runtimeManifest,
      path.join(home, '.kiro/zensu/prompts/zensu-orchestrator.md'));
    assert(runtimePromptKey, 'legacy runtime prompt must be recorded');
    // Reproduce the installer's path spelling, including Git Bash's /c/ form.
    const runtimeRoot = runtimePromptKey.slice(0, runtimePromptKey.lastIndexOf('/prompts/'));
    const kept = [];
    for (const [i, p] of configs.entries()) {
      const legacy = JSON.parse(fs.readFileSync(path.join(root, 'agents/cli', names[i] + '.json'), 'utf8')
        .replaceAll('__ZENSU_HOME__', runtimeRoot)
        .replaceAll('file://./zensu-prompts/', 'file://' + runtimeRoot + '/prompts/'));
      save(p, legacy);
      const key = keyFor(previous, p);
      previous.files[key] = hash(read(p));
      fs.copyFileSync(p, p + '.bak');
      if (i > 0) {
        legacy.kiroUpgrade = {revision: 2, fingerprint: 'synthetic-migration', source: 'synthetic-source'};
        if (i > 1) legacy.description = 'User-owned configuration after migration.';
        save(p, legacy);
        kept.push([p, read(p), read(p + '.bak'), previous.files[key]]);
      }
      if (i === 3) delete previous.files[key]; // Foreign config with a plausible backup.
    }
    fs.appendFileSync(prompts[0], '\nUser-owned prompt customization.\n');
    const edited = read(prompts[0]);
    fs.appendFileSync(prompts[1], '\nPre-existing foreign prompt.\n');
    delete previous.files[keyFor(previous, prompts[1])];
    const foreign = read(prompts[1]);
    save(manifestPath, previous);
    const legacyPrompt = path.join(home, '.kiro/zensu/prompts/zensu-orchestrator.md');
    const legacyBytes = read(legacyPrompt);
    fs.appendFileSync(legacyPrompt, '\nCustomized legacy prompt still in use.\n');
    const customizedLegacy = read(legacyPrompt);
    const legacyConfig = read(configs[0]);
    const guarded = install(scope);
    check(scope + ': clean legacy config keeps using its customized legacy prompt', () => {
      assert(guarded.includes('customized legacy prompt'));
      assert.deepEqual(read(configs[0]), legacyConfig);
      assert.deepEqual(read(legacyPrompt), customizedLegacy);
      const current = json(manifestPath);
      assert.equal(current.files[keyFor(current, configs[0])], hash(legacyConfig));
    });
    fs.writeFileSync(legacyPrompt, legacyBytes);
    const out = install(scope);
    check(scope + ': untouched legacy config upgrades; migrated and foreign configs stay intact', () => {
      assert.equal(json(configs[0]).prompt, 'file://./zensu-prompts/zensu-orchestrator.md');
      assert(out.includes('docs/kiro-v3-migration.md'));
      for (const [p, bytes, backup, oldHash] of kept) {
        assert.deepEqual(read(p), bytes); assert.deepEqual(read(p + '.bak'), backup);
        if (p !== configs[3]) assert.equal(hash(backup), oldHash);
      }
    });
    install(scope);
    check(scope + ': repeated reinstalls preserve ownership and edits, despite matching backup hashes', () => {
      const current = json(manifestPath);
      for (const [p, bytes, backup, oldHash] of kept) {
        assert.deepEqual(read(p), bytes); assert.deepEqual(read(p + '.bak'), backup);
        if (p === configs[3]) assert.equal(keyFor(current, p), undefined);
        else assert.equal(current.files[keyFor(current, p)], oldHash);
      }
      assert.deepEqual(read(prompts[0]), edited);
      assert.deepEqual(read(prompts[1]), foreign);
      assert.equal(current.files[keyFor(current, prompts[0])], manifest.files[keyFor(manifest, prompts[0])]);
      assert.equal(keyFor(current, prompts[1]), undefined);
    });
    scopes.push({scope, configs, prompts, kept, edited, foreign, manifestPath});
  }
  for (const item of scopes.slice().reverse()) {
    const {scope, configs, prompts, kept, edited, foreign} = item;
    const other = scopes.find(s => s !== item);
    const otherFiles = [...other.configs, ...other.prompts, other.manifestPath,
      path.join(home, '.kiro/zensu/prompts/zensu-orchestrator.md')]
      .filter(p => fs.existsSync(p)).map(p => [p, read(p)]);
    install(scope, ['--uninstall']);
    check(scope + ': uninstall removes owned files and preserves edits, foreign files, backups and other scope', () => {
      assert(!fs.existsSync(configs[0]));
      assert.deepEqual(read(prompts[0]), edited); assert.deepEqual(read(prompts[1]), foreign);
      for (const p of prompts.slice(2)) assert(!fs.existsSync(p));
      for (const [p, bytes, backup] of kept) {
        assert.deepEqual(read(p), bytes); assert.deepEqual(read(p + '.bak'), backup);
      }
      for (const [p, bytes] of otherFiles) {
        // User uninstall owns the shared runtime; workspace uninstall does not.
        if (scope === 'user' && p.includes(path.join(home, '.kiro/zensu/'))) continue;
        assert.deepEqual(read(p), bytes);
      }
    });
  }
  if (process.platform !== 'win32') {
    const dir = path.join(workspace, '.kiro/agents/zensu-prompts');
    const outside = path.join(tmp, 'outside-prompts');
    fs.renameSync(dir, outside); fs.symlinkSync(outside, dir);
    const sentinel = path.join(outside, 'zensu-orchestrator.md');
    const bytes = read(sentinel);
    check('symlinked prompt directory is refused without modifying its target', () => {
      assert(install('workspace', [], 1).includes('symlink in agent prompt path'));
      assert.deepEqual(read(sentinel), bytes);
    });
  }
  console.log(`Result: ${checks} passed, 0 failed`);
} finally { fs.rmSync(tmp, {recursive: true, force: true}); }
NODE
