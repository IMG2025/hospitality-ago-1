#!/usr/bin/env bash
set -euo pipefail

echo "Fixing PCI execution order (move after cache + policies init)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");

// 1. Remove any existing PCI execution blocks (safe + idempotent)
src = src.replace(
  /\n\/\/ PCI domain \(modular\)[\s\S]*?\n\}/g,
  ""
);

// 2. Find the correct anchor: AFTER cache AND policies exist
// We anchor after the policies loader invocation
const anchorRegex =
  /(const\s+policies\s*=\s*loadPolicies\([\s\S]*?\);\s*)/m;

if (!anchorRegex.test(src)) {
  throw new Error("Could not find policies initialization anchor");
}

// 3. Inject PCI execution block in the correct scope
const pciBlock = `
  // PCI domain (modular)
  {
    const pci = (DOMAIN_REGISTRY as any).pci;
    const pciFindings =
      typeof pci === "function"
        ? pci({ cache, policies } as any)
        : typeof pci?.evaluate === "function"
          ? pci.evaluate({ cache, policies } as any)
          : [];
    if (Array.isArray(pciFindings) && pciFindings.length) {
      findings.push(...pciFindings);
    }
  }
`;

src = src.replace(anchorRegex, `$1\n${pciBlock}\n`);

fs.writeFileSync(path, src, "utf8");
console.log("PCI execution block relocated successfully.");
NODE

npm run build
