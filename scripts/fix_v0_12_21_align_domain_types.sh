#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.21: align DomainEvaluator/DomainContext contracts (idempotent)"

node <<'NODE'
import fs from "fs";

function read(p){ return fs.readFileSync(p,"utf8"); }
function writeIfChanged(p, next){
  const cur = fs.existsSync(p) ? read(p) : "";
  if (cur === next) return false;
  fs.writeFileSync(p, next, "utf8");
  return true;
}

const typesPath = "src/shared/types.ts";
if (!fs.existsSync(typesPath)) {
  throw new Error(`Missing ${typesPath}; cannot align contracts.`);
}
const typesSrc = read(typesPath);

// --- Detect DomainContext key for input cache ---
// We want the property that holds parsed CSV tables / input tables.
// Common candidates: cache, inputs, tables, data
const contextBlockMatch =
  typesSrc.match(/export\s+(?:interface|type)\s+DomainContext\s*=?\s*\{[\s\S]*?\}/m);

const contextBlock = contextBlockMatch?.[0] ?? "";
const candidates = ["cache","inputs","tables","data","datasets","sources"];
let ctxKey = candidates.find(k => new RegExp(`\\b${k}\\s*[:?]`, "m").test(contextBlock)) ?? "";

// If we can’t detect it, we fall back to safe `as any` but keep it consistent.
if (!ctxKey) ctxKey = "cache"; // internal fallback key; we will cast ctx as any

// --- Detect DomainResult shape ---
// We need to return whatever DomainEvaluator expects.
// If DomainResult mentions "findings", we’ll return { findings }.
// Otherwise we’ll return { findings } as any (still stable).
const domainResultMatch =
  typesSrc.match(/export\s+(?:interface|type)\s+DomainResult\s*=?\s*\{[\s\S]*?\}/m);
const domainResultBlock = domainResultMatch?.[0] ?? "";
const domainResultHasFindings = /\bfindings\s*[:?]\s*/m.test(domainResultBlock);

// --- Normalize PCI domain file ---
const pciPath = "src/domains/pci.ts";
const pciCanonical = `import type { DomainEvaluator, Finding, DomainContext } from "../shared/types.js";
import { existsSync } from "fs";

// Domain metadata required by shared DomainEvaluator contract
export const pci: DomainEvaluator = {
  id: "pci",
  name: "PCI Compliance",
  evaluate: (ctx: DomainContext) => {
    // Orchestrator injects parsed inputs on DomainContext. We keep tolerant typing.
    const anyCtx = ctx as any;
    const cache = anyCtx?.${ctxKey} ?? anyCtx?.cache ?? anyCtx?.inputs ?? anyCtx?.tables ?? {};
    const findings: Finding[] = [];

    if (!existsSync("inputs/pci_events.csv")) {
      return ${domainResultHasFindings ? "{ findings }" : "({ findings } as any)"};
    }

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
        } as any);
      }
    }

    return ${domainResultHasFindings ? "{ findings }" : "({ findings } as any)"};
  }
};
`;

let changed = false;
changed = writeIfChanged(pciPath, pciCanonical) || changed;

// --- Normalize domain registry (src/domains/index.ts) ---
const registryPath = "src/domains/index.ts";
if (!fs.existsSync(registryPath)) {
  throw new Error(`Missing ${registryPath}; cannot wire domains.`);
}
let reg = read(registryPath);

// Ensure DomainEvaluator import
if (!/import\s+type\s+\{\s*DomainEvaluator\s*\}\s+from\s+["']\.\.\/shared\/types\.js["']/.test(reg)) {
  reg = `import type { DomainEvaluator } from "../shared/types.js";\n` + reg.trimStart();
}

// Ensure pci import uses canonical export
reg = reg
  .replace(/import\s+\{\s*pciEvaluator\s*\}\s+from\s+["']\.\/pci\.js["'];?/g, 'import { pci } from "./pci.js";')
  .replace(/import\s+\{\s*pci\s*\}\s+from\s+["']\.\/pci\.js["'];?/g, 'import { pci } from "./pci.js";');

// Ensure registry entry exists and points at pci
if (/export\s+const\s+DOMAIN_REGISTRY[\s\S]*?\{/.test(reg)) {
  // Replace any prior pci mapping
  reg = reg.replace(/pci\s*:\s*[A-Za-z0-9_]+/g, "pci: pci");
  // Add if missing
  if (!/pci\s*:/.test(reg)) {
    reg = reg.replace(
      /(export\s+const\s+DOMAIN_REGISTRY\s*:\s*Record<string,\s*DomainEvaluator>\s*=\s*\{\s*)/m,
      `$1\n  pci: pci,\n`
    );
  }
}

changed = writeIfChanged(registryPath, reg) || changed;

// --- Normalize orchestrator (src/index.ts) to use correct DomainContext key and DomainResult ---
const indexPath = "src/index.ts";
if (!fs.existsSync(indexPath)) {
  throw new Error(`Missing ${indexPath}; cannot update orchestrator.`);
}
const idx = read(indexPath);

// We’ll rebuild index.ts in-place deterministically to avoid patch drift.
const rebuilt = `import fs from "fs";
import path from "path";
import type { Finding, DomainContext } from "./shared/types.js";
import { DOMAIN_REGISTRY } from "./domains/index.js";

type CsvTable = { headers: string[]; rows: Record<string, string>[] };

function parseCsv(p: string): CsvTable {
  const raw = fs.readFileSync(p, "utf8").trim().split(/\\r?\\n/);
  const headers = raw[0].split(",");
  const rows = raw.slice(1).map((l) => {
    const cols = l.split(",");
    const r: Record<string, string> = {};
    headers.forEach((h, i) => (r[h] = cols[i] ?? ""));
    return r;
  });
  return { headers, rows };
}

function loadInputs(): Record<string, CsvTable> {
  const dir = "inputs";
  const cache: Record<string, CsvTable> = {};
  if (!fs.existsSync(dir)) return cache;

  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith(".csv")) continue;
    const full = path.join(dir, f);
    cache[full] = parseCsv(full);
  }
  return cache;
}

function run(): Finding[] {
  const cache = loadInputs();

  // Align to DomainContext contract from shared types
  const ctx: DomainContext = (${ctxKey === "cache" ? "{ cache }" : `{ ${ctxKey}: cache }`}) as any;

  const findings: Finding[] = [];

  for (const [name, domain] of Object.entries(DOMAIN_REGISTRY)) {
    try {
      const out = domain.evaluate(ctx) as any;

      // DomainResult compatibility: prefer out.findings, fallback to array
      const produced =
        Array.isArray(out) ? out :
        Array.isArray(out?.findings) ? out.findings :
        [];

      findings.push(...produced);
    } catch (e) {
      findings.push({
        severity: "high",
        domain: name,
        summary: "Domain execution failed",
        evidence: { error: String(e) }
      } as any);
    }
  }

  return findings;
}

const findings = run();
for (const f of findings) {
  console.log(\`[\${String(f.severity).toUpperCase()}] [\${f.domain}] \${f.summary}\`);
}
`;

changed = writeIfChanged(indexPath, rebuilt) || changed;

console.log(changed ? "v0.12.21 patch applied." : "v0.12.21 already satisfied (idempotent).");
NODE

npm run build
