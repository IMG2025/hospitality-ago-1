#!/usr/bin/env bash
set -euo pipefail

echo "Fixing ESM import extensions for v0.11 (node16/nodenext compatible)"

FILE="src/domains/index.ts"

if [ ! -f "$FILE" ]; then
  echo "ERROR: $FILE not found"
  exit 1
fi

node <<'NODE'
import fs from "fs";

const path = "src/domains/index.ts";
let src = fs.readFileSync(path, "utf8");

// Normalize shared/types import to explicit .js extension
src = src.replace(
  /from\s+["']\.\.\/shared\/types["']/g,
  'from "../shared/types.js"'
);

fs.writeFileSync(path, src, "utf8");
console.log("ESM import normalization complete.");
NODE

npm run build
