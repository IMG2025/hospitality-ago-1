#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.5: hard reset malformed PCI execution block (idempotent)"

node <<'NODE'
import fs from "fs";

function read(p){ return fs.readFileSync(p,"utf8"); }
function writeIfChanged(p,next){
  const cur = read(p);
  if (cur === next) return false;
  fs.writeFileSync(p,next,"utf8");
  return true;
}

const path = "src/index.ts";
let src = read(path);
let changed = false;

// --------------------------------------------------
// 1) Remove ANY malformed PCI execution remnants
// --------------------------------------------------
const badPatterns = [
  /\/\/ PCI domain[\s\S]*?findings\.push[\s\S]*?\);\s*}/g,
  /\?\s*typeof pci[\s\S]*?:\s*\[\]\s*;/g,
  /findings\.push\(\.\.\.DOMAIN_REGISTRY\.pci[\s\S]*?\);/g
];

for (const rx of badPatterns) {
  src = src.replace(rx, "");
}

// --------------------------------------------------
// 2) Find cache initialization anchor
// --------------------------------------------------
const cacheAnchor = /const\s+cache\s*:\s*Record<[\s\S]*?>\s*=\s*\{\s*\};/m;
const m = src.match(cacheAnchor);

if (!m) {
  throw new Error("Could not locate cache initialization anchor in src/index.ts");
}

const insertAt = m.index! + m[0].length;

// --------------------------------------------------
// 3) Canonical PCI execution block (NO ternary)
// --------------------------------------------------
const pciBlock = `

  // PCI domain (modular, canonical)
  try {
    const res = DOMAIN_REGISTRY.pci.evaluate({ cache, policies: {} } as any);
    const pciFindings =
      (res && Array.isArray((res as any).findings))
        ? (res as any).findings
        : [];
    if (pciFindings.length) findings.push(...pciFindings);
  } catch (e) {
    findings.push({
      severity: "low",
      domain: "data_quality",
      summary: "PCI module execution failed (non-fatal)",
      evidence: { error: String(e) }
    } as any);
  }
`;

// Prevent double insertion
if (!src.includes("PCI domain (modular, canonical)")) {
  src = src.slice(0, insertAt) + pciBlock + src.slice(insertAt);
  changed = true;
}

changed = writeIfChanged(path, src) || changed;

console.log(changed ? "v0.12.5 patch applied." : "v0.12.5 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
