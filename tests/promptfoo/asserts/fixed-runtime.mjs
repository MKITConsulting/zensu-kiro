// B6 — the installed fixed Kiro runtime must carry a self-consistent VERSION,
// manifest, and manifest hashes for the complete logging execution closure.
import { createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { RUNTIME_FILES } from "../fixed-runtime-closure.mjs";

const PF_ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const sha256 = file => createHash("sha256").update(readFileSync(file)).digest("hex");

export default (output, context) => {
  const vars = (context && context.vars) || {};
  const label = String(vars.label || vars.scenario || "default").replace(/[^a-z0-9-]/gi, "-");
  const artifacts = join(PF_ROOT, ".artifacts", label);
  const captured = join(artifacts, "home-kiro", "zensu");
  const metaFile = join(artifacts, "meta.json");
  const versionFile = join(captured, "VERSION");
  const manifestFile = join(captured, "manifest.json");
  const closure = RUNTIME_FILES;
  const closureFiles = closure.map(rel => [rel, join(captured, ...rel.split("/"))]);

  for (const file of [metaFile, versionFile, manifestFile, ...closureFiles.map(([, file]) => file)]) {
    if (!existsSync(file)) return { pass: false, score: 0, reason: `fixed-runtime artifact missing: ${file}` };
  }

  try {
    const meta = JSON.parse(readFileSync(metaFile, "utf8"));
    const manifest = JSON.parse(readFileSync(manifestFile, "utf8"));
    const version = readFileSync(versionFile, "utf8").trim();
    const runtime = join(meta.home, ".kiro", "zensu");
    const checks = closureFiles;
    const ok = manifest.version === version && checks.every(([rel, file]) => manifest.files?.[join(runtime, rel)] === sha256(file));
    return {
      pass: ok,
      score: ok ? 1 : 0,
      reason: ok ? `fixed Kiro runtime ${version} passed manifest integrity checks` : "fixed Kiro runtime VERSION/hash mismatch",
    };
  } catch (error) {
    return { pass: false, score: 0, reason: `fixed-runtime validation error: ${error.message}` };
  }
};
