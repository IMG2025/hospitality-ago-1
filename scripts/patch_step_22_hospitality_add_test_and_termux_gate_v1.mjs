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

const SCRIPTS_DIR = "scripts";
if (!exists(SCRIPTS_DIR)) fs.mkdirSync(SCRIPTS_DIR, { recursive: true });

// ------------------------------------------------------------
// 1) Audit: dist entrypoints importable (runtime contract)
// ------------------------------------------------------------
const AUDIT = "scripts/audit_hospitality_dist_importable_v1.sh";
const auditSrc = [
  "#!/usr/bin/env bash",
  "set -euo pipefail",
  "",
  'ROOT="$(git rev-parse --show-toplevel)"',
  'cd "$ROOT"',
  "",
  "npm run build >/dev/null",
  "",
  "node - <<'NODE'",
  "async function main() {",
  "  const entrypoints = [",
  '    "./dist/index.js",',
  "  ];",
  "  const ok = [];",
  "  for (const p of entrypoints) {",
  "    try {",
  "      await import(p);",
  "      ok.push(p);",
  "    } catch (e) {",
  '      console.error("FAIL: dist import failed:", p);',
  "      console.error(String((e && e.stack) || e));",
  "      process.exit(1);",
  "    }",
  "  }",
  '  console.log("OK: Hospitality dist entrypoints importable:", ok);',
  "}",
  "main();",
  "NODE",
  "",
].join("\n");

writeIfChanged(AUDIT, auditSrc);
chmod755(AUDIT);
console.log("OK: wrote " + AUDIT);

// ------------------------------------------------------------
// 2) Termux gate (canonical): npm test + clean tree + npm run build
// ------------------------------------------------------------
const GATE = "scripts/gate_ci_termux_v1.sh";
const gateSrc = [
  "#!/usr/bin/env bash",
  "set -euo pipefail",
  "",
  'ROOT="$(git rev-parse --show-toplevel)"',
  'cd "$ROOT"',
  "",
  'echo "OK: Hospitality Termux gate: start"',
  "npm test",
  "",
  "# Enforce clean tree after tests (prevents untracked drift artifacts)",
  'if [[ -n "$(git status --porcelain)" ]]; then',
  '  echo "FAIL: working tree not clean after tests:"',
  "  git status --porcelain",
  "  exit 1",
  "fi",
  "",
  "npm run build",
  'echo "OK: Hospitality Termux gate: green + clean tree"',
  "",
].join("\n");

writeIfChanged(GATE, gateSrc);
chmod755(GATE);
console.log("OK: wrote " + GATE);

// ------------------------------------------------------------
// 3) Wire npm test (idempotent)
//    If missing, create it. If present but not canonical, leave it unchanged (no surprises).
// ------------------------------------------------------------
const pkg = JSON.parse(read(PKG));
pkg.scripts = pkg.scripts || {};

if (typeof pkg.scripts.test !== "string") {
  pkg.scripts.test = "npm run build && ./scripts/audit_hospitality_dist_importable_v1.sh";
  writeIfChanged(PKG, JSON.stringify(pkg, null, 2) + "\n");
  console.log("OK: created scripts.test");
} else if (pkg.scripts.test === "npm run build && ./scripts/audit_hospitality_dist_importable_v1.sh") {
  console.log("OK: scripts.test already canonical");
} else {
  console.log("OK: scripts.test exists (left unchanged): " + pkg.scripts.test);
}

// ------------------------------------------------------------
// 4) Gates (must end with npm run build)
// ------------------------------------------------------------
run("npm test");
run("./scripts/gate_ci_termux_v1.sh");
run("npm run build");
