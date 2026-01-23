#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.14: repair toMillis() block by boundary replacement (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");
let changed = false;

const startNeedle = "function toMillis(";
const start = src.indexOf(startNeedle);
if (start === -1) throw new Error("Could not find function toMillis(...) in src/index.ts");

// Next function boundary after toMillis
const nextFn = src.indexOf("\nfunction ", start + 1);
if (nextFn === -1) throw new Error("Could not find the next function boundary after toMillis().");

const canonical = `function toMillis(ts?: string): number | null {
  if (!ts) return null;
  const d = new Date(ts);
  const t = d.getTime();
  return Number.isNaN(t) ? null : t;
}
`;

const existingSlice = src.slice(start, Math.min(start + canonical.length, src.length));
if (existingSlice !== canonical) {
  src = src.slice(0, start) + canonical + src.slice(nextFn + 1);
  changed = true;
}

fs.writeFileSync(path, src, "utf8");
console.log(changed ? "v0.12.14 patch applied." : "v0.12.14 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
