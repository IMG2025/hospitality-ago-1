#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.16: repair evalRule() block by boundary replacement (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");
let changed = false;

const startNeedle = "function evalRule(";
const start = src.indexOf(startNeedle);
if (start === -1) throw new Error("Could not find function evalRule(...) in src/index.ts");

// Next function boundary after evalRule
const nextFn = src.indexOf("\nfunction ", start + 1);
if (nextFn === -1) throw new Error("Could not find the next function boundary after evalRule().");

const canonical = `function evalRule(rule: Rule, row: Record<string, string>): boolean {
  const field = rule.field;
  const v = (row[field] ?? "").toString();

  switch (rule.op) {
    case "eq":
      return v === String(rule.value ?? "");
    case "neq":
      return v !== String(rule.value ?? "");
    case "contains":
      return v.includes(String(rule.value ?? ""));
    case "exists":
      return v.trim().length > 0;
    case "gte": {
      const n = Number(v);
      const t = Number(rule.value);
      return Number.isFinite(n) && Number.isFinite(t) ? n >= t : false;
    }
    case "lte": {
      const n = Number(v);
      const t = Number(rule.value);
      return Number.isFinite(n) && Number.isFinite(t) ? n <= t : false;
    }
    default:
      return false;
  }
}
`;

const existingSlice = src.slice(start, Math.min(start + canonical.length, src.length));
if (existingSlice !== canonical) {
  src = src.slice(0, start) + canonical + src.slice(nextFn + 1);
  changed = true;
}

fs.writeFileSync(path, src, "utf8");
console.log(changed ? "v0.12.16 patch applied." : "v0.12.16 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
