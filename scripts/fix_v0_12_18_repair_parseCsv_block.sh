#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.18: repair parseCsv() function block by boundary replacement (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");
let changed = false;

const startNeedle = "function parseCsv(";
const start = src.indexOf(startNeedle);
if (start === -1) throw new Error("Could not find function parseCsv(...) in src/index.ts");

// Next function boundary after parseCsv
const nextFn = src.indexOf("\nfunction ", start + 1);
if (nextFn === -1) throw new Error("Could not find the next function boundary after parseCsv().");

// Canonical CSV parser (simple, quoted-fields aware enough for exports)
const canonical = `function parseCsv(text: string): { headers: string[]; rows: Record<string, string>[] } {
  const lines = text.replace(/\\r\\n/g, "\\n").replace(/\\r/g, "\\n").split("\\n").filter(l => l.trim().length > 0);
  if (lines.length === 0) return { headers: [], rows: [] };

  const parseLine = (line: string): string[] => {
    const out: string[] = [];
    let cur = "";
    let inQ = false;
    for (let i = 0; i < line.length; i++) {
      const ch = line[i];
      if (ch === '"') {
        // handle escaped quotes ""
        const next = line[i + 1];
        if (inQ && next === '"') {
          cur += '"';
          i++;
        } else {
          inQ = !inQ;
        }
      } else if (ch === "," && !inQ) {
        out.push(cur);
        cur = "";
      } else {
        cur += ch;
      }
    }
    out.push(cur);
    return out.map(s => s.trim());
  };

  const headers = parseLine(lines[0]).map(h => h.trim());
  const rows: Record<string, string>[] = [];

  for (let i = 1; i < lines.length; i++) {
    const cols = parseLine(lines[i]);
    if (cols.every(c => c.trim() === "")) continue;
    const row: Record<string, string> = {};
    for (let j = 0; j < headers.length; j++) {
      row[headers[j]] = (cols[j] ?? "").trim();
    }
    rows.push(row);
  }

  return { headers, rows };
}
`;

const existingSlice = src.slice(start, Math.min(start + canonical.length, src.length));
if (existingSlice !== canonical) {
  src = src.slice(0, start) + canonical + src.slice(nextFn + 1);
  changed = true;
}

fs.writeFileSync(path, src, "utf8");
console.log(changed ? "v0.12.18 patch applied." : "v0.12.18 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
