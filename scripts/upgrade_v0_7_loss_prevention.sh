#!/usr/bin/env bash
set -euo pipefail

mkdir -p src policies artifacts logs inputs

# Add loss-prevention policy thresholds (simple + tunable)
cat > policies/loss_prevention.yaml <<'YAML'
loss_prevention:
  spike_threshold_value: 250        # USD variance_value triggers a spike
  repeat_window_days: 7             # lookback for repeat patterns
  repeat_count_threshold: 2         # repeats within window escalate
  top_n: 5                          # hotspots lists
YAML

# Ensure canonical inventory variance template exists
cat > inputs/inventory_variance.csv <<'EOF'
business_date,location_id,sku,expected_qty,actual_qty,variance_qty,variance_value,notes
EOF

# Replace src/index.ts with v0.7 loss prevention intelligence added (keeps v0.6 email + v0.5 scoring)
cat > src/index.ts <<'TS'
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

type Severity = "low" | "medium" | "high";
type Finding = {
  severity: Severity;
  domain: string;
  summary: string;
  evidence?: Record<string, string>;
  recommendation?: string[];
  data_quality?: { missing_required_fields: string[]; input: string; check_id: string };
};

type RiskSummary = {
  score: number;
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

const EMAIL_WINDOW_MINUTES = 15;

function ensureDir(p: string) { if (!existsSync(p)) mkdirSync(p, { recursive: true }); }
function now() { return new Date().toISOString(); }
function readText(path: string): string { return readFileSync(path, "utf-8"); }

function listInputsDir(): string[] {
  if (!existsSync("inputs")) return [];
  return readdirSync("inputs").filter(f => f.endsWith(".csv")).map(f => join("inputs", f));
}

// --- Minimal YAML readers for checks.yaml and loss_prevention.yaml ---
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

type LossPolicy = {
  spike_threshold_value: number;
  repeat_window_days: number;
  repeat_count_threshold: number;
  top_n: number;
};

function loadLossPolicy(path: string): LossPolicy {
  const defaults: LossPolicy = { spike_threshold_value: 250, repeat_window_days: 7, repeat_count_threshold: 2, top_n: 5 };
  if (!existsSync(path)) return defaults;

  const raw = readText(path).split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  for (const l of raw) {
    if (l.startsWith("spike_threshold_value:")) defaults.spike_threshold_value = Number(l.split(":")[1].trim()) || defaults.spike_threshold_value;
    if (l.startsWith("repeat_window_days:")) defaults.repeat_window_days = Number(l.split(":")[1].trim()) || defaults.repeat_window_days;
    if (l.startsWith("repeat_count_threshold:")) defaults.repeat_count_threshold = Number(l.split(":")[1].trim()) || defaults.repeat_count_threshold;
    if (l.startsWith("top_n:")) defaults.top_n = Number(l.split(":")[1].trim()) || defaults.top_n;
  }
  return defaults;
}

// --- CSV utilities ---
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

function toMillis(ts?: string): number | null {
  if (!ts) return null;
  const d = new Date(ts);
  return isNaN(d.getTime()) ? null : d.getTime();
}

function maxSeverity(a: Severity, b: Severity): Severity {
  const rank: Record<Severity, number> = { low: 1, medium: 2, high: 3 };
  return rank[a] >= rank[b] ? a : b;
}

// --- Risk scoring (from v0.5) ---
function computeRisk(findings: Finding[]): RiskSummary {
  const weights: Record<Severity, number> = { high: 30, medium: 12, low: 3 };

  let high = 0, medium = 0, low = 0;
  for (const f of findings) {
    if (f.domain === "data_quality") { low += 1; continue; }
    if (f.severity === "high") high++;
    else if (f.severity === "medium") medium++;
    else low++;
  }

  const raw = high * weights.high + medium * weights.medium + low * weights.low;
  const score = Math.max(0, Math.min(100, Math.round(100 * (1 - Math.exp(-raw / 60)))));

  let level: RiskSummary["level"] = "low";
  if (score >= 80) level = "critical";
  else if (score >= 55) level = "high";
  else if (score >= 25) level = "moderate";

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

  return { score, level, weights, counts: { high, medium, low }, top_domains };
}

// --- Email recommendations & correlation (from v0.6) ---
function emailRecommendations(sev: Severity): string[] {
  if (sev === "high") return [
    "Review mailbox forwarding and inbox rules immediately.",
    "Force password reset for affected account(s).",
    "Review OAuth grants and recent sign-in activity.",
    "Preserve logs and artifacts for incident response."
  ];
  if (sev === "medium") return [
    "Review recent sign-in and rule change activity.",
    "Confirm whether changes were authorized.",
    "Increase monitoring for the next 24 hours."
  ];
  return ["No immediate action required.", "Continue monitoring email security events."];
}

// --- Loss prevention recommendations ---
function lossRecommendations(sev: Severity): string[] {
  if (sev === "high") return [
    "Validate inventory counts and receiving records for affected SKU/location/date.",
    "Review waste/comp/void logs for the same period (no individual attribution).",
    "Confirm vendor deliveries and invoice quantities; check for unit-of-measure mismatches.",
    "Increase cycle counts for affected SKU(s) for the next 7 days."
  ];
  if (sev === "medium") return [
    "Review variance drivers (waste, spoilage, comps) for affected SKU/location/date.",
    "Spot-check receiving and storage controls for affected SKU(s)."
  ];
  return ["Monitor variance trends and confirm data coverage."];
}

// --- Loss prevention engine ---
function parseNumber(x: string | undefined): number | null {
  if (!x) return null;
  const v = Number(String(x).replace(/[^0-9.\-]/g, ""));
  return Number.isFinite(v) ? v : null;
}
function parseDateOnly(x: string | undefined): number | null {
  if (!x) return null;
  // Treat YYYY-MM-DD as UTC midnight
  const d = new Date(x + "T00:00:00Z");
  return isNaN(d.getTime()) ? null : d.getTime();
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
  const lossPolicy = loadLossPolicy("policies/loss_prevention.yaml");

  const cache: Record<string, { headers: string[]; rows: Record<string, string>[] }> = {};
  for (const inp of autoInputs) {
    try { cache[inp] = parseCsv(inp); }
    catch { findings.push({ severity: "high", domain: "ingestion", summary: `Unreadable input: ${inp}` }); }
  }

  // Base checks evaluation (email, pci, maintenance)
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
        const base: Finding = {
          severity: chk.severity,
          domain: chk.domain,
          summary: `Policy match: ${chk.id}`,
          evidence: pickEvidence(chk.evidence_fields, row)
        };
        if (chk.domain === "email_intrusion") base.recommendation = emailRecommendations(chk.severity);
        findings.push(base);
      }
    }
  }

  // Email correlation (15-minute window)
  if (existsSync("inputs/email_security.csv")) {
    const parsed = cache["inputs/email_security.csv"] ?? parseCsv("inputs/email_security.csv");
    cache["inputs/email_security.csv"] = parsed;

    const byActor = new Map<string, number[]>();
    for (const r of parsed.rows) {
      const actor = r["actor"] || "unknown";
      const ts = toMillis(r["timestamp"]);
      if (!ts) continue;
      const arr = byActor.get(actor) ?? [];
      arr.push(ts);
      byActor.set(actor, arr);
    }

    for (const [actor, times] of byActor.entries()) {
      times.sort((a, b) => a - b);
      let count = 1;
      for (let i = 1; i < times.length; i++) {
        const diffMin = (times[i] - times[i - 1]) / 60000;
        if (diffMin <= EMAIL_WINDOW_MINUTES) count++;
        else count = 1;

        if (count >= 2) {
          findings.push({
            severity: "high",
            domain: "email_intrusion",
            summary: `Repeated email security events for actor '${actor}' within ${EMAIL_WINDOW_MINUTES} minutes`,
            recommendation: emailRecommendations("high")
          });
          break;
        }
      }
    }
  }

  // Loss prevention: variance spikes + repeats + hotspots
  if (existsSync("inputs/inventory_variance.csv")) {
    const parsed = cache["inputs/inventory_variance.csv"] ?? parseCsv("inputs/inventory_variance.csv");
    cache["inputs/inventory_variance.csv"] = parsed;

    // Required fields for loss engine
    const req = ["business_date", "location_id", "sku", "variance_value"];
    const miss = missingFields(parsed.headers, req);
    if (miss.length > 0) {
      findings.push({
        severity: "low",
        domain: "data_quality",
        summary: `Missing required fields for loss prevention evaluation (skipped)`,
        data_quality: { missing_required_fields: miss, input: "inventory_variance.csv", check_id: "loss_prevention_engine" }
      });
    } else {
      const nowMs = Date.now();
      const windowMs = lossPolicy.repeat_window_days * 24 * 60 * 60 * 1000;

      type VarRow = { dMs: number; business_date: string; location_id: string; sku: string; variance_value: number; variance_qty?: string; notes?: string };
      const rows: VarRow[] = [];

      for (const r of parsed.rows) {
        const d = parseDateOnly(r["business_date"]);
        const v = parseNumber(r["variance_value"]);
        if (d === null || v === null) continue;
        rows.push({
          dMs: d,
          business_date: r["business_date"] ?? "",
          location_id: r["location_id"] ?? "",
          sku: r["sku"] ?? "",
          variance_value: v,
          variance_qty: r["variance_qty"],
          notes: r["notes"]
        });
      }

      // Spike findings
      const spikes = rows.filter(r => r.variance_value >= lossPolicy.spike_threshold_value);
      for (const s of spikes) {
        findings.push({
          severity: "medium",
          domain: "loss_prevention",
          summary: `Inventory variance spike detected (>= $${lossPolicy.spike_threshold_value})`,
          evidence: {
            business_date: s.business_date,
            location_id: s.location_id,
            sku: s.sku,
            variance_value: String(s.variance_value),
            variance_qty: s.variance_qty ?? "",
            notes: s.notes ?? ""
          },
          recommendation: lossRecommendations("medium")
        });
      }

      // Repeat pattern escalation: same location+sku spikes >= repeat_count_threshold in window
      const recentSpikes = spikes.filter(r => (nowMs - r.dMs) <= windowMs);
      const keyCounts = new Map<string, { count: number; totalValue: number }>();
      for (const r of recentSpikes) {
        const key = `${r.location_id}::${r.sku}`;
        const cur = keyCounts.get(key) ?? { count: 0, totalValue: 0 };
        cur.count += 1;
        cur.totalValue += r.variance_value;
        keyCounts.set(key, cur);
      }

      for (const [key, v] of keyCounts.entries()) {
        if (v.count >= lossPolicy.repeat_count_threshold) {
          const [location_id, sku] = key.split("::");
          findings.push({
            severity: "high",
            domain: "loss_prevention",
            summary: `Repeat variance pattern: ${v.count} spikes in last ${lossPolicy.repeat_window_days} days (location=${location_id}, sku=${sku})`,
            evidence: { location_id, sku, spike_count: String(v.count), total_variance_value: String(Math.round(v.totalValue)) },
            recommendation: lossRecommendations("high")
          });
        }
      }

      // Hotspots: top SKUs and locations by variance_value (absolute)
      const skuTotals = new Map<string, number>();
      const locTotals = new Map<string, number>();
      for (const r of rows) {
        skuTotals.set(r.sku, (skuTotals.get(r.sku) ?? 0) + r.variance_value);
        locTotals.set(r.location_id, (locTotals.get(r.location_id) ?? 0) + r.variance_value);
      }

      const topN = lossPolicy.top_n;

      const topSkus = [...skuTotals.entries()].sort((a,b) => b[1]-a[1]).slice(0, topN);
      if (topSkus.length) {
        findings.push({
          severity: "low",
          domain: "loss_prevention",
          summary: `Hotspot SKUs by total variance value (top ${topN})`,
          evidence: Object.fromEntries(topSkus.map(([sku,val], i) => [`sku_${i+1}`, `${sku} ($${Math.round(val)})`])),
          recommendation: lossRecommendations("low")
        });
      }

      const topLocs = [...locTotals.entries()].sort((a,b) => b[1]-a[1]).slice(0, topN);
      if (topLocs.length) {
        findings.push({
          severity: "low",
          domain: "loss_prevention",
          summary: `Hotspot locations by total variance value (top ${topN})`,
          evidence: Object.fromEntries(topLocs.map(([loc,val], i) => [`location_${i+1}`, `${loc} ($${Math.round(val)})`])),
          recommendation: lossRecommendations("low")
        });
      }
    }
  }

  if (autoInputs.length === 0) {
    findings.push({ severity: "medium", domain: "ingestion", summary: "No inputs provided and inputs/ is empty." });
  }

  const risk = computeRisk(findings);
  const payload = { runId, timestamp, inputs: autoInputs, findings, risk };

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
  if (risk.top_domains.length) md.push(`- Top Domains: ${risk.top_domains.map(d => `${d.domain}(${d.count}, max=${d.maxSeverity})`).join(", ")}`);
  else md.push(`- Top Domains: None`);
  md.push(``);
  md.push(`### Recommended Next Steps`);
  if (risk.level === "critical" || risk.level === "high") md.push(`- Initiate same-day human review of HIGH findings and preserve evidence.`);
  else if (risk.level === "moderate") md.push(`- Review MEDIUM findings within 72 hours.`);
  else md.push(`- No urgent action. Continue monitoring and validate data coverage.`);
  if (findings.some(f => f.domain === "data_quality")) md.push(`- Address data gaps flagged under data_quality to improve assessment accuracy.`);

  md.push(``);
  md.push(`## Findings (${findings.length})`);
  if (findings.length === 0) md.push(`- None`);
  for (const f of findings) {
    const ev = f.evidence ? Object.entries(f.evidence).map(([k,v]) => `${k}=${v}`).join(", ") : "";
    const rec = f.recommendation ? ` | rec: ${f.recommendation.join("; ")}` : "";
    const dq = f.data_quality ? ` missing=${f.data_quality.missing_required_fields.join("|")} input=${f.data_quality.input}` : "";
    md.push(`- **${f.severity.toUpperCase()}** [${f.domain}] ${f.summary}${ev ? ` — _${ev}_` : ""}${dq ? ` — _${dq}_` : ""}${rec}`);
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
