#!/usr/bin/env bash
set -euo pipefail

mkdir -p src policies artifacts logs

# Replace src/index.ts with v0.5 scoring + exec summary (keeps v0.4 tolerant ingestion)
cat > src/index.ts <<'TS'
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

type Severity = "low" | "medium" | "high";
type Finding = {
  severity: Severity;
  domain: string;
  summary: string;
  evidence?: Record<string, string>;
  data_quality?: { missing_required_fields: string[]; input: string; check_id: string };
};

type RiskSummary = {
  score: number;                // 0-100
  level: "low" | "moderate" | "high" | "critical";
  weights: Record<Severity, number>;
  counts: Record<Severity, number>;
  top_domains: Array<{ domain: string; count: number; maxSeverity: Severity }>;
};

type Ago1Run = {
  runId: string;
  timestamp: string;
  inputs: string[];
  findings: Finding[];
  risk: RiskSummary;
};

function ensureDir(p: string) { if (!existsSync(p)) mkdirSync(p, { recursive: true }); }
function now() { return new Date().toISOString(); }
function readText(path: string): string { return readFileSync(path, "utf-8"); }

function listInputsDir(): string[] {
  if (!existsSync("inputs")) return [];
  return readdirSync("inputs").filter(f => f.endsWith(".csv")).map(f => join("inputs", f));
}

// Minimal YAML reader for our limited checks.yaml
type Rule =
  | { type: "equals"; field: string; value: string }
  | { type: "contains_any"; field: string; values: string[] };

type Check = {
  id: string;
  domain: string;
  severity: Severity;
  input: string;
  required_fields: string[];
  optional_fields: string[];
  rule: Rule;
  evidence_fields: string[];
};

function parseYamlList(line: string): string[] {
  const arr = line.split(":").slice(1).join(":").trim();
  const inside = arr.replace(/^\[/, "").replace(/\]$/, "");
  if (!inside.trim()) return [];
  return inside.split(",").map(s => s.trim()).filter(Boolean);
}

function loadChecks(yamlPath: string): Check[] {
  const raw = readText(yamlPath).split(/\r?\n/);
  const checks: Check[] = [];
  let cur: any = null;
  let inRule = false;

  for (const line of raw) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;

    if (t.startsWith("- id:")) {
      if (cur) checks.push(cur as Check);
      cur = { id: t.split(":")[1].trim(), required_fields: [], optional_fields: [], evidence_fields: [], rule: null };
      inRule = false;
      continue;
    }
    if (!cur) continue;

    if (t.startsWith("domain:")) cur.domain = t.split(":")[1].trim();
    else if (t.startsWith("severity:")) cur.severity = t.split(":")[1].trim();
    else if (t.startsWith("input:")) cur.input = t.split(":")[1].trim();
    else if (t.startsWith("required_fields:")) cur.required_fields = parseYamlList(t);
    else if (t.startsWith("optional_fields:")) cur.optional_fields = parseYamlList(t);
    else if (t.startsWith("evidence_fields:")) cur.evidence_fields = parseYamlList(t);
    else if (t.startsWith("rule:")) inRule = true;
    else if (inRule && t.startsWith("type:")) cur.rule = { type: t.split(":")[1].trim() } as any;
    else if (inRule && t.startsWith("field:")) cur.rule.field = t.split(":")[1].trim();
    else if (inRule && t.startsWith("value:")) cur.rule.value = t.split(":")[1].trim();
    else if (inRule && t.startsWith("values:")) cur.rule.values = parseYamlList(t);
  }

  if (cur) checks.push(cur as Check);
  return checks.filter(c => c.id && c.domain && c.severity && c.input && c.rule && c.rule.field);
}

function parseCsv(path: string): { headers: string[]; rows: Record<string, string>[] } {
  const text = readText(path);
  const lines = text.split(/\r?\n/).filter(l => l.trim().length > 0);
  if (lines.length === 0) return { headers: [], rows: [] };

  const headers = lines[0].split(",").map(h => h.trim());
  const rows: Record<string, string>[] = [];

  for (let i = 1; i < lines.length; i++) {
    const parts = lines[i].split(",");
    const row: Record<string, string> = {};
    for (let j = 0; j < headers.length; j++) row[headers[j]] = (parts[j] ?? "").trim();
    rows.push(row);
  }
  return { headers, rows };
}

