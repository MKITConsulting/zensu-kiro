// B5 — after a /zensu-tdd run on the toy-app, the project-local .zensu
// artifacts must show a real RED→IMPL→GREEN walk: phase state visited the
// trio for at least one step, and the witness log recorded shell commands.
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PF_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export default (output, context) => {
  const vars = (context && context.vars) || {};
  const label = String(vars.label || vars.scenario || "default").replace(/[^a-z0-9-]/gi, "-");
  const zensuDir = join(PF_ROOT, ".artifacts", label, "zensu");
  if (!existsSync(zensuDir)) return { pass: false, score: 0, reason: "no .zensu artifacts captured" };

  const notes = [];
  let pass = true;

  const stateDir = join(zensuDir, "state");
  let phases = [];
  if (existsSync(stateDir)) {
    for (const f of readdirSync(stateDir)) {
      if (!f.startsWith("tdd-phase-")) continue;
      try {
        const j = JSON.parse(readFileSync(join(stateDir, f), "utf8"));
        const hist = Array.isArray(j.history) ? j.history.map((h) => h.phase) : [];
        phases = phases.concat(hist, j.phase ? [j.phase] : []);
      } catch { /* ignore */ }
    }
  }
  const seen = new Set(phases);
  for (const want of ["RED_FAIL", "IMPL", "GREEN_PASS"]) {
    if (seen.has(want)) notes.push(`phase ${want} visited`);
    else { pass = false; notes.push(`phase ${want} NEVER visited`); }
  }

  const logsDir = join(zensuDir, "logs");
  let witnessLines = 0;
  if (existsSync(logsDir)) {
    for (const f of readdirSync(logsDir)) {
      if (f.startsWith("witness-")) witnessLines += readFileSync(join(logsDir, f), "utf8").trim().split("\n").filter(Boolean).length;
    }
  }
  if (witnessLines > 0) notes.push(`witness recorded ${witnessLines} shell commands`);
  else { pass = false; notes.push("witness log empty"); }

  return { pass, score: pass ? 1 : 0, reason: notes.join(" | ") };
};
