#!/usr/bin/env bash
set -euo pipefail

node - <<'NODE'
import fs from "fs";

const path = "tsconfig.json";
const ts = JSON.parse(fs.readFileSync(path, "utf8"));

ts.compilerOptions ||= {};
ts.compilerOptions.noEmit = false;
ts.compilerOptions.declaration = true;
ts.compilerOptions.emitDeclarationOnly = false;
ts.compilerOptions.declarationMap = true;
ts.compilerOptions.outDir = ts.compilerOptions.outDir || "dist";
ts.compilerOptions.rootDir = ts.compilerOptions.rootDir || "src";

fs.writeFileSync(path, JSON.stringify(ts, null, 2) + "\n");

console.log("Forced noEmit=false and declaration emit");
NODE

rm -rf dist
npm run build
