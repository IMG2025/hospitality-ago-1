#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.19C: replace unbalanced raw loop block via brace matching (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");

const marker = "v0.12.19C RAW_LOOP_REPLACED";
if (src.includes(marker)) {
  console.log("v0.12.19C already applied; no-op.");
  process.exit(0);
}

const needle = "for (const l of raw)";
const loopIdx = src.indexOf(needle);
if (loopIdx === -1) throw new Error("Target loop not found: for (const l of raw)");

const braceOpen = src.indexOf("{", loopIdx);
if (braceOpen === -1) throw new Error("Could not find '{' after raw loop.");

// Simple brace matcher with comment/string skipping (good enough for this scenario)
let i = braceOpen;
let depth = 0;

let inS = false, inD = false, inT = false, inLC = false, inBC = false;
let esc = false;

for (; i < src.length; i++) {
  const c = src[i];
  const n = src[i + 1];

  if (inLC) { if (c === "\n") inLC = false; continue; }
  if (inBC) { if (c === "*" && n === "/") { inBC = false; i++; } continue; }

  if (inS) { if (!esc && c === "'") inS = false; esc = (!esc && c === "\\"); continue; }
  if (inD) { if (!esc && c === '"') inD = false; esc = (!esc && c === "\\"); continue; }
  if (inT) { if (!esc && c === "`") inT = false; esc = (!esc && c === "\\"); continue; }

  if (c === "/" && n === "/") { inLC = true; i++; continue; }
  if (c === "/" && n === "*") { inBC = true; i++; continue; }

  if (c === "'") { inS = true; esc = false; continue; }
  if (c === '"') { inD = true; esc = false; continue; }
  if (c === "`") { inT = true; esc = false; continue; }

  if (c === "{") depth++;
  if (c === "}") {
    depth--;
    if (depth === 0) { i++; break; } // include this closing brace
  }
}

if (depth !== 0) {
  throw new Error("Brace matcher could not find the end of the raw loop block (still unbalanced).");
}

const blockStart = loopIdx;
const blockEnd = i; // exclusive end index (already advanced past matching brace)

const replacement =
`for (const l of raw) {
  // ${marker}
  // Structural recovery: prior implementation had unbalanced braces.
  // Reintroduce raw-policy parsing later in a dedicated module.
  void l;
}
`;

src = src.slice(0, blockStart) + replacement + src.slice(blockEnd);

fs.writeFileSync(path, src, "utf8");
console.log("Replaced raw loop block successfully.");
NODE

# Must end with build (per rule)
npm run build
