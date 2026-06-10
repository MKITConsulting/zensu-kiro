// promptfoo custom provider — drives a real `kiro-cli chat --no-interactive`
// per test case.
//
// Isolation model: PROJECT-level sandboxes only. Relocating KIRO_HOME/HOME
// also relocates kiro-cli's auth state (verified: sandboxed runs prompt a
// fresh browser login), so the provider instead performs a REAL user-level
// `install.sh --scope user --no-default` (idempotent; installing the plugin
// is the port's end state anyway) and isolates each test in a throwaway
// project cwd. Project-local artifacts (.zensu state/logs, payload dumps)
// are copied to .artifacts/<test label>; ~/.zensu/plugin-root is captured
// for the B6 assert. Variant agents (zensu-dump) land in the real
// ~/.kiro/agents — the runner removes them after the suite.
// Auth: the developer's logged-in kiro-cli session or KIRO_API_KEY.
import { execFileSync, execFile } from "node:child_process";
import { mkdtempSync, mkdirSync, cpSync, existsSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PF_ROOT = resolve(HERE, "..");          // tests/promptfoo
const REPO_ROOT = resolve(PF_ROOT, "../.."); // repo root

export default class KiroCliProvider {
  constructor(options = {}) {
    this.providerId = options.id || "kiro-cli";
    this.config = options.config || {};
  }

  id() {
    return this.providerId;
  }

  async callApi(prompt, context = {}) {
    const vars = (context && context.vars) || {};
    const label = String(vars.label || vars.scenario || "default").replace(/[^a-z0-9-]/gi, "-");
    const agent = String(vars.agent || this.config.agent || "zensu");
    const timeoutMs = Number(vars.timeoutMs || this.config.timeoutMs || 300000);

    const sandbox = mkdtempSync(join(tmpdir(), "zensu-kiro-eval-"));
    const home = process.env.HOME;
    const cwd = join(sandbox, "project");
    mkdirSync(cwd, { recursive: true });

    if (vars.fixture) {
      const fixture = join(PF_ROOT, "scenarios", "fixtures", String(vars.fixture));
      if (existsSync(fixture)) cpSync(fixture, cwd, { recursive: true });
    }

    const env = {
      ...process.env,
      ZENSU_EVAL_SANDBOX: sandbox,
    };

    try {
      execFileSync("bash", [join(REPO_ROOT, "install.sh"), "--scope", "user", "--no-default"], {
        env,
        cwd: REPO_ROOT,
        stdio: "pipe",
        timeout: 120000,
      });
    } catch (e) {
      return { output: "", error: `install.sh failed in sandbox: ${e.message}` };
    }

    if (vars.scenario) {
      const setup = join(PF_ROOT, "scenarios", String(vars.scenario), "setup.sh");
      if (existsSync(setup)) {
        try {
          execFileSync("bash", [setup], { env, cwd, stdio: "pipe", timeout: 60000 });
        } catch (e) {
          return { output: "", error: `scenario setup failed: ${e.message}` };
        }
      }
    }

    const args = ["chat", "--no-interactive", "--trust-all-tools", "--agent", agent, prompt];
    const run = () =>
      new Promise((resolveRun) => {
        execFile("kiro-cli", args, { env, cwd, timeout: timeoutMs, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) => {
          resolveRun({ err, stdout: String(stdout || ""), stderr: String(stderr || "") });
        });
      });

    const { err, stdout, stderr } = await run();

    // Persist side-effect artifacts for the file-based assertions.
    const artifacts = join(PF_ROOT, ".artifacts", label);
    rmSync(artifacts, { recursive: true, force: true });
    mkdirSync(artifacts, { recursive: true });
    for (const [src, dst] of [
      [join(cwd, ".zensu"), join(artifacts, "zensu")],
      [join(cwd, ".zensu-dump"), join(artifacts, "dump")],
      [join(home, ".zensu", "plugin-root"), join(artifacts, "home-zensu", "plugin-root")],
    ]) {
      if (existsSync(src)) cpSync(src, dst, { recursive: true });
    }
    writeFileSync(join(artifacts, "stdout.txt"), stdout);
    writeFileSync(join(artifacts, "stderr.txt"), stderr);
    writeFileSync(
      join(artifacts, "meta.json"),
      JSON.stringify({ sandbox, cwd, home, agent, error: err ? String(err.message || err) : null }, null, 2)
    );

    if (err && !stdout) {
      return { output: "", error: `kiro-cli failed: ${err.message}\n${stderr.slice(-500)}`, metadata: { artifacts } };
    }
    return { output: stdout, metadata: { artifacts, stderr: stderr.slice(-2000), sandbox } };
  }
}
