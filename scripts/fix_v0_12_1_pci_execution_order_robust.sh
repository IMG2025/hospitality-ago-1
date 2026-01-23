#!/usr/bin/env bash
set -euo pipefail

echo "Fixing PCI execution order (robust anchors: policies -> cache)"

node <<'NODE'
import fs from "fs";

const file = "src/index.ts";
let src = fs.readFileSync(file, "utf8");

// 1) Remove any existing PCI execution block(s) to make this idempotent.
// We remove blocks that start with the comment and include the braces block.
src = src.replace(/\n\s*\/\/ PCI domain \(modular\)[\s\S]*?\n\s*\}\s*\n/g, "\n");

// 2) Build the PCI block we want to insert (scoped, safe, tolerant)
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

// 3) Choose insertion point.
// Prefer AFTER: "const policies = ...;" (any RHS), else AFTER: "const cache = ...;"
const policiesDecl = [...src.matchAll(/(^\s*const\s+policies\s*=\s*[\s\S]*?;\s*$)/gm)];
const cacheDecl    = [...src.matchAll(/(^\s*const\s+cache\s*=\s*[\s\S]*?;\s*$)/gm)];

let insertAt = -1;

if (policiesDecl.length > 0) {
  const m = policiesDecl[policiesDecl.length - 1];
  insertAt = m.index! + m[0].length;
  console.log("Anchor selected: const policies = ...;");
} else if (cacheDecl.length > 0) {
  const m = cacheDecl[cacheDecl.length - 1];
  insertAt = m.index! + m[0].length;
  console.log("Anchor selected: const cache = ...; (fallback)");
} else {
  throw new Error("Could not find anchor: neither `const policies = ...;` nor `const cache = ...;` exists in src/index.ts");
}

// 4) Insert PCI block once (idempotent because we remove prior block above)
src = src.slice(0, insertAt) + "\n" + pciBlock + "\n" + src.slice(insertAt);

fs.writeFileSync(file, src, "utf8");
console.log("PCI execution block relocated (robust).");
NODE

npm run build
