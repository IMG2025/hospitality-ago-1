#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.6: remove orphaned catch blocks (idempotent)"

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

// Remove any catch blocks that are not directly preceded by try
// Conservative: remove standalone catch blocks at top-level
const orphanCatch =
  /\n\s*catch\s*\(\s*[^)]*\s*\)\s*\{[\s\S]*?\n\s*\}\s*/g;

src = src.replace(orphanCatch, () => {
  changed = true;
  return "\n";
});

changed = writeIfChanged(path, src) || changed;

console.log(changed ? "v0.12.6 patch applied." : "v0.12.6 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
