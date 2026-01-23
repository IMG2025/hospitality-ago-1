#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.17: repair missingFields() block by boundary replacement (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");
let changed = false;

const startNeedle = "function missingFields(";
const start = src.indexOf(startNeedle);
if (start === -1) throw new Error("Could not find function missingFields(...) in src/index.ts");

// Next function boundary after missingFields
const nextFn = src.indexOf("\nfunction ", start + 1);
if (nextFn === -1) throw new Error("Could not find the next function boundary after missingFields().");

const canonical = `function missingFields(headers: string[], required: string[]): string[] {
  const set = new Set(headers.map(h => h.trim().toLowerCase()));
  const missing: string[] = [];
  for (const r of required) {
    const key = r.trim().toLowerCase();
    if (!set.has(key)) missing.push(r);
  }
  return missing;
}
`;

const existingSlice = src.slice(start, Math.min(start + canonical.length, src.length));
if (existingSlice !== canonical) {
  src = src.slice(0, start) + canonical + src.slice(nextFn + 1);
  changed = true;
}

fs.writeFileSync(path, src, "utf8");
console.log(changed ? "v0.12.17 patch applied." : "v0.12.17 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
