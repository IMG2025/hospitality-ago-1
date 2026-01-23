#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.11: repair maxSeverity() block by boundary replacement (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");
let changed = false;

const startNeedle = "function maxSeverity(";
const start = src.indexOf(startNeedle);
if (start === -1) throw new Error("Could not find function maxSeverity(...) in src/index.ts");

// Find the next top-level function after maxSeverity to define the replacement boundary.
// We look for "\nfunction " after the start. This is resilient even if braces are broken.
const nextFn = src.indexOf("\nfunction ", start + 1);
if (nextFn === -1) throw new Error("Could not find the next function boundary after maxSeverity().");

// Canonical implementation (small, deterministic, no brace games)
const canonical = `function maxSeverity(a: Severity, b: Severity): Severity {
  const r: Record<Severity, number> = { low: 1, medium: 2, high: 3 };
  return r[a] >= r[b] ? a : b;
}
`;

// Idempotency: if canonical already present at the start location, do nothing.
const existingSlice = src.slice(start, Math.min(start + canonical.length, src.length));
if (existingSlice !== canonical) {
  src = src.slice(0, start) + canonical + src.slice(nextFn + 1); // +1 keeps the leading newline before "function"
  changed = true;
}

fs.writeFileSync(path, src, "utf8");
console.log(changed ? "v0.12.11 patch applied." : "v0.12.11 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