function missingFields(headers: string[], required: string[]): string[] {
  const set = new Set(headers);
  return required.filter(f => !set.has(f));
}

function evalRule(rule: Rule, row: Record<string, string>): boolean {
  const v = (row[rule.field] ?? "").toLowerCase();
  if (rule.type === "equals") return v === rule.value.toLowerCase();
  if (rule.type === "contains_any") return rule.values.map(x => x.toLowerCase()).some(x => v.includes(x));
  return false;
}

function pickEvidence(fields: string[], row: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of fields) if (row[f] !== undefined && row[f] !== "") out[f] = row[f];
  return out;
}

function maxSeverity(a: Severity, b: Severity): Severity {
  const rank: Record<Severity, number> = { low: 1, medium: 2, high: 3 };
  return rank[a] >= rank[b] ? a : b;
}

function computeRisk(findings: Finding[]): RiskSummary {
  // We intentionally down-weight data_quality. It's a governance signal, not direct exposure.
  const weights: Record<Severity, number> = { high: 30, medium: 12, low: 3 };

  let high = 0, medium = 0, low = 0;
  for (const f of findings) {
    if (f.domain === "data_quality") { low += 1; continue; }
    if (f.severity === "high") high++;
    else if (f.severity === "medium") medium++;
    else low++;
  }

  const raw = high * weights.high + medium * weights.medium + low * weights.low;

  // Saturating score: approaches 100 as raw grows.
  const score = Math.max(0, Math.min(100, Math.round(100 * (1 - Math.exp(-raw / 60)))));

  let level: RiskSummary["level"] = "low";
  if (score >= 80) level = "critical";
  else if (score >= 55) level = "high";
  else if (score >= 25) level = "moderate";

  // top domains (excluding data_quality)
  const domainMap = new Map<string, { count: number; max: Severity }>();
  for (const f of findings) {
    if (f.domain === "data_quality") continue;
    const cur = domainMap.get(f.domain) ?? { count: 0, max: "low" as Severity };
    cur.count += 1;
    cur.max = maxSeverity(cur.max, f.severity);
    domainMap.set(f.domain, cur);
  }
  const top_domains = [...domainMap.entries()]
    .map(([domain, v]) => ({ domain, count: v.count, maxSeverity: v.max }))
    .sort((a, b) => b.count - a.count)
    .slice(0, 5);

  return {
    score,
    level,
    weights,
    counts: { high, medium, low },
    top_domains
  };
}

function executiveNextSteps(risk: RiskSummary, findings: Finding[]): string[] {
  const steps: string[] = [];
  if (risk.level === "critical" || risk.level === "high") {
    steps.push("Initiate same-day human review of HIGH findings; preserve evidence artifacts for audit.");
    steps.push("Confirm whether any finding indicates active compromise or policy breach; if yes, follow incident response playbook.");
  } else if (risk.level === "moderate") {
    steps.push("Review MEDIUM findings within 72 hours and confirm corrective actions.");
  } else {
    steps.push("No urgent action. Continue monitoring and validate data coverage.");
  }

  const dq = findings.filter(f => f.domain === "data_quality");
  if (dq.length > 0) steps.push("Address data gaps flagged under data_quality to improve assessment accuracy.");

  return steps;
}

