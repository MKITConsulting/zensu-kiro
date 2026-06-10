// D1/D4 — inspect the payload dumps written by the zensu-dump variant agent.
// Verifies the risk-register facts: userPromptSubmit carries `prompt` (R2),
// session_id is stable across events (R12), records the MCP tool_name format
// (R4) and shell tool_response keys (R5), and (for vars.expect=subagent, R3)
// whether postToolUse fired for the subagent tool.
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const PF_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

export default (output, context) => {
  const vars = (context && context.vars) || {};
  const label = String(vars.scenario || "default").replace(/[^a-z0-9-]/gi, "-");
  const dumpDir = join(PF_ROOT, ".artifacts", label, "dump");
  if (!existsSync(dumpDir)) {
    return { pass: false, score: 0, reason: `no dump dir at ${dumpDir} — variant agent hooks did not fire` };
  }
  const events = {};
  for (const f of readdirSync(dumpDir)) {
    const lines = readFileSync(join(dumpDir, f), "utf8").trim().split("\n").filter(Boolean);
    events[f.replace(/\.jsonl?$/, "")] = lines.map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  }
  const notes = [];
  let pass = true;

  if (vars.expect === "subagent") {
    const post = events.postToolUse || [];
    const hit = post.find((p) => p.tool_name === "subagent" || p.tool_name === "use_subagent" || p.tool_name === "delegate");
    if (hit) notes.push(`R3 VERIFIED: postToolUse fired for ${hit.tool_name}; tool_input keys=${Object.keys(hit.tool_input || {}).join(",")}`);
    else { pass = false; notes.push(`R3 REFUTED: no postToolUse for subagent (events seen: ${(post.map(p=>p.tool_name)).join(",") || "none"})`); }
    return { pass, score: pass ? 1 : 0, reason: notes.join(" | ") };
  }

  const ups = events.userPromptSubmit || [];
  if (ups.length && typeof ups[0].prompt === "string" && ups[0].prompt.length > 0) notes.push("R2 VERIFIED: userPromptSubmit has prompt field");
  else { pass = false; notes.push(`R2 PROBLEM: userPromptSubmit keys=${ups.length ? Object.keys(ups[0]).join(",") : "no event"}`); }

  const sids = new Set();
  for (const evs of Object.values(events)) for (const e of evs) if (e.session_id) sids.add(e.session_id);
  if (sids.size === 1) notes.push("R12 VERIFIED: session_id stable across events");
  else { pass = false; notes.push(`R12 PROBLEM: ${sids.size} distinct session_ids`); }

  const pre = events.preToolUse || [];
  const mcp = pre.filter((p) => /zensu/i.test(String(p.tool_name)) && !/^(write|fs_write|shell|execute_bash|read|fs_read)$/.test(String(p.tool_name)));
  if (mcp.length) notes.push(`R4 EVIDENCE: MCP tool_name format = "${mcp[0].tool_name}"`);
  else notes.push("R4 NO-EVIDENCE: no zensu MCP call observed (informational)");

  const post = events.postToolUse || [];
  const shell = post.find((p) => p.tool_name === "shell" || p.tool_name === "execute_bash");
  if (shell) notes.push(`R5 EVIDENCE: tool_response keys = ${Object.keys(shell.tool_response || {}).join(",") || "(none)"}`);
  else notes.push("R5 NO-EVIDENCE: no shell call observed (informational)");

  if (events.agentSpawn && events.agentSpawn.length) notes.push("R14 EVIDENCE: agentSpawn fired; keys=" + Object.keys(events.agentSpawn[0]).join(","));

  return { pass, score: pass ? 1 : 0, reason: notes.join(" | ") };
};
