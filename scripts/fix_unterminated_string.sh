#!/usr/bin/env bash
set -euo pipefail

echo "Fixing unterminated string literal issue (defensive pass)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");

// Normalize accidental broken maintenance.csv strings
src = src.replace(/"inputs\/maintenance\.csv\s*"/g, `"inputs/maintenance.csv"`);

// Guard against stray line breaks inside quotes
src = src.replace(/"inputs\/maintenance\.csv\s*\n\s*"/g, `"inputs/maintenance.csv"`);

fs.writeFileSync(path, src, "utf8");
console.log("String normalization complete.");
NODE

npm run build
