#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.15: repair pickEvidence() block by boundary replacement (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");
let changed = false;

const startNeedle = "function pickEvidence(";
const start = src.indexOf(startNeedle);
if (start === -1) throw new Error("Could not find function pickEvidence(...) in src/index.ts");

// Next function boundary after pickEvidence
const nextFn = src.indexOf("\nfunction ", start + 1);
if (nextFn === -1) throw new Error("Could not find the next function boundary after pickEvidence().");

const canonical = `function pickEvidence(fields: string[], row: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of fields) {
    const v = row[f];
    if (v !== undefined && String(v).trim() !== "") out[f] = String(v);
  }
  return out;
}
`;

const existingSlice = src.slice(start, Math.min(start + canonical.length, src.length));
if (existingSlice !== canonical) {
  src = src.slice(0, start) + canonical + src.slice(nextFn + 1);
  changed = true;
}

fs.writeFileSync(path, src, "utf8");
console.log(changed ? "v0.12.15 patch applied." : "v0.12.15 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
