#!/usr/bin/env node
"use strict";

// Generate the resolver's immutable runtime closure from runtime-files.txt.
// install.sh consumes the same inventory directly; CI uses --check so the
// embedded fail-closed list cannot drift from installed publication.
const fs = require("fs");
const path = require("path");

const root = path.resolve(__dirname, "..");
const inventoryPath = path.join(root, "runtime-files.txt");
const resolverPath = path.join(root, "hooks", "lib", "resolve-plugin-root.sh");
const files = fs.readFileSync(inventoryPath, "utf8").split(/\r?\n/).filter(Boolean);
if (!files.length || new Set(files).size !== files.length || files.some(file => file.startsWith("/") || file.split("/").includes(".."))) {
  throw new Error("runtime-files.txt contains an invalid or duplicate entry");
}
const source = fs.readFileSync(resolverPath, "utf8");
const marker = /\/\* zensu-runtime-inventory:start \*\/[\s\S]*?\/\* zensu-runtime-inventory:end \*\//;
if (!marker.test(source)) throw new Error("resolver runtime-inventory markers are missing");
const generated = `/* zensu-runtime-inventory:start */ ${JSON.stringify(files, null, 2)} /* zensu-runtime-inventory:end */`;
const next = source.replace(marker, generated);
if (process.argv[2] === "--check") {
  if (next !== source) {
    process.stderr.write("resolve-plugin-root.sh runtime inventory is stale; run scripts/sync-runtime-inventory.js\n");
    process.exit(1);
  }
} else {
  fs.writeFileSync(resolverPath, next);
}
