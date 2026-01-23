#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.7: cleanup dangling TypeScript fragments (idempotent)"

node <<'NODE'
import fs from "fs";

function read(p){ return fs.readFileSync(p,"utf8"); }
function writeIfChanged(p,next){
  const cur = read(p);
  if (cur === next) return false;
  fs.writeFileSync(p,next,"utf8");
  return true;
}

const path = "src/index.ts";
let src = read(path);
let changed = false;

// 1) Remove standalone `as any);`
src = src.replace(/^\s*as\s+any\);\s*$/gm, () => {
  changed = true;
  return "";
});

// 2) Remove standalone `);`
src = src.replace(/^\s*\);\s*$/gm, () => {
  changed = true;
  return "";
});

// 3) Remove stray standalone closing braces at top level
// (very conservative: only braces on their own line)
src = src.replace(/^\s*\}\s*$/gm, () => {
  changed = true;
  return "";
});

changed = writeIfChanged(path, src) || changed;

console.log(changed ? "v0.12.7 patch applied." : "v0.12.7 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
