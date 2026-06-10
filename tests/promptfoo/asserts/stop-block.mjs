// D3 — verifies the stop chain-enforcer MECHANISM from side effects: with an
// armed session where implementation is complete but the chain is not done,
// the stop hook must have fired and emitted its block (it appends to the
// .stopblocks anti-deadlock budget exactly when it blocks).
// Live finding (kiro-cli 2.6.1): in --no-interactive mode Kiro runs the stop
// hook but does not re-prompt on {"decision":"block"} — the loop is an
// interactive-session behavior, so the model's final text cannot be asserted
// here; the artifact trail can.
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PF_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export default (output, context) => {
  const vars = (context && context.vars) || {};
  const label = String(vars.label || vars.scenario || "default").replace(/[^a-z0-9-]/gi, "-");
  const stateDir = join(PF_ROOT, ".artifacts", label, "zensu", "state");
  if (!existsSync(stateDir)) return { pass: false, score: 0, reason: "no state artifacts captured" };

  const notes = [];
  let armed = false, blocked = false;
  for (const f of readdirSync(stateDir)) {
    const p = join(stateDir, f);
    if (f.startsWith("tdd-phase-") && f.endsWith(".json")) {
      try {
        const j = JSON.parse(readFileSync(p, "utf8"));
        if (j.active === true && j.implComplete === true && j.chainDone !== true) {
          armed = true;
          notes.push(`armed state: ${f} (active+implComplete, chain open)`);
        }
      } catch { /* ignore */ }
    }
    if (f.endsWith(".stopblocks") && statSync(p).size > 0) {
      blocked = true;
      notes.push(`stop hook blocked ${statSync(p).size}x (${f})`);
    }
  }
  if (!armed) notes.push("no armed open-chain state found");
  if (!blocked) notes.push("no .stopblocks budget written — stop hook never emitted a block");
  const pass = armed && blocked;
  return { pass, score: pass ? 1 : 0, reason: notes.join(" | ") };
};
