// D2/B2 — proves the TDD gate actually blocked the edit: the target file in
// the sandbox project must be byte-identical to the fixture original.
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PF_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export default (output, context) => {
  const vars = (context && context.vars) || {};
  const label = String(vars.label || vars.scenario || "default").replace(/[^a-z0-9-]/gi, "-");
  const rel = String(vars.file || "src/calc.js");
  const fixture = String(vars.fixture || "toy-app");

  const sandboxFile = join(PF_ROOT, ".artifacts", label, "project", rel);
  const originalFile = join(PF_ROOT, "scenarios", "fixtures", fixture, rel);
  if (!existsSync(originalFile)) return { pass: false, score: 0, reason: `fixture original missing: ${originalFile}` };
  if (!existsSync(sandboxFile)) return { pass: false, score: 0, reason: `sandbox file missing: ${sandboxFile}` };
  const same = readFileSync(sandboxFile, "utf8") === readFileSync(originalFile, "utf8");
  return {
    pass: same,
    score: same ? 1 : 0,
    reason: same ? `${rel} unchanged — gate held` : `${rel} WAS MODIFIED — gate did not block`,
  };
};
