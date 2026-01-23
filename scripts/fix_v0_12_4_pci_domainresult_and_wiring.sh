#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.4: PCI DomainResult + orchestrator wiring (idempotent)"

node <<'NODE'
import fs from "fs";

function read(p){ return fs.readFileSync(p,"utf8"); }
function writeIfChanged(p, next){
  const cur = read(p);
  if (cur === next) return false;
  fs.writeFileSync(p, next, "utf8");
  return true;
}

let changed = false;

// -------------------------------
// 1) Fix src/domains/pci.ts return type -> DomainResult
// -------------------------------
{
  const path = "src/domains/pci.ts";
  let src = read(path);

  // Ensure DomainResult is imported
  if (!src.includes("DomainResult")) {
    src = src.replace(
      /import\s+type\s+\{\s*([^}]+)\s*\}\s+from\s+["']\.\.\/shared\/types\.js["'];/,
      (m, inner) => {
        const parts = inner.split(",").map(s => s.trim()).filter(Boolean);
        if (!parts.includes("DomainResult")) parts.push("DomainResult");
        return `import type { ${parts.join(", ")} } from "../shared/types.js";`;
      }
    );
  }

  // Normalize export name to `pci` if needed (defensive; ok if already)
  src = src.replace(/\bexport\s+const\s+pciEvaluator\b/g, "export const pci");

  // Convert evaluate return to DomainResult shape:
  // - Replace: `return findings;`
  // - With: `{ findings } as any` (tolerant across DomainResult shape differences)
  src = src.replace(/\breturn\s+findings\s*;\s*$/gm, "return ({ findings } as any);");

  // Also handle early return: `if (!existsSync(...)) return findings;`
  src = src.replace(/return\s+findings\s*;/g, "return ({ findings } as any);");

  changed = writeIfChanged(path, src) || changed;
}

// -------------------------------
// 2) Fix src/index.ts PCI call site:
//    - Remove any earlier PCI modular execution block
//    - Re-insert PCI evaluation AFTER cache initialization
//    - Use DomainEvaluator.evaluate(...) (never call evaluator as a function)
//    - Do NOT require `policies` in scope (pass empty object; PCI currently uses cache)
// -------------------------------
{
  const path = "src/index.ts";
  let src = read(path);

  // A) Remove any existing PCI modular block (best-effort patterns)
  src = src.replace(
    /\n\s*\/\/\s*PCI domain\s*\(modular\)[\s\S]*?\n\s*;\s*\n/g,
    "\n"
  );
  src = src.replace(
    /\n\s*\/\*\s*PCI domain\s*\(modular\)[\s\S]*?\*\/\s*\n/g,
    "\n"
  );

  // Also remove the known bad call patterns if still present
  src = src.replace(/\n[^\n]*\?\s*pci\(\{[^\n]*\}\s+as\s+any\)[^\n]*\n/g, "\n");
  src = src.replace(/\n[^\n]*\?\s*pci\.evaluate\(\{[^\n]*\}\s+as\s+any\)[^\n]*\n/g, "\n");
  src = src.replace(/\n[^\n]*DOMAIN_REGISTRY\.pci\(\{[^\n]*\}\)[^\n]*\n/g, "\n");

  // B) Insert correct PCI evaluation block after `const cache = ...` initialization
  const cacheDecl = /const\s+cache\s*:\s*Record<\s*string\s*,\s*\{\s*headers:\s*string\[\]\s*;\s*rows:\s*Record<string,\s*string>\[\]\s*\}\s*>\s*=\s*\{\s*\}\s*;\s*/m;
  const m = src.match(cacheDecl);

  if (!m) {
    throw new Error("Could not find cache initialization in src/index.ts (expected: const cache: Record<string, { headers: string[]; rows: Record<string,string>[] }> = {};)");
  }

  const insertAt = m.index! + m[0].length;

  const pciBlock = `

  // PCI domain (modular)
  try {
    const pciRes = DOMAIN_REGISTRY.pci.evaluate({ cache, policies: {} } as any);
    const pciFindings =
      Array.isArray((pciRes as any)?.findings) ? (pciRes as any).findings :
      Array.isArray(pciRes as any) ? (pciRes as any) :
      [];
    if (pciFindings.length) findings.push(...pciFindings);
  } catch (e) {
    // Defensive: never crash the whole run due to PCI module
    findings.push({
      severity: "low",
      domain: "data_quality",
      summary: "PCI module execution failed (non-fatal)",
      evidence: { error: String(e) }
    } as any);
  }
`;

  // Ensure we don't double-insert if already present
  if (!src.includes("// PCI domain (modular)") || !src.includes("DOMAIN_REGISTRY.pci.evaluate")) {
    src = src.slice(0, insertAt) + pciBlock + src.slice(insertAt);
  }

  changed = writeIfChanged(path, src) || changed;
}

console.log(changed ? "v0.12.4 patch applied." : "v0.12.4 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
