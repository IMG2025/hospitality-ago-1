#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.13: repair parseDateOnly() block by boundary replacement (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");
let changed = false;

const startNeedle = "function parseDateOnly(";
const start = src.indexOf(startNeedle);
if (start === -1) throw new Error("Could not find function parseDateOnly(...) in src/index.ts");

// Next function boundary after parseDateOnly
const nextFn = src.indexOf("\nfunction ", start + 1);
if (nextFn === -1) throw new Error("Could not find the next function boundary after parseDateOnly().");

const canonical = `function parseDateOnly(x: string | undefined): number | null {
  if (x == null) return null;
  const s = String(x).trim();
  if (!s) return null;

  // Accept YYYY-MM-DD or any string Date can parse; normalize to UTC date-only millis
  const d = new Date(s.length >= 10 ? s.slice(0, 10) : s);
  if (Number.isNaN(d.getTime())) return null;

  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
}
`;

const existingSlice = src.slice(start, Math.min(start + canonical.length, src.length));
if (existingSlice !== canonical) {
  src = src.slice(0, start) + canonical + src.slice(nextFn + 1);
  changed = true;
}

fs.writeFileSync(path, src, "utf8");
console.log(changed ? "v0.12.13 patch applied." : "v0.12.13 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
