#!/usr/bin/env bash
set -euo pipefail

mkdir -p scripts policies

cat > policies/risk_scoring.yaml <<'YAML'
risk_scoring:
  # Domain caps prevent one area from pegging the whole run.
  domain_caps:
    email_intrusion: 35
    loss_prevention: 30
    facility_maintenance: 25
    inventory_reorder: 25
    pci_compliance: 35
    ingestion: 20

  # Base severity weights; still matters, but will be normalized.
  severity_weights:
    high: 20
    medium: 8
    low: 2

  # Diminishing returns within a domain:
  # points for the Nth finding in the same domain are multiplied by this factor.
  domain_decay: 0.65

  # Evidence multiplier: more evidence fields -> higher confidence (up to cap)
  evidence_multiplier:
    min: 0.85
    max: 1.15
YAML

# Patch src/index.ts (idempotent): replace computeRisk with normalized version and loader
node - <<'NODE'
const fs = require("fs");

const path = "src/index.ts";
const src = fs.readFileSync(path, "utf8");

function fail(msg){ console.error("ERROR:", msg); process.exit(1); }

if (!src.includes("function computeRisk(")) fail("computeRisk not found");

const replacement = `function computeRisk(findings: Finding[]): RiskSummary {
  // Normalized scoring: per-domain caps + diminishing returns + evidence weighting
  const defaultCaps: Record<string, number> = {
    email_intrusion: 35,
    loss_prevention: 30,
    facility_maintenance: 25,
    inventory_reorder: 25,
    pci_compliance: 35,
    ingestion: 20
  };

  const severityWeights: Record<Severity, number> = { high: 20, medium: 8, low: 2 };
  let domainDecay = 0.65;
  let evMin = 0.85;
  let evMax = 1.15;

  // best-effort parse of policies/risk_scoring.yaml (simple key:value)
  if (existsSync("policies/risk_scoring.yaml")) {
    const raw = readText("policies/risk_scoring.yaml").split(/\\r?\\n/);
    let inCaps = false, inWeights = false, inEv = false;
    for (const line of raw) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      if (t.startsWith("domain_caps:")) { inCaps = true; inWeights = false; inEv = false; continue; }
      if (t.startsWith("severity_weights:")) { inCaps = false; inWeights = true; inEv = false; continue; }
      if (t.startsWith("evidence_multiplier:")) { inCaps = false; inWeights = false; inEv = true; continue; }
      if (t.startsWith("domain_decay:")) { domainDecay = Number(t.split(":")[1].trim()) || domainDecay; continue; }

      // nested keys look like "email_intrusion: 35"
      if (inCaps && t.includes(":")) {
        const [k, v] = t.split(":").map(x => x.trim());
        if (k && v) defaultCaps[k] = Number(v) || defaultCaps[k];
      }
      if (inWeights && t.includes(":")) {
        const [k, v] = t.split(":").map(x => x.trim());
        if (k === "high" || k === "medium" || k === "low") severityWeights[k] = Number(v) || severityWeights[k];
      }
      if (inEv && t.includes(":")) {
        const [k, v] = t.split(":").map(x => x.trim());
        if (k === "min") evMin = Number(v) || evMin;
        if (k === "max") evMax = Number(v) || evMax;
      }
    }
  }

  let high = 0, medium = 0, low = 0;
  for (const f of findings) {
    if (f.domain === "data_quality") { low += 1; continue; }
    if (f.severity === "high") high++;
    else if (f.severity === "medium") medium++;
    else low++;
  }

  // Score by domain with decay + evidence multiplier, then cap domain points
  const byDomain = new Map<string, Finding[]>();
  for (const f of findings) {
    if (f.domain === "data_quality") continue;
    const arr = byDomain.get(f.domain) ?? [];
    arr.push(f);
    byDomain.set(f.domain, arr);
  }

  const domainPoints = new Map<string, number>();
  for (const [domain, arr] of byDomain.entries()) {
    // sort by severity so highest impacts are counted first
    const rank: Record<Severity, number> = { high: 3, medium: 2, low: 1 };
    arr.sort((a, b) => rank[b.severity] - rank[a.severity]);

    let pts = 0;
    for (let i = 0; i < arr.length; i++) {
      const f = arr[i];
      const base = severityWeights[f.severity];

      const evCount = f.evidence ? Object.keys(f.evidence).length : 0;
      const evMult = Math.max(evMin, Math.min(evMax, 0.85 + Math.min(10, evCount) * 0.03));

      const decay = Math.pow(domainDecay, i);
      pts += base * evMult * decay;
    }

    const cap = defaultCaps[domain] ?? 20;
    domainPoints.set(domain, Math.min(cap, pts));
  }

  // Total available is sum of caps for present domains; normalize to 0..100
  const presentDomains = [...domainPoints.keys()];
  const totalCap = presentDomains.reduce((s, d) => s + (defaultCaps[d] ?? 20), 0) || 1;
  const raw = [...domainPoints.values()].reduce((s, v) => s + v, 0);

  const score = Math.max(0, Math.min(100, Math.round((raw / totalCap) * 100)));

  let level: RiskSummary["level"] = "low";
  if (score >= 85) level = "critical";
  else if (score >= 60) level = "high";
  else if (score >= 30) level = "moderate";

  const top_domains = presentDomains
    .map(domain => {
      const count = (byDomain.get(domain) ?? []).length;
      const maxSeverity = (byDomain.get(domain) ?? []).reduce((m, f) => {
        const r: Record<Severity, number> = { low: 1, medium: 2, high: 3 };
        return r[f.severity] > r[m] ? f.severity : m;
      }, "low" as Severity);
      return { domain, count, maxSeverity };
    })
    .sort((a, b) => b.count - a.count)
    .slice(0, 5);

  return { score, level, weights: severityWeights, counts: { high, medium, low }, top_domains };
}`;

const out = src.replace(/function computeRisk\\([\\s\\S]*?\\n}\\n\\n\\/\\/ --- Recommendations ---/m,
  replacement + "\\n\\n// --- Recommendations ---");

if (out === src) fail("Patch did not apply (computeRisk block not matched)");
fs.writeFileSync(path, out);
NODE

npm run build
