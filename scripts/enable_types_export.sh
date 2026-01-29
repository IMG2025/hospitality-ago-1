#!/usr/bin/env bash
set -euo pipefail

node - <<'NODE'
import fs from "fs";

const tsPath = "tsconfig.json";
const ts = JSON.parse(fs.readFileSync(tsPath, "utf8"));

ts.compilerOptions ||= {};
ts.compilerOptions.declaration = true;
ts.compilerOptions.declarationMap = true;
ts.compilerOptions.emitDeclarationOnly = false;
ts.compilerOptions.outDir ||= "dist";
ts.compilerOptions.rootDir ||= "src";

fs.writeFileSync(tsPath, JSON.stringify(ts, null, 2) + "\n");
console.log("Patched tsconfig.json (declarations enabled)");
NODE

node - <<'NODE'
import fs from "fs";

const pkgPath = "package.json";
const pkg = JSON.parse(fs.readFileSync(pkgPath, "utf8"));

pkg.name = "hospitality-ago-1";
pkg.main ||= "dist/index.js";
pkg.types ||= "dist/index.d.ts";

pkg.exports ||= {};
pkg.exports["."] ||= {};
pkg.exports["."].import ||= "./dist/index.js";
pkg.exports["."].types  ||= "./dist/index.d.ts";

fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + "\n");
console.log("Patched package.json (types + exports)");
NODE

npm run build
