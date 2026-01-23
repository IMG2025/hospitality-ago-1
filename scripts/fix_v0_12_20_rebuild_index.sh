#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.20: rebuild src/index.ts orchestrator from clean spec"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";

const rebuilt = `import fs from "fs";
import path from "path";
import type { Finding, DomainContext } from "./shared/types.js";
import { DOMAIN_REGISTRY } from "./domains/index.js";

type CsvTable = { headers: string[]; rows: Record<string,string>[] };

function parseCsv(p: string): CsvTable {
  const raw = fs.readFileSync(p, "utf8").trim().split(/\\r?\\n/);
  const headers = raw[0].split(",");
  const rows = raw.slice(1).map(l => {
    const cols = l.split(",");
    const r: Record<string,string> = {};
    headers.forEach((h,i) => r[h] = cols[i] ?? "");
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
  const ctx: DomainContext = { cache };
  const findings: Finding[] = [];

  for (const [name, domain] of Object.entries(DOMAIN_REGISTRY)) {
    try {
      const out = domain.evaluate(ctx);
      if (Array.isArray(out)) findings.push(...out);
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
  console.log(
    \`[\${f.severity.toUpperCase()}] [\${f.domain}] \${f.summary}\`
  );
}
`;

fs.writeFileSync(path, rebuilt, "utf8");
console.log("src/index.ts rebuilt cleanly.");
NODE

npm run build
