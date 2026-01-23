#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.12: repair parseNumber() block by boundary replacement (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");
let changed = false;

const startNeedle = "function parseNumber(";
const start = src.indexOf(startNeedle);
if (start === -1) throw new Error("Could not find function parseNumber(...) in src/index.ts");

// Next function boundary after parseNumber
const nextFn = src.indexOf("\nfunction ", start + 1);
if (nextFn === -1) throw new Error("Could not find the next function boundary after parseNumber().");

const canonical = `function parseNumber(x: string | undefined): number | null {
  if (x == null) return null;
  const s = String(x).trim();
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}
`;

// Idempotent: only replace if the slice isn't already canonical
const existingSlice = src.slice(start, Math.min(start + canonical.length, src.length));
if (existingSlice !== canonical) {
  // Keep the leading newline before the next function ("function ...")
  src = src.slice(0, start) + canonical + src.slice(nextFn + 1);
  changed = true;
}

fs.writeFileSync(path, src, "utf8");
console.log(changed ? "v0.12.12 patch applied." : "v0.12.12 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
