import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../..");

export const RUNTIME_FILES = Object.freeze(
  readFileSync(join(REPO_ROOT, "runtime-files.txt"), "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
);
