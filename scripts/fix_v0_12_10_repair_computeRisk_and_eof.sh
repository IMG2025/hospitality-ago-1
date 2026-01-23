#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.10: repair computeRisk() + trim EOF after main() (idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");
let changed = false;

// 1) Replace computeRisk() with a canonical implementation (robust match: from function header to its closing brace)
const computeRiskRegex =
  /function\s+computeRisk\s*\([\s\S]*?\n}\n(?=\s*(function|export|const|let|var|type|interface|\/\*|\/\/|$))/m;

if (!computeRiskRegex.test(src)) {
  throw new Error("Could not locate computeRisk() function block to repair.");
}

const canonicalComputeRisk = `function computeRisk(findings: Finding[]) {
  // BEGIN v0.12.10 COMPUTE_RISK
  const severityWeights: Record<Severity, number> = { low: 1, medium: 2, high: 3 };

  const counts = findings.reduce(
    (acc, f) => {
      acc[f.severity] += 1;
      return acc;
    },
    { low: 0, medium: 0, high: 0 } as Record<Severity, number>
  );

  // Score: weighted average scaled to 0..100
  const total = counts.low + counts.medium + counts.high;
  const weighted =
    counts.low * severityWeights.low +
    counts.medium * severityWeights.medium +
    counts.high * severityWeights.high;

  const avg = total === 0 ? 0 : weighted / total; // 0..3
  const score = Math.round((avg / 3) * 100);

  const level =
    score >= 85 ? "CRITICAL" :
    score >= 60 ? "HIGH" :
    score >= 30 ? "MEDIUM" :
    "LOW";

  // top domains (count + max severity)
  const order: Record<Severity, number> = { low: 1, medium: 2, high: 3 };
  const byDomain = new Map<string, { count: number; maxSeverity: Severity }>();

  for (const f of findings) {
    const cur = byDomain.get(f.domain);
    if (!cur) {
      byDomain.set(f.domain, { count: 1, maxSeverity: f.severity });
    } else {
      cur.count += 1;
      if (order[f.severity] > order[cur.maxSeverity]) cur.maxSeverity = f.severity;
    }
  }

  const top_domains = Array.from(byDomain.entries())
    .map(([domain, v]) => ({ domain, count: v.count, maxSeverity: v.maxSeverity }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 5);

  return { score, level, weights: severityWeights, counts, top_domains };
  // END v0.12.10 COMPUTE_RISK
}
`;

const next = src.replace(computeRiskRegex, canonicalComputeRisk + "\n");
if (next !== src) {
  src = next;
  changed = true;
}

// 2) Trim any dangling garbage after main(); (this removes the orphan } } } } } at EOF safely)
const mainIdx = src.lastIndexOf("main();");
if (mainIdx !== -1) {
  const end = mainIdx + "main();".length;
  const trimmed = src.slice(0, end) + "\n";
  if (trimmed !== src) {
    src = trimmed;
    changed = true;
  }
}

// 3) Ensure file ends with newline
if (!src.endsWith("\n")) {
  src += "\n";
  changed = true;
}

fs.writeFileSync(path, src, "utf8");
console.log(changed ? "v0.12.10 patch applied." : "v0.12.10 already satisfied (idempotent).");
NODE

# Must end with build (per rule)
npm run build
