#!/usr/bin/env node
import fs from "node:fs";
import { execSync } from "node:child_process";

function run(cmd) { execSync(cmd, { stdio: "inherit" }); }
function read(p) { return fs.readFileSync(p, "utf8"); }
function exists(p) { return fs.existsSync(p); }
function writeIfChanged(p, next) {
  const prev = exists(p) ? read(p) : "";
  if (prev !== next) fs.writeFileSync(p, next);
}
function chmod755(p) { try { fs.chmodSync(p, 0o755); } catch {} }

const ROOT = execSync("git rev-parse --show-toplevel", { encoding: "utf8" }).trim();
process.chdir(ROOT);

const PKG = "package.json";
if (!exists(PKG)) throw new Error("Missing: package.json");

// Sanity: ensure baseline artifacts exist (Step-22)
const audit = "scripts/audit_hospitality_dist_importable_v1.sh";
const gate = "scripts/gate_ci_termux_v1.sh";
if (!exists(audit)) throw new Error(`Missing expected Step-22 artifact: ${audit}`);
if (!exists(gate)) throw new Error(`Missing expected Step-22 artifact: ${gate}`);

// Ensure package.json has test script (idempotent)
const pkg = JSON.parse(read(PKG));
pkg.scripts = pkg.scripts || {};
const canonical = "npm run build && ./scripts/audit_hospitality_dist_importable_v1.sh";
if (typeof pkg.scripts.test !== "string") {
  pkg.scripts.test = canonical;
  writeIfChanged(PKG, JSON.stringify(pkg, null, 2) + "\n");
  console.log("OK: created scripts.test");
} else if (pkg.scripts.test === canonical) {
  console.log("OK: scripts.test already canonical");
} else {
  console.log("OK: scripts.test exists (left unchanged): " + pkg.scripts.test);
}

// IMPORTANT: do NOT run clean-tree gate inside a patch that creates/modifies files.
// Gates (must end with npm run build)
run("npm test");
run("npm run build");
