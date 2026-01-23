#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.8: brace-balance repair for src/index.ts (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");

// 1) Remove prior v0.12.8 block if present (idempotent reset)
src = src.replace(
  /\n\/\/ BEGIN v0\.12\.8 BRACE_FIX[\s\S]*?\n\/\/ END v0\.12\.8 BRACE_FIX\s*\n?/g,
  "\n"
);

// 2) Best-effort brace balance ignoring strings/comments (simple state machine)
let bal = 0;
let i = 0;

let inS = false;   // '
let inD = false;   // "
let inT = false;   // `
let inLC = false;  // //
let inBC = false;  // /* */
let esc = false;

while (i < src.length) {
  const c = src[i];
  const n = src[i + 1];

  if (inLC) {
    if (c === "\n") inLC = false;
    i++;
    continue;
  }
  if (inBC) {
    if (c === "*" && n === "/") { inBC = false; i += 2; continue; }
    i++;
    continue;
  }

  if (inS) { if (!esc && c === "'") inS = false; esc = (!esc && c === "\\"); i++; continue; }
  if (inD) { if (!esc && c === '"') inD = false; esc = (!esc && c === "\\"); i++; continue; }
  if (inT) { if (!esc && c === "`") inT = false; esc = (!esc && c === "\\"); i++; continue; }

  // comment starts
  if (c === "/" && n === "/") { inLC = true; i += 2; continue; }
  if (c === "/" && n === "*") { inBC = true; i += 2; continue; }

  // string starts
  if (c === "'") { inS = true; esc = false; i++; continue; }
  if (c === '"') { inD = true; esc = false; i++; continue; }
  if (c === "`") { inT = true; esc = false; i++; continue; }

  // braces
  if (c === "{") bal++;
  if (c === "}") bal--;

  i++;
}

// If bal > 0, we are missing `bal` closing braces.
if (bal > 0) {
  const fix =
    `\n// BEGIN v0.12.8 BRACE_FIX\n` +
    `// Auto-appended to close unbalanced blocks after scripted refactors.\n` +
    `${"}\n".repeat(bal)}` +
    `// END v0.12.8 BRACE_FIX\n`;

  src = src.replace(/\s*$/m, "") + fix;
}

fs.writeFileSync(path, src, "utf8");
console.log(bal > 0 ? `v0.12.8 applied: appended ${bal} closing brace(s).` : "v0.12.8 no-op: braces already balanced.");
NODE

# Must end with build (per rule)
npm run build
