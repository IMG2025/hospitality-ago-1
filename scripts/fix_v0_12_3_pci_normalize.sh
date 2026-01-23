#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.3: normalize PCI domain export + registry wiring (idempotent)"

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

// ---- 1) Normalize src/domains/pci.ts to export `pci: DomainEvaluator` ----
{
  const path = "src/domains/pci.ts";
  const src = read(path);

  // If already normalized, keep logic but ensure it exports `pci`
  const already = /export\s+const\s+pci\s*:\s*DomainEvaluator\b/.test(src);

  if (!already) {
    // Build canonical file content (minimal, typed, no `as any` where avoidable)
    const canonical = `import type { DomainEvaluator, Finding, DomainContext } from "../shared/types.js";
import { existsSync } from "fs";

export const pci: DomainEvaluator = {
  evaluate: (ctx: DomainContext) => {
    // cache is injected by orchestrator; keep tolerant typing
    const cache = (ctx as any)?.cache as any;
    const findings: Finding[] = [];

    if (!existsSync("inputs/pci_events.csv")) return findings;

    const rows = cache?.["inputs/pci_events.csv"]?.rows ?? [];
    for (const row of rows) {
      if ((row as any).event_type === "pci_violation") {
        findings.push({
          severity: "high",
          domain: "pci",
          summary: "PCI compliance violation detected",
          evidence: row as any,
          recommendation:
            "Immediately investigate PCI violation; Preserve evidence for compliance review; Validate PCI scope and controls."
        });
      }
    }

    return findings;
  }
};
`;
    changed = writeIfChanged(path, canonical) || changed;
  }
}

// ---- 2) Normalize src/domains/index.ts to import/export `pci` ----
{
  const path = "src/domains/index.ts";
  let src = read(path);

  // Replace imports to canonical
  src = src
    .replace(/import\s+type\s+\{\s*DomainEvaluator\s*\}\s+from\s+["']\.\.\/shared\/types\.js["'];?\s*\n?/g, "")
    .replace(/import\s+\{\s*pciEvaluator\s*\}\s+from\s+["']\.\/pci\.js["'];?/g, 'import { pci } from "./pci.js";')
    .replace(/import\s+\{\s*pci\s*\}\s+from\s+["']\.\/pci\.js["'];?/g, 'import { pci } from "./pci.js";');

  // Ensure DomainEvaluator import exists once
  if (!/import\s+type\s+\{\s*DomainEvaluator\s*\}\s+from\s+["']\.\.\/shared\/types\.js["']/.test(src)) {
    src = `import type { DomainEvaluator } from "../shared/types.js";\n` + src.trimStart();
  }

  // Normalize registry entry
  // Handles: pci: pciEvaluator, pci: pci, or other spacing
  src = src.replace(/pci\s*:\s*pciEvaluator\b/g, "pci: pci");

  // If registry missing pci entry, add it (safe best-effort)
  if (/export\s+const\s+DOMAIN_REGISTRY\s*:\s*Record<string,\s*DomainEvaluator>\s*=\s*\{/.test(src) && !/pci\s*:/.test(src)) {
    src = src.replace(
      /(export\s+const\s+DOMAIN_REGISTRY\s*:\s*Record<string,\s*DomainEvaluator>\s*=\s*\{\s*)/m,
      `$1\n  pci: pci,\n`
    );
  }

  changed = writeIfChanged(path, src) || changed;
}

console.log(changed ? "v0.12.3 patch applied." : "v0.12.3 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
