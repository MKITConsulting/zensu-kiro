#!/usr/bin/env node
"use strict";

const mode = process.env.ZENSU_KIRO_TEST_CYGPATH_MODE || "nonzero";
const unrelated = process.env.ZENSU_KIRO_TEST_UNRELATED_NATIVE || "C:/unrelated";

switch (mode) {
  case "nonzero":
    process.exit(9);
    break;
  case "timeout":
    setTimeout(() => {}, 10000);
    break;
  case "multiline":
    process.stdout.write(`${unrelated}\n${unrelated}\n`);
    break;
  case "relative":
    process.stdout.write("relative/unbound-anchor\n");
    break;
  case "unrelated":
    process.stdout.write(`${unrelated}\n`);
    break;
  default:
    process.exit(10);
}
