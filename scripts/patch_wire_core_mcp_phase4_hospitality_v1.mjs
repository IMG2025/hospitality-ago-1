#!/usr/bin/env node
/**
 * patch_wire_core_mcp_phase4_hospitality_v1.mjs
 * Idempotent patch:
 * - Adds ago-1-core as dependency
 * - Adds compile-time proof that Hospitality can construct an MCP call via core
 * - Runs npm install
 * - Ends with npm run build
 */
import fs from "node:fs";
import path from "node:path";
import { execSync } from "node:child_process";

function run(cmd) { execSync(cmd, { stdio: "inherit" }); }
function sh(cmd) { return execSync(cmd, { encoding: "utf8" }).trim(); }

const ROOT = sh("git rev-parse --show-toplevel");
const p = (...xs) => path.join(ROOT, ...xs);

function exists(fp) { return fs.existsSync(fp); }
function read(fp) { return fs.readFileSync(fp, "utf8"); }
function mkdirp(dir) { fs.mkdirSync(dir, { recursive: true }); }

function writeIfChanged(fp, next) {
  const prev = exists(fp) ? read(fp) : "";
  if (prev === next) return false;
  mkdirp(path.dirname(fp));
  fs.writeFileSync(fp, next);
  return true;
}

function upsertDependency(pkgPath, name, spec) {
  const pkg = JSON.parse(read(pkgPath));
  pkg.dependencies ||= {};
  if (pkg.dependencies[name] === spec) return { changed: false, pkg };
  pkg.dependencies[name] = spec;
  return { changed: true, pkg };
}

function main() {
  console.log("== Hospitality Phase 4B: wire MCP from ago-1-core ==");

  const changed = [];

  // 1) package.json dependency
  const pkgPath = p("package.json");
  if (!exists(pkgPath)) throw new Error("package.json not found");

  const CORE_SPEC = "github:IMG2025/ago-1-core#master";

  const { changed: depChanged, pkg } = upsertDependency(pkgPath, "ago-1-core", CORE_SPEC);
  if (depChanged) {
    if (writeIfChanged(pkgPath, JSON.stringify(pkg, null, 2) + "\n")) {
      changed.push("package.json (deps: ago-1-core)");
    }
  }

  // 2) Compile-time proof module
  const proofTs = `/**
 * Hospitality Phase 4B — Compile-Time Proof (MCP via ago-1-core)
 *
 * This file intentionally does NOT execute at runtime.
 * It proves Hospitality can build a valid MCP tool request using the core Nexus plane.
 */
import { mcp } from "ago-1-core";

export function hospitalityMcpCompileProof() {
  const transport = mcp.createHttpToolTransport({ baseUrl: "http://127.0.0.1:8787" });

  const req: mcp.ToolRequest = {
    tool: "shared.artifact_registry.read",
    args: {},
    ctx: {
      tenant: "shared",
      actor: "hospitality-ago-1",
      purpose: "hospitality-phase4b-compile-proof",
      classification: "internal",
      traceId: "hospitality-compile-proof"
    }
  };

  // Compile-time validation of call shape + policy surface.
  void mcp.callTool(transport, req);
}
`;
  if (writeIfChanged(p("src", "mcp_phase4b_compile_proof.ts"), proofTs)) {
    changed.push("src/mcp_phase4b_compile_proof.ts");
  }

  console.log("Changed files:", changed.length ? changed : "(no changes; already applied)");

  console.log("== Installing deps (required after package.json change) ==");
  run("npm install --no-audit --no-fund");

  console.log("== Running build (required) ==");
  run("npm run build");

  console.log("== Patch complete ==");
}

main();
