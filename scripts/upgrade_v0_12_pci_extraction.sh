#!/usr/bin/env bash
set -euo pipefail

echo "Upgrading to v0.12 — extracting PCI domain"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");

if (!src.includes("DOMAIN_REGISTRY")) {
  src = src.replace(
    /function main\(\)\s*{/,
    `
import { DOMAIN_REGISTRY } from "./domains/index.js";

function main() {
`
  );
}

if (!src.includes("pciEvaluator")) {
  src = src.replace(
    /const findings: Finding\[\] = \[\];/,
    `
const findings: Finding[] = [];

// PCI domain (modular)
if (DOMAIN_REGISTRY.pci) {
  findings.push(...DOMAIN_REGISTRY.pci({ cache, policies }));
}
`
  );
}

fs.writeFileSync(path, src, "utf8");
console.log("PCI domain wired into orchestrator.");
NODE

npm run build
