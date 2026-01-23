#!/usr/bin/env bash
set -euo pipefail

echo "Fixing v0.12 PCI extraction: align to shared DomainEvaluator + Finding types"

node <<'NODE'
import fs from "fs";

const typesPath = "src/shared/types.ts";
const pciPath = "src/domains/pci.ts";
const domainsIndexPath = "src/domains/index.ts";
const mainPath = "src/index.ts";

const typesSrc = fs.existsSync(typesPath) ? fs.readFileSync(typesPath, "utf8") : "";

// Detect whether DomainEvaluator is callable or an object with evaluate()
const domainEvaluatorIsCallable =
  /export\s+type\s+DomainEvaluator\s*=\s*\(/.test(typesSrc) ||
  /export\s+type\s+DomainEvaluator\s*=\s*\(\s*ctx/.test(typesSrc);

const domainEvaluatorHasEvaluate =
  /interface\s+DomainEvaluator[\s\S]*evaluate\s*\(/.test(typesSrc) ||
  /type\s+DomainEvaluator[\s\S]*evaluate\s*:\s*\(/.test(typesSrc);

// Detect a context type name if present
let ctxType = "any";
if (/export\s+type\s+DomainContext\b/.test(typesSrc) || /export\s+interface\s+DomainContext\b/.test(typesSrc)) {
  ctxType = "DomainContext";
}
if (/export\s+type\s+EvalContext\b/.test(typesSrc) || /export\s+interface\s+EvalContext\b/.test(typesSrc)) {
  ctxType = "EvalContext";
}

// Detect Finding.recommendation type (string vs string[])
const recommendationIsStringArray =
  /recommendation\?\s*:\s*string\[\]\s*;/.test(typesSrc);

const recValue = recommendationIsStringArray
  ? `[
          "Immediately investigate PCI violation",
          "Preserve evidence for compliance review",
          "Validate PCI scope and controls"
        ]`
  : `"Immediately investigate PCI violation; Preserve evidence for compliance review; Validate PCI scope and controls."`;

// --- Rewrite src/domains/pci.ts (deterministic, idempotent) ---
const pciModule = (() => {
  const header = `import type { DomainEvaluator, Finding${ctxType !== "any" ? `, ${ctxType}` : ""} } from "../shared/types.js";
import { existsSync } from "fs";
`;

  // Build evaluator shape based on detected contract
  if (domainEvaluatorIsCallable && !domainEvaluatorHasEvaluate) {
    return `${header}
export const pciEvaluator: DomainEvaluator = (${ctxType !== "any" ? `ctx: ${ctxType}` : `ctx: any`}) => {
  const { cache } = ctx as any;
  const findings: Finding[] = [];

  if (!existsSync("inputs/pci_events.csv")) return findings;

  const rows = cache?.["inputs/pci_events.csv"]?.rows || [];
  for (const row of rows) {
    if ((row as any).event_type === "pci_violation") {
      findings.push({
        severity: "high",
        domain: "pci",
        summary: "PCI compliance violation detected",
        evidence: row as any,
        recommendation: ${recValue}
      } as any);
    }
  }

  return findings;
};
`;
  }

  // Default: DomainEvaluator is an object with evaluate()
  return `${header}
export const pciEvaluator: DomainEvaluator = {
  evaluate: (${ctxType !== "any" ? `ctx: ${ctxType}` : `ctx: any`}) => {
    const { cache } = ctx as any;
    const findings: Finding[] = [];

    if (!existsSync("inputs/pci_events.csv")) return findings;

    const rows = cache?.["inputs/pci_events.csv"]?.rows || [];
    for (const row of rows) {
      if ((row as any).event_type === "pci_violation") {
        findings.push({
          severity: "high",
          domain: "pci",
          summary: "PCI compliance violation detected",
          evidence: row as any,
          recommendation: ${recValue}
        } as any);
      }
    }

    return findings;
  }
} as any;
`;
})();

fs.mkdirSync("src/domains", { recursive: true });
fs.writeFileSync(pciPath, pciModule, "utf8");

// --- Ensure src/domains/index.ts exports registry with pci ---
let domainsIndex = fs.existsSync(domainsIndexPath) ? fs.readFileSync(domainsIndexPath, "utf8") : "";
if (!domainsIndex.includes(`from "./pci.js"`)) {
  domainsIndex = `import type { DomainEvaluator } from "../shared/types.js";
import { pciEvaluator } from "./pci.js";

export const DOMAIN_REGISTRY: Record<string, DomainEvaluator> = {
  pci: pciEvaluator
};
`;
  fs.writeFileSync(domainsIndexPath, domainsIndex, "utf8");
}

// --- Fix src/index.ts wiring: move PCI call AFTER cache/policies are defined ---
let main = fs.readFileSync(mainPath, "utf8");

// Ensure import exists
if (!main.includes(`from "./domains/index.js"`)) {
  main = main.replace(
    /^(.*\bfrom\s+["']fs["'];\s*)$/m,
    `$1\nimport { DOMAIN_REGISTRY } from "./domains/index.js";`
  );
}

// Remove any previous PCI injection block we added
main = main.replace(
  /\n\/\/ PCI domain \(modular\)[\s\S]*?\n(?=\s*\/\/|\s*const|\s*function|\s*if|\s*for|\s*\w)/g,
  "\n"
);

// Insert PCI evaluation block in a safe location: immediately AFTER cache declaration line (or after it is assigned)
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
  if (Array.isArray(pciFindings) && pciFindings.length) findings.push(...pciFindings);
}
`;

if (!main.includes("// PCI domain (modular)")) {
  // Prefer to insert after `const cache` line if present
  const cacheLine = /const\s+cache\s*:\s*Record<[^;]+>[^;]*;\s*/m;
  if (cacheLine.test(main)) {
    main = main.replace(cacheLine, (m) => `${m}${pciBlock}`);
  } else {
    // Fallback: insert right after `const findings: Finding[] = [];`
    main = main.replace(
      /const\s+findings:\s*Finding\[\]\s*=\s*\[\];/m,
      (m) => `${m}\n${pciBlock}`
    );
  }
}

fs.writeFileSync(mainPath, main, "utf8");

console.log("v0.12 PCI types + wiring fix applied.");
NODE

npm run build