function main() {
  const runId = `ago1_${Date.now()}`;
  const timestamp = now();
  ensureDir("artifacts");
  ensureDir("logs");

  const argvInputs = process.argv.slice(2);
  const autoInputs = argvInputs.length ? argvInputs : listInputsDir();

  const findings: Finding[] = [];
  const checks = existsSync("policies/checks.yaml") ? loadChecks("policies/checks.yaml") : [];

  const cache: Record<string, { headers: string[]; rows: Record<string, string>[] }> = {};
  for (const inp of autoInputs) {
    try { cache[inp] = parseCsv(inp); }
    catch { findings.push({ severity: "high", domain: "ingestion", summary: `Unreadable input: ${inp}` }); }
  }

  for (const chk of checks) {
    const inpPath = join("inputs", chk.input);
    if (!existsSync(inpPath)) continue;

    const parsed = cache[inpPath] ?? parseCsv(inpPath);
    cache[inpPath] = parsed;

    const missing = missingFields(parsed.headers, chk.required_fields);
    if (missing.length > 0) {
      findings.push({
        severity: "low",
        domain: "data_quality",
        summary: `Missing required fields for check ${chk.id} (skipped evaluation)`,
        data_quality: { missing_required_fields: missing, input: chk.input, check_id: chk.id }
      });
      continue;
    }

    for (const row of parsed.rows) {
      if (evalRule(chk.rule, row)) {
        findings.push({
          severity: chk.severity,
          domain: chk.domain,
          summary: `Policy match: ${chk.id}`,
          evidence: pickEvidence(chk.evidence_fields, row)
        });
      }
    }
  }

  if (autoInputs.length === 0) {
    findings.push({ severity: "medium", domain: "ingestion", summary: "No inputs provided and inputs/ is empty." });
  }

  const risk = computeRisk(findings);
  const payload: Ago1Run = { runId, timestamp, inputs: autoInputs, findings, risk };

  const jsonOut = join("artifacts", `${runId}.json`);
  writeFileSync(jsonOut, JSON.stringify(payload, null, 2), "utf-8");

  const mdOut = join("artifacts", `${runId}.md`);
  const md: string[] = [];
  md.push(`# AGO-1 Report`);
  md.push(``);
  md.push(`Run ID: \`${runId}\``);
  md.push(`Timestamp: \`${timestamp}\``);
  md.push(``);
  md.push(`## Executive Summary`);
  md.push(`- Risk Score: **${risk.score}/100** (**${risk.level.toUpperCase()}**)`);
  md.push(`- Findings: HIGH=${risk.counts.high}, MEDIUM=${risk.counts.medium}, LOW=${risk.counts.low} (data_quality counted as LOW)`);
  if (risk.top_domains.length) {
    md.push(`- Top Domains: ${risk.top_domains.map(d => `${d.domain}(${d.count}, max=${d.maxSeverity})`).join(", ")}`);
  } else {
    md.push(`- Top Domains: None`);
  }
  md.push(``);
  md.push(`### Recommended Next Steps`);
  for (const s of executiveNextSteps(risk, findings)) md.push(`- ${s}`);

  md.push(``);
  md.push(`## Findings (${findings.length})`);
  if (findings.length === 0) md.push(`- None`);
  for (const f of findings) {
    const ev = f.evidence ? Object.entries(f.evidence).map(([k,v]) => `${k}=${v}`).join(", ") : "";
    const dq = f.data_quality ? ` missing=${f.data_quality.missing_required_fields.join("|")} input=${f.data_quality.input}` : "";
    md.push(`- **${f.severity.toUpperCase()}** [${f.domain}] ${f.summary}${ev ? ` — _${ev}_` : ""}${dq ? ` — _${dq}_` : ""}`);
  }

  md.push(``);
  md.push(`## Inputs`);
  if (autoInputs.length === 0) md.push(`- None`);
  for (const i of autoInputs) md.push(`- \`${i}\``);

  writeFileSync(mdOut, md.join("\n"), "utf-8");
  writeFileSync(join("logs", `${runId}.log`), `AGO-1 ${runId} completed with ${findings.length} findings; risk=${risk.score}/${risk.level}\n`, "utf-8");

  console.log(`AGO-1 complete: ${runId}`);
  console.log(`Artifacts: ${jsonOut}, ${mdOut}`);
  console.log(`Risk: ${risk.score}/100 (${risk.level})`);
  console.log(`Findings: ${findings.length}`);
}

main();
TS

npm run build
