// B6 — the sandbox HOME must end up with ~/.zensu/plugin-root pointing at the
// sandbox runtime home (written by install.sh and re-asserted by the
// agentSpawn pulse hook on every session).
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PF_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export default (output, context) => {
  const vars = (context && context.vars) || {};
  const label = String(vars.scenario || "default").replace(/[^a-z0-9-]/gi, "-");
  const f = join(PF_ROOT, ".artifacts", label, "home-zensu", "plugin-root");
  if (!existsSync(f)) return { pass: false, score: 0, reason: "plugin-root not captured from sandbox home" };
  const v = readFileSync(f, "utf8").trim();
  const ok = v.endsWith("/.kiro/zensu");
  return { pass: ok, score: ok ? 1 : 0, reason: ok ? `plugin-root = ${v}` : `unexpected plugin-root: ${v}` };
};
