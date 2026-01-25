#!/usr/bin/env bash
set -euo pipefail

node - <<'NODE'
import fs from "fs";

const path = "package.json";
const pkg = JSON.parse(fs.readFileSync(path, "utf8"));

pkg.name = "hospitality-ago-1";
pkg.description = "AGO-1 Hospitality Domain Executor";
pkg.version = pkg.version || "0.1.0";

fs.writeFileSync(path, JSON.stringify(pkg, null, 2) + "\n");

console.log("Renamed package to hospitality-ago-1");
NODE

npm run build
