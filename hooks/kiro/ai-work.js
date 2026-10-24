#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const capture = require('../lib/ai-work-capture-v1.js');
const KEY = /^awcv1_[0-9a-f]{64}$/;
const INCOMPLETE = 'Zensu AI work capture incomplete. No acceptance was recorded. Check the capture key from this conversation, personal CLI OAuth, prerequisites and connection; retry the same goal.';
function child(payload) {
  return ['agent_id', 'agent_type', 'agentId', 'agentType', 'parent_session_id', 'parentAgentId'].some(k => Object.hasOwn(payload, k)) || payload.isChild === true;
}
function key(id) {
  if (typeof id !== 'string' || !id.trim() || id.length > 512 || /[\x00-\x1f\x7f]/.test(id)) throw new Error('Missing native identity');
  return 'awcv1_' + crypto.createHash('sha256').update('zensu.ai-work.v1\0kiro\0' + id).digest('hex');
}
function location(workspace) {
  const env = { ...process.env };
  for (const name of Object.keys(env)) if (name.startsWith('GIT_')) delete env[name];
  const result = cp.spawnSync('git', ['rev-parse', '--absolute-git-dir'], { cwd: workspace, env, encoding: 'utf8', timeout: 3000, maxBuffer: 65536 });
  if (result.error || result.status !== 0) throw new Error('Capture needs a Git worktree');
  const directory = path.join(result.stdout.trim(), 'zensu-ai-work-bindings-v1');
  if (fs.existsSync(directory) && (!fs.lstatSync(directory).isDirectory() || fs.lstatSync(directory).isSymbolicLink())) throw new Error('Unsafe capture binding directory');
  return directory;
}
function read(workspace, captureKey) {
  if (!KEY.test(captureKey)) throw new Error('Use the key issued for this conversation');
  const file = path.join(location(workspace), captureKey + '.json');
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 2048) throw new Error('Unsafe capture binding');
  const value = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (value.schema !== 1 || value.key !== captureKey || !['native', 'conversation-key'].includes(value.identity)) throw new Error('Invalid capture binding');
  return value;
}
function initialize(payload) {
  if (child(payload)) throw new Error('Only the main conversation may initialize capture');
  const native = Object.hasOwn(payload, 'session_id');
  const captureKey = key(native ? 'native:' + validNative(payload.session_id) : 'local:' + crypto.randomUUID());
  const value = { schema: 1, key: captureKey, identity: native ? 'native' : 'conversation-key' };
  const directory = location(payload.cwd);
  if (!fs.existsSync(directory)) fs.mkdirSync(directory, { mode: 0o700 });
  const file = path.join(directory, captureKey + '.json');
  try { fs.writeFileSync(file, JSON.stringify(value) + '\n', { flag: 'wx', mode: 0o600 }); }
  catch (e) { if (e.code !== 'EEXIST') throw e; read(payload.cwd, captureKey); }
  return value;
}
function validNative(id) { key(id); return id; }
function primer(binding) {
  const helper = JSON.stringify(path.resolve(__dirname, 'ai-work.js'));
  return `Zensu AI work capture: retain captureKey=${binding.key} only in this conversation. Identity mode=${binding.identity}. For an authorized implementation goal, automatically run node ${helper} begin --capture-key ${binding.key} --task <stable-goal-key> --title <agreed-objective> --criteria <criteria-version-or-digest>. Quote each value; reuse them on retries. This applies in direct mode too; startup, greetings and read-only questions create no work. After the final clean commit run node ${helper} checkpoint --capture-key ${binding.key} and include its exact reviewUrl. Personal CLI OAuth identifies the reporting account; a local conversation key is not proof of native host identity or authorship. Never borrow a project current-session pointer or another conversation key. ${binding.identity === 'native' ? 'Stop can retry this exact native session.' : 'This host supplied no session ID: automatic Stop capture is unavailable; the agent must checkpoint before handoff.'} Capture failures stay visible without blocking coding. Human acceptance and revocation remain web-only; a commit or merge never approves a result.`;
}
function run(action, args, workspace = process.cwd()) {
  const values = {};
  for (let i = 0; i < args.length; i += 2) {
    const name = args[i];
    if (!['--capture-key', '--task', '--title', '--criteria'].includes(name) || typeof args[i + 1] !== 'string' || Object.hasOwn(values, name.slice(2))) throw new Error('Invalid capture arguments');
    values[name.slice(2)] = args[i + 1];
  }
  if (action === 'checkpoint' && Object.keys(values).some(k => k !== 'capture-key')) throw new Error('Checkpoint accepts only the capture key');
  const binding = read(workspace, values['capture-key']);
  return capture.run(action, { workspace, session: binding.key, task: values.task, title: values.title, criteria: values.criteria }, 20000);
}
function stop(payload) {
  if (child(payload)) return { status: 'child_ignored' };
  if (!Object.hasOwn(payload, 'session_id')) return { status: 'host_session_unavailable', message: 'This host supplies no session ID; the agent checkpoint is required. No project session pointer was used.' };
  const captureKey = key('native:' + validNative(payload.session_id));
  const directory = location(payload.cwd);
  if (!fs.existsSync(path.join(directory, captureKey + '.json'))) return { status: 'not_started' };
  return run('checkpoint', ['--capture-key', captureKey], payload.cwd);
}
function main(argv) {
  const [action, ...args] = argv;
  if (action === 'session') {
    if (args.length) throw new Error('Session initialization takes no selectors');
    const binding = initialize({ cwd: process.cwd() });
    process.stdout.write(JSON.stringify({ ...binding, instructions: primer(binding) }) + '\n');
    return;
  }
  if (['hook-start', 'hook-prompt', 'hook-stop'].includes(action)) {
    const raw = fs.readFileSync(0);
    if (raw.length > 1024 * 1024) throw new Error('Oversized hook input');
    const payload = JSON.parse(raw.toString('utf8'));
    if (child(payload)) return;
    // Modern CLI hosts need not emit agentSpawn. A native identity makes lazy
    // prompt initialization idempotent; legacy prompts never mint another key.
    if (action === 'hook-prompt' && !Object.hasOwn(payload, 'session_id')) return;
    if (action !== 'hook-stop') process.stdout.write(JSON.stringify({ hookSpecificOutput: { additionalContext: primer(initialize(payload)) } }) + '\n');
    else {
      const result = stop(payload);
      if (result.status !== 'not_started') process.stdout.write(`Zensu AI work capture: ${JSON.stringify(result)}. Submission is not acceptance.\n`);
    }
    return;
  }
  process.stdout.write(JSON.stringify(run(action, args)) + '\n');
}
if (require.main === module) {
  try { main(process.argv.slice(2)); } catch {
    process.stderr.write(INCOMPLETE + '\n');
    process.exitCode = ['hook-start', 'hook-prompt', 'hook-stop'].includes(process.argv[2]) ? 0 : 1;
  }
}
module.exports = { key, child, initialize, read, primer, run, stop, INCOMPLETE };
