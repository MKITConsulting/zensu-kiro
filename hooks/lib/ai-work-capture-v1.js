'use strict';

// Explicit work goals, not session surveillance. No transcripts, code, diffs,
// credentials or local paths leave this process. A Stop is never acceptance.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const cp = require('node:child_process');
const goalScope = require('./ai-work-goal-scope-v1.js');
const recovery = require('./ai-work-recovery-v1.js');
const compatibility = require('./ai-work-preflight-v1.js');
const { isDeepStrictEqual } = require('node:util');
let deadline = Infinity;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;

function text(value, max) {
  return typeof value === 'string' && value.trim().length > 0 && value.length <= max && !/[\x00-\x1f\x7f]/.test(value);
}
function execute(command, args, cwd) {
  const env = { ...process.env };
  // Git hooks may export discovery variables belonging to another checkout.
  for (const key of Object.keys(env)) if (key.startsWith('GIT_')) delete env[key];
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new Error('Capture deadline reached; retry the same task');
  const r = cp.spawnSync(command, args, { cwd, env, encoding: 'utf8', timeout: Math.min(15000, remaining), maxBuffer: 1024 * 1024, windowsHide: true });
  if (r.error || r.status !== 0) throw new Error(`${command === 'git' ? 'Git' : 'CLI'} capture operation failed; capture is incomplete. Check personal OAuth login, permissions, server compatibility and connection, then retry the same task.`);
  return r.stdout.trim();
}
function cli(args, cwd) {
  const value = JSON.parse(execute('zensu', ['ai-work', ...args], cwd));
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid capture response');
  return value;
}
function location(workspace, session, create = false) {
  if (!text(workspace, 4096) || !/^awcv1_[0-9a-f]{64}$/.test(session)) throw new Error('A bound workspace and capture key are required');
  const root = fs.realpathSync(workspace);
  const gitDir = execute('git', ['rev-parse', '--absolute-git-dir'], root);
  const dir = path.join(gitDir, 'zensu-ai-work-v1');
  if (fs.existsSync(dir) && fs.lstatSync(dir).isSymbolicLink()) throw new Error('Unsafe capture directory');
  if (create) fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  return { root, dir, file: path.join(dir, `${session}.json`) };
}
function read(file) {
  if (!fs.existsSync(file)) return null;
  const st = fs.lstatSync(file);
  if (!st.isFile() || st.isSymbolicLink() || st.size > 98304) throw new Error('Unsafe capture state');
  const s = JSON.parse(fs.readFileSync(file, 'utf8'));
  if (s.schema !== 1 || !UUID.test(s.id) || !text(s.task, 160) || !text(s.title, 160) || !text(s.criteria, 160) || !text(s.apiUrl, 2048) || !SHA.test(s.startHead)) throw new Error('Invalid capture state');
  if (s.metadata && (!text(s.metadata.source, 32) || !text(s.metadata.sourceVersion, 64) || !['work', 'test'].includes(s.metadata.runKind))) throw new Error('Invalid capture metadata');
  if (s.pending && (!UUID.test(s.pending.id) || !Number.isInteger(s.pending.expectedVersion) || s.pending.expectedVersion < 1 || !/^commit:(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(s.pending.artifactRef) || s.pending.criteriaVersion !== s.criteria)) throw new Error('Invalid pending submission');
  if (s.pending?.reviewDetails) validateReviewDetails(s.pending.reviewDetails);
  return s;
}
function save(file, state) {
  const tmp = `${file}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state) + '\n', { flag: 'wx', mode: 0o600 });
  fs.renameSync(tmp, file);
}
function lock(file, fn) {
  const lockPath = `${file}.lock`;
  let fd;
  try { fd = fs.openSync(lockPath, 'wx', 0o600); } catch { throw new Error('Capture already running; retry after it finishes. A crash may leave a lock requiring inspection.'); }
  try { return fn(); } finally { fs.closeSync(fd); fs.unlinkSync(lockPath); }
}
function confirmedScope(context, reason = '') {
  if (context.ready !== true || !UUID.test(context.reportingUserId) || !UUID.test(context.organizationId)) throw new Error('Product confirmation was not verified; update the CLI and server');
  if (reason) {
    if (context.workScope !== 'cross_product' || context.productId) throw new Error('Invalid explicit cross-product context');
    return { workScope: 'cross_product', productId: null, crossProductReason: reason };
  }
  if (context.workScope !== 'product' || !UUID.test(context.productId)) throw new Error('A confirmed product binding is required');
  return { workScope: 'product', productId: context.productId, crossProductReason: '' };
}
function start(s, root) {
  if (!s.scope) throw new Error('Legacy capture has no confirmed scope; begin a new explicitly scoped goal');
  if (!s.scope.taskScope) throw new Error('Legacy capture has no feature goal scope; begin a new explicitly scoped goal');
  const context = cli(goalScope.contextArgs(s.scope), root);
  if (context.apiUrl !== s.apiUrl) throw new Error('Capture host changed; restore the original host or begin a new task');
  const scope = { ...confirmedScope(context, s.scope.crossProductReason), ...goalScope.confirm(context, goalScope.fromOptions({ ...(s.scope.featureId ? { feature: s.scope.featureId } : {}), ...(s.scope.featureRevisionId ? { 'feature-revision': s.scope.featureRevisionId } : {}), ...(s.scope.maintenanceReason ? { 'maintenance-reason': s.scope.maintenanceReason } : {}), ...(s.scope.crossProductReason ? { 'cross-product-reason': s.scope.crossProductReason } : {}) })) };
  if (JSON.stringify(scope) !== JSON.stringify(s.scope) || context.reportingUserId !== s.user || context.organizationId !== s.organization) throw new Error('Capture scope or account changed; capture incomplete, explicitly confirm a new goal');
  const metadata = s.metadata ? ['--source', s.metadata.source, '--source-version', s.metadata.sourceVersion, '--run-kind', s.metadata.runKind] : ['--legacy-metadata'];
  const scopeArgs = scope.productId ? ['--product', scope.productId] : ['--cross-product-reason', scope.crossProductReason];
  const result = cli(['start', '--id', s.id, '--title', s.title, ...metadata, ...scopeArgs, ...goalScope.startArgs(scope)], root);
  if (result.id !== s.id) throw new Error('Capture start identity mismatch');
}
function detail(s, root) {
  const d = cli(['get', s.id], root);
  if (d.id !== s.id || !Number.isInteger(d.version) || d.version < 1 || !UUID.test(d.reportingUserId) || !UUID.test(d.organizationId)) throw new Error('Capture detail identity mismatch');
  if (d.workScope !== s.scope.workScope || (d.productId ?? null) !== s.scope.productId || d.crossProductReason !== s.scope.crossProductReason) throw new Error('Capture product scope was not confirmed by the server');
  goalScope.assertSame(d, s.scope);
  if (s.metadata && (d.source !== s.metadata.source || d.sourceVersion !== s.metadata.sourceVersion || !['work', 'test'].includes(d.runKind))) throw new Error('Capture metadata was not confirmed; update the CLI and server');
  if (s.user && (s.user !== d.reportingUserId || s.organization !== d.organizationId)) throw new Error('Capture account changed');
  if (d.result && (!UUID.test(d.result.id) || typeof d.result.artifactRef !== 'string')) throw new Error('Invalid captured result');
  const review = new URL(d.reviewUrl);
  if (!['http:', 'https:'].includes(review.protocol) || review.username || review.password || review.searchParams.get('unit') !== s.id || (d.result && review.searchParams.get('result') !== d.result.id)) throw new Error('Invalid review link');
  s.user = d.reportingUserId; s.organization = d.organizationId;
  return d;
}
function checkCLI(root) { return compatibility.check(root, Math.max(0, Math.min(8000, deadline - Date.now()))); }

function preflight(options) {
  const { root, file } = location(options.workspace, options.session);
  if (compatibility.paused(file)) return { status: 'capture_disabled' };
  const support = checkCLI(root);
  if (support.status !== 'compatible') return support;
  const goal = goalScope.fromOptions(options);
  try {
    const context = cli(goalScope.contextArgs(goal), root);
    if (context.ready === false && context.workScope === 'unassigned') return { ...support, status: 'product_confirmation_required', reason: 'Ask once for the exact product and this goal\'s feature or maintenance scope before implementation. Bind only after explicit human confirmation; otherwise continue without capture.' };
    const scope = confirmedScope(context, options['cross-product-reason'] ?? '');
    if (!goal) return { ...support, status: 'feature_confirmation_required', productId: scope.productId, reason: 'Reuse the confirmed product. Ask once for this goal\'s exact feature or an explicit maintenance reason; otherwise continue without capture.' };
    goalScope.confirm(context, goal);
    return { ...support, status: 'ready', ...scope, ...goal };
  } catch {
    return { ...support, status: 'scope_unavailable', reason: 'Scope could not be verified. Check CLI authentication, access and server compatibility. No work was captured; coding can continue.' };
  }
}
function pause(options) {
  const { file } = location(options.workspace, options.session, true);
  return lock(file, () => compatibility.pause(file));
}
function begin(options) {
  const { root, file } = location(options.workspace, options.session, true);
  return lock(file, () => {
    let s = read(file);
    compatibility.paused(file); // Validate a local pause before any remote declaration.
    let recoveredReceipt;
    // An attempted goal change must never leave Stop reporting into the old goal.
    // Legacy receipts cannot submit; keep their original bytes for recovery.
    if (s && !recovery.isLegacy(s)) { s.capturePaused = true; save(file, s); }
    const runKind = options['run-kind'] ?? 'work';
    if (!['work', 'test'].includes(runKind)) throw new Error('Run kind must be work or test');
    const reason = options['cross-product-reason'] ?? '';
    if (Object.hasOwn(options, 'cross-product-reason') && !text(reason, 500)) throw new Error('An explicit cross-product reason is required');
    if (!text(options.task, 160) || !text(options.title, 160) || !text(options.criteria, 160)) throw new Error('Task, objective and criteria version are required');
    const goal = goalScope.fromOptions(options);
    if (s && !goal) return { status: 'skipped_missing_feature', reason: 'Choose the feature or explicit exception for this goal. Development can continue without capture.' };
    if (s && s.task === options.task && goal) goalScope.assertSame(s.scope ?? {}, goal);
    if (s && s.task === options.task && s.scope && s.scope.crossProductReason !== reason) throw new Error('A task retry must keep its product scope; use a new task key');
    if (s && s.task === options.task && (s.title !== options.title || s.criteria !== options.criteria)) throw new Error('A task retry must keep its objective and criteria version; use a new task key for a changed goal');
    if (s && s.task === options.task && ((s.metadata && (s.metadata.runKind !== runKind || s.metadata.source !== options.source)) || (!s.metadata && Object.hasOwn(options, 'run-kind')))) throw new Error('A task retry must keep its run purpose and source; use a new task key');
    const support = checkCLI(root);
    if (support.status !== 'compatible') return support;
    if (!s || s.task !== options.task) {
      if (!text(options.source, 32) || !text(options.sourceVersion, 64)) throw new Error('A reporter source and version are required');
      if (s && s.pending && !recovery.isLegacy(s)) throw new Error('Previous submission is still pending; retry it or explicitly archive it with zensu ai-work recover before starting another task');
      const head = execute('git', ['rev-parse', 'HEAD'], root);
      if (!SHA.test(head)) throw new Error('A committed starting revision is required');
      const context = cli(goalScope.contextArgs(goal), root);
      if (!reason && context.ready === false && context.workScope === 'unassigned') return { status: 'skipped_unassigned', reason: 'Explicitly confirm the repository product with zensu ai-work bind --product <id> --confirm. Development can continue without capture.' };
      if (!goal) return { status: 'skipped_missing_feature', reason: 'Explicitly choose this goal\'s feature or a maintenance reason. Development can continue without capture.' };
      const scope = { ...confirmedScope(context, reason), ...goalScope.confirm(context, goal) };
      if (!text(context.apiUrl, 2048)) throw new Error('Invalid capture host');
      // Do not detach history until the replacement goal is explicitly scoped
      // and confirmed. A failed archive leaves the old active receipt intact.
      if (recovery.isLegacy(s)) recoveredReceipt = recovery.archive(file);
      s = { schema: 1, scope, user: context.reportingUserId, organization: context.organizationId, metadata: { source: options.source, sourceVersion: options.sourceVersion, runKind }, id: crypto.randomUUID(), task: options.task, title: options.title, criteria: options.criteria, apiUrl: context.apiUrl, startHead: head };
      // Persist before the first request, including on a lost response.
      save(file, s);
    }
    start(s, root);
    const d = detail(s, root); delete s.capturePaused; save(file, s);
    compatibility.resume(file);
    return { status: 'recording', id: s.id, reviewUrl: d.reviewUrl, ...(recoveredReceipt ? { recoveredReceipt } : {}) };
  });
}
function validateReviewDetails(d) {
  const object = (value, keys) => value && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).every(k => keys.includes(k));
  const prose = (value, max, required = true) => typeof value === 'string' && Buffer.from(value, 'utf8').toString('utf8') === value && [...value].length <= max && (!required || value.trim()) && !/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]/.test(value);
  const invalid = () => { throw new Error('Invalid explicit review details'); };
  if (!object(d, ['summary', 'artifactUrl', 'acceptanceCriteria', 'evidence', 'limitations']) || !prose(d.summary, 4000) || (d.limitations !== undefined && !prose(d.limitations, 4000, false)) || !Array.isArray(d.acceptanceCriteria) || d.acceptanceCriteria.length > 20 || !Array.isArray(d.evidence) || d.evidence.length > 20 || Buffer.byteLength(JSON.stringify(d).replace(/[<>&\u2028\u2029]/g, c => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'))) > 32768) invalid();
  const validateURL = value => {
    if (value === undefined || value === '') return;
    if (!prose(value, 2000) || /[\s\\]/.test(value) || !/^https?:\/\//.test(value)) invalid();
    const u = new URL(value);
    if (!u.hostname || u.username || u.password) invalid();
  };
  validateURL(d.artifactUrl);
  for (const c of d.acceptanceCriteria) if (!object(c, ['text', 'status']) || !prose(c.text, 1000) || !['met', 'not_met', 'not_checked'].includes(c.status)) invalid();
  for (const e of d.evidence) {
    if (!object(e, ['label', 'url', 'description']) || !prose(e.label, 200) || /[\n\r\t]/.test(e.label) || (e.url !== undefined && typeof e.url !== 'string') || (e.description !== undefined && !prose(e.description, 2000, false)) || (!e.url && !e.description?.trim())) invalid();
    validateURL(e.url);
  }
}

function checkpoint(options) {
  const { root, file } = location(options.workspace, options.session);
  if (compatibility.paused(file)) return { status: 'capture_disabled' };
  if (!fs.existsSync(file)) return { status: 'not_started' };
  return lock(file, () => {
    if (compatibility.paused(file)) return { status: 'capture_disabled' };
    const s = read(file);
    if (s.capturePaused) return { status: 'skipped_missing_feature', reason: 'Resume with an explicit valid goal before capture continues.' };
    if (!recovery.isLegacy(s)) {
      const support = checkCLI(root);
      if (support.status !== 'compatible') return support;
    }
    start(s, root);
    let d = detail(s, root);
    let reviewDetails;
    if (Object.hasOwn(options, 'review-file')) {
      if (typeof options['review-file'] !== 'string' || options['review-file'] === '') throw new Error('Unsafe review file');
      const input = path.resolve(root, options['review-file']);
      const st = fs.lstatSync(input);
      if (!st.isFile() || st.isSymbolicLink() || st.size > 32768) throw new Error('Unsafe review file');
      reviewDetails = JSON.parse(fs.readFileSync(input, 'utf8'));
      validateReviewDetails(reviewDetails);
      // Match the typed CLI/server representation of optional empty strings.
      if (reviewDetails.limitations === '') delete reviewDetails.limitations;
      if (reviewDetails.artifactUrl === '') delete reviewDetails.artifactUrl;
      for (const evidence of reviewDetails.evidence) {
        if (evidence.url === '') delete evidence.url;
        if (evidence.description === '') delete evidence.description;
      }
    }
    if (s.pending && reviewDetails && !isDeepStrictEqual(s.pending.reviewDetails, reviewDetails)) throw new Error('Pending submission has different review details; retry the frozen submission first');
    if (!s.pending) {
      const head = execute('git', ['rev-parse', 'HEAD'], root);
      if (!SHA.test(head)) throw new Error('Invalid commit revision');
      if (execute('git', ['status', '--porcelain', '--untracked-files=normal'], root)) return { status: 'uncommitted_work', id: s.id };
      if (head === s.startHead) return { status: 'no_new_commit', id: s.id };
      if (d.result && d.result.artifactRef === `commit:${head}` && d.result.criteriaVersion === s.criteria && (!reviewDetails || isDeepStrictEqual(d.result.reviewDetails, reviewDetails))) return { status: 'already_submitted', id: s.id, reviewUrl: d.reviewUrl };
      s.pending = { id: crypto.randomUUID(), expectedVersion: d.version, artifactRef: `commit:${head}`, criteriaVersion: s.criteria, ...(reviewDetails ? { reviewDetails } : {}) };
      save(file, s);
    }
    const p = s.pending;
    const args = ['submit', s.id, '--event-id', p.id, '--expected-version', String(p.expectedVersion), '--artifact', p.artifactRef, '--criteria-version', p.criteriaVersion];
    // Retry from the frozen private receipt, never from a changed source file.
    const reviewFile = `${file}.${crypto.randomUUID()}.review.json`;
    let result;
    try {
      if (p.reviewDetails) {
        fs.writeFileSync(reviewFile, JSON.stringify(p.reviewDetails), { flag: 'wx', mode: 0o600 });
        args.push('--review-file', reviewFile);
      }
      result = cli(args, root);
    } finally {
      if (fs.existsSync(reviewFile)) fs.unlinkSync(reviewFile);
    }
    if (result.id !== p.id) throw new Error('Submission identity mismatch');
    d = detail(s, root);
    if (p.reviewDetails) {
      const recorded = d.result?.id === p.id ? d.result : d.events?.find(e => e.id === p.id);
      if (!isDeepStrictEqual(recorded?.reviewDetails, p.reviewDetails)) throw new Error('Review details were not confirmed by the server; capture remains incomplete');
    }
    delete s.pending; save(file, s);
    return { status: 'submitted_for_review', id: s.id, reviewUrl: d.reviewUrl };
  });
}

// Native adapters own identity and transport. The time budget covers the entire
// checkpoint, so an unavailable service cannot consume the host Stop deadline.
function run(action, options, budgetMs = 20000) {
  const operations = { begin, checkpoint, preflight, pause };
  if (!Object.hasOwn(operations, action) || !Number.isInteger(budgetMs) || budgetMs < 1 || budgetMs > 60000) throw new Error('Invalid capture operation');
  const previous = deadline;
  deadline = Math.min(previous, Date.now() + budgetMs);
  try { return operations[action](options); }
  finally { deadline = previous; }
}
module.exports = { begin, checkpoint, preflight, pause, run };
