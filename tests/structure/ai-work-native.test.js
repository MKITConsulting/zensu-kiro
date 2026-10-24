'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const cp = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const capture = require('../../hooks/kiro/ai-work');
function fixture(t) {
  const project = fs.mkdtempSync(path.join(os.tmpdir(), 'kiro-capture-native-'));
  assert.equal(cp.spawnSync('git', ['init', '-q', project]).status, 0);
  t.after(() => fs.rmSync(project, { recursive: true, force: true }));
  return project;
}
test('legacy conversations receive independent keys and never consult the current-session pointer', t => {
  const cwd = fixture(t);
  fs.mkdirSync(path.join(cwd, '.zensu/state'), { recursive: true });
  fs.writeFileSync(path.join(cwd, '.zensu/state/session-id-current.txt'), 'another-user-session');
  const first = capture.initialize({ cwd }), second = capture.initialize({ cwd });
  assert.notEqual(first.key, second.key); assert.equal(first.identity, 'conversation-key');
  assert.deepEqual(capture.read(cwd, first.key), first);
  assert.equal(capture.stop({ cwd }).status, 'host_session_unavailable');
  assert.match(capture.primer(first), /automatic Stop capture is unavailable/);
});
test('native session payloads are stable and Stop does not create a goal', t => {
  const cwd = fixture(t), payload = { cwd, session_id: 'real-native-session' };
  const first = capture.initialize(payload), again = capture.initialize(payload);
  assert.deepEqual(again, first); assert.equal(first.identity, 'native');
  assert.equal(capture.stop(payload).status, 'not_started');
  assert.equal(fs.existsSync(path.join(cwd, '.git/zensu-ai-work-v1')), false);
  assert.equal(capture.stop({ cwd, session_id: 'another-session' }).status, 'not_started');
});
test('child and malformed native identities never fall back to a main conversation key', t => {
  const cwd = fixture(t);
  for (const fields of [{ agent_id: '' }, { agent_type: 'reviewer' }, { parentAgentId: null }, { isChild: true }]) {
    assert.throws(() => capture.initialize({ cwd, ...fields }), /main conversation/);
    assert.equal(capture.stop({ cwd, ...fields }).status, 'child_ignored');
  }
  for (const session_id of ['', null, 'bad\nvalue']) assert.throws(() => capture.initialize({ cwd, session_id }), /native identity/);
  assert.equal(fs.existsSync(path.join(cwd, '.git/zensu-ai-work-bindings-v1')), false);
});
test('capture keys cannot borrow another worktree or a symlinked binding', t => {
  const cwd = fixture(t), other = fixture(t), binding = capture.initialize({ cwd });
  assert.throws(() => capture.read(other, binding.key));
  assert.throws(() => capture.run('begin', ['--capture-key', binding.key, '--workspace', other], cwd), /Invalid/);
  const file = path.join(cwd, '.git/zensu-ai-work-bindings-v1', binding.key + '.json');
  fs.renameSync(file, file + '.saved'); fs.symlinkSync(file + '.saved', file);
  assert.throws(() => capture.read(cwd, binding.key), /Unsafe/);
});
test('main helper uses only its issued key and refuses decision operations', t => {
  const cwd = fixture(t), binding = capture.initialize({ cwd });
  assert.equal(capture.run('checkpoint', ['--capture-key', binding.key], cwd).status, 'not_started');
  for (const action of ['accept', 'revoke', 'assign']) assert.throws(() => capture.run(action, ['--capture-key', binding.key], cwd), /Invalid capture operation/);
  assert.throws(() => capture.run('checkpoint', ['--capture-key', binding.key, '--title', 'invented'], cwd), /only the capture key/);
});
test('the actual Kiro shim injects the primer and handles malformed input without exposing it', t => {
  const cwd = fixture(t);
  const call = (script, payload) => cp.spawnSync('bash', [path.join(root, 'hooks/kiro/kiro-shim.sh'), script], { cwd, input: typeof payload === 'string' ? payload : JSON.stringify(payload), encoding: 'utf8' });
  const start = call('session-start-ai-work.sh', { cwd, session_id: 'native-main' });
  assert.equal(start.status, 0); assert.match(start.stdout, /captureKey=awcv1_[0-9a-f]{64}/);
  assert.match(start.stdout, /Identity mode=native/); assert.doesNotMatch(start.stdout, /hookSpecificOutput/);
  assert.equal(call('stop-ai-work-capture.sh', { cwd, session_id: 'native-main' }).stdout, '');
  const malformed = call('stop-ai-work-capture.sh', 'private-input-invalid-json');
  assert.equal(malformed.status, 0); assert.match(malformed.stderr, /capture incomplete/);
  assert.doesNotMatch(malformed.stderr + malformed.stdout, /private-input/);
});
test('native prompt initializes without agentSpawn and legacy prompts never rotate a key', t => {
  const cwd = fixture(t);
  const call = payload => cp.spawnSync('bash', [path.join(root, 'hooks/kiro/kiro-shim.sh'), 'user-prompt-ai-work.sh'], { cwd, input: JSON.stringify(payload), encoding: 'utf8' });
  assert.equal(call({ cwd }).stdout, '');
  assert.equal(fs.existsSync(path.join(cwd, '.git/zensu-ai-work-bindings-v1')), false);
  const first = call({ cwd, session_id: 'native-lazy' });
  assert.equal(first.status, 0); assert.match(first.stdout, /Identity mode=native/);
  assert.equal(call({ cwd, session_id: 'native-lazy' }).stdout, first.stdout);
  assert.equal(fs.readdirSync(path.join(cwd, '.git/zensu-ai-work-bindings-v1')).length, 1);
  assert.equal(call({ cwd, session_id: 'native-lazy', agent_id: 'child' }).stdout, '');
});
