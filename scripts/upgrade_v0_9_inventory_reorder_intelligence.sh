#!/usr/bin/env bash
set -euo pipefail

mkdir -p src policies artifacts logs inputs

cat > policies/inventory_reorder.yaml <<'YAML'
inventory_reorder:
  low_stock_ratio: 0.50            # on_hand <= (par * ratio) => MEDIUM
  critical_stock_ratio: 0.10       # on_hand <= (par * ratio) => HIGH
  stockout_is_high: true           # on_hand <= 0 => HIGH
  default_par_level_qty: 10        # used if par_level_qty missing
  top_n: 5                         # hotspots lists
YAML

# Canonical inventory levels template
cat > inputs/inventory_levels.csv <<'EOF'
business_date,location_id,sku,on_hand_qty,par_level_qty,unit_cost,vendor,notes
EOF

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
  drafts?: { purchase_orders: PurchaseOrderDraft[] };
};

const EMAIL_WINDOW_MINUTES = 15;

function ensureDir(p: string) { if (!existsSync(p)) mkdirSync(p, { recursive: true }); }
function now() { return new Date().toISOString(); }
function readText(path: string): string { return readFileSync(path, "utf-8"); }
function listInputsDir(): string[] {
  if (!existsSync("inputs")) return [];
  return readdirSync("inputs").filter(f => f.endsWith(".csv")).map(f => join("inputs", f));
}

// --- YAML readers (checks.yaml, loss_prevention.yaml, maintenance.yaml, inventory_reorder.yaml) ---
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

type LossPolicy = { spike_threshold_value: number; repeat_window_days: number; repeat_count_threshold: number; top_n: number; };
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

type MaintPolicy = { stale_days_threshold: number; stale_high_priority_days: number; repeat_window_days: number; repeat_count_threshold: number; top_n_vendors: number; };
function loadMaintPolicy(path: string): MaintPolicy {
  const d: MaintPolicy = { stale_days_threshold: 7, stale_high_priority_days: 3, repeat_window_days: 30, repeat_count_threshold: 2, top_n_vendors: 5 };
  if (!existsSync(path)) return d;
  const raw = readText(path).split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  for (const l of raw) {
    if (l.startsWith("stale_days_threshold:")) d.stale_days_threshold = Number(l.split(":")[1].trim()) || d.stale_days_threshold;
    if (l.startsWith("stale_high_priority_days:")) d.stale_high_priority_days = Number(l.split(":")[1].trim()) || d.stale_high_priority_days;
    if (l.startsWith("repeat_window_days:")) d.repeat_window_days = Number(l.split(":")[1].trim()) || d.repeat_window_days;
    if (l.startsWith("repeat_count_threshold:")) d.repeat_count_threshold = Number(l.split(":")[1].trim()) || d.repeat_count_threshold;
    if (l.startsWith("top_n_vendors:")) d.top_n_vendors = Number(l.split(":")[1].trim()) || d.top_n_vendors;
  }
  return d;
}

type ReorderPolicy = {
  low_stock_ratio: number;
  critical_stock_ratio: number;
  stockout_is_high: boolean;
  default_par_level_qty: number;
  top_n: number;
};
function loadReorderPolicy(path: string): ReorderPolicy {
  const d: ReorderPolicy = { low_stock_ratio: 0.5, critical_stock_ratio: 0.1, stockout_is_high: true, default_par_level_qty: 10, top_n: 5 };
  if (!existsSync(path)) return d;
  const raw = readText(path).split(/\r?\n/).map(l => l.trim()).filter(Boolean);
  for (const l of raw) {
    if (l.startsWith("low_stock_ratio:")) d.low_stock_ratio = Number(l.split(":")[1].trim()) || d.low_stock_ratio;
    if (l.startsWith("critical_stock_ratio:")) d.critical_stock_ratio = Number(l.split(":")[1].trim()) || d.critical_stock_ratio;
    if (l.startsWith("stockout_is_high:")) d.stockout_is_high = (l.split(":")[1].trim().toLowerCase() === "true");
    if (l.startsWith("default_par_level_qty:")) d.default_par_level_qty = Number(l.split(":")[1].trim()) || d.default_par_level_qty;
    if (l.startsWith("top_n:")) d.top_n = Number(l.split(":")[1].trim()) || d.top_n;
  }
  return d;
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
function parseDateOnly(x: string | undefined): number | null {
  if (!x) return null;
  const d = new Date(x + "T00:00:00Z");
  return isNaN(d.getTime()) ? null : d.getTime();
}
function parseNumber(x: string | undefined): number | null {
  if (!x) return null;
  const v = Number(String(x).replace(/[^0-9.\-]/g, ""));
  return Number.isFinite(v) ? v : null;
}
function maxSeverity(a: Severity, b: Severity): Severity {
  const rank: Record<Severity, number> = { low: 1, medium: 2, high: 3 };
  return rank[a] >= rank[b] ? a : b;
}

// --- Risk scoring ---
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

// --- Recommendations ---
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

function maintRecommendations(sev: Severity): string[] {
  if (sev === "high") return [
    "Escalate to facilities leadership; validate vendor dispatch and parts availability.",
    "If customer-impacting asset, implement temporary mitigation until repair completed.",
    "Preserve ticket evidence and closure notes for recurring failure analysis."
  ];
  if (sev === "medium") return [
    "Review stale tickets and confirm assignment/ETA.",
    "Validate whether the asset is impacting service levels.",
    "Ensure closure notes capture root cause and corrective action."
  ];
  return ["Monitor ticket aging trends and confirm data coverage."];
}

function reorderRecommendations(sev: Severity): string[] {
  if (sev === "high") return [
    "Initiate same-day replenishment review for critical items.",
    "Confirm open POs, vendor lead times, and receiving schedule.",
    "Validate par levels and unit-of-measure accuracy for the SKU."
  ];
  if (sev === "medium") return [
    "Review reorder candidates and confirm demand forecast.",
    "Validate par level settings and recent usage trends."
  ];
  return ["Monitor inventory levels and confirm data coverage."];
}

function isHighPriority(p: string): boolean {
  const x = (p || "").toLowerCase();
  return ["high", "urgent", "p1", "1", "critical"].includes(x);
}

// --- Engines: loss + maintenance reused from v0.8 ---
function lossEngine(findings: Finding[], cache: Record<string, { headers: string[]; rows: Record<string, string>[] }>, lossPolicy: any) {
  if (!existsSync("inputs/inventory_variance.csv")) return;
  const parsed = cache["inputs/inventory_variance.csv"] ?? parseCsv("inputs/inventory_variance.csv");
  cache["inputs/inventory_variance.csv"] = parsed;

  const req = ["business_date", "location_id", "sku", "variance_value"];
  const miss = missingFields(parsed.headers, req);
  if (miss.length > 0) {
    findings.push({ severity: "low", domain: "data_quality", summary: `Missing required fields for loss prevention evaluation (skipped)`, data_quality: { missing_required_fields: miss, input: "inventory_variance.csv", check_id: "loss_prevention_engine" } });
    return;
  }

  const nowMs = Date.now();
  const windowMs = lossPolicy.repeat_window_days * 24 * 60 * 60 * 1000;

  type VarRow = { dMs: number; business_date: string; location_id: string; sku: string; variance_value: number; variance_qty?: string; notes?: string };
  const rows: VarRow[] = [];
  for (const r of parsed.rows) {
    const d = parseDateOnly(r["business_date"]);
    const v = parseNumber(r["variance_value"]);
    if (d === null || v === null) continue;
    rows.push({ dMs: d, business_date: r["business_date"] ?? "", location_id: r["location_id"] ?? "", sku: r["sku"] ?? "", variance_value: v, variance_qty: r["variance_qty"], notes: r["notes"] });
  }

  const spikes = rows.filter(r => r.variance_value >= lossPolicy.spike_threshold_value);
  for (const s of spikes) {
    findings.push({
      severity: "medium",
      domain: "loss_prevention",
      summary: `Inventory variance spike detected (>= $${lossPolicy.spike_threshold_value})`,
      evidence: { business_date: s.business_date, location_id: s.location_id, sku: s.sku, variance_value: String(s.variance_value), variance_qty: s.variance_qty ?? "", notes: s.notes ?? "" },
      recommendation: lossRecommendations("medium")
    });
  }

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

  const skuTotals = new Map<string, number>();
  const locTotals = new Map<string, number>();
  for (const r of rows) {
    skuTotals.set(r.sku, (skuTotals.get(r.sku) ?? 0) + r.variance_value);
    locTotals.set(r.location_id, (locTotals.get(r.location_id) ?? 0) + r.variance_value);
  }
  const topN = lossPolicy.top_n;
  const topSkus = [...skuTotals.entries()].sort((a,b) => b[1]-a[1]).slice(0, topN);
  if (topSkus.length) findings.push({ severity: "low", domain: "loss_prevention", summary: `Hotspot SKUs by total variance value (top ${topN})`, evidence: Object.fromEntries(topSkus.map(([sku,val], i) => [`sku_${i+1}`, `${sku} ($${Math.round(val)})`])), recommendation: lossRecommendations("low") });

  const topLocs = [...locTotals.entries()].sort((a,b) => b[1]-a[1]).slice(0, topN);
  if (topLocs.length) findings.push({ severity: "low", domain: "loss_prevention", summary: `Hotspot locations by total variance value (top ${topN})`, evidence: Object.fromEntries(topLocs.map(([loc,val], i) => [`location_${i+1}`, `${loc} ($${Math.round(val)})`])), recommendation: lossRecommendations("low") });
}

function maintenanceEngine(findings: Finding[], cache: Record<string, { headers: string[]; rows: Record<string, string>[] }>, mp: any) {
  if (!existsSync("inputs/maintenance.csv")) return;
  const parsed = cache["inputs/maintenance.csv"] ?? parseCsv("inputs/maintenance.csv");
  cache["inputs/maintenance.csv"] = parsed;

  const req = ["ticket_id", "location_id", "asset_id", "issue_type", "priority", "opened_date"];
  const miss = missingFields(parsed.headers, req);
  if (miss.length > 0) {
    findings.push({ severity: "low", domain: "data_quality", summary: `Missing required fields for facility maintenance evaluation (skipped)`, data_quality: { missing_required_fields: miss, input: "maintenance.csv", check_id: "facility_maintenance_engine" } });
    return;
  }

  const nowMs = Date.now();
  const staleMs = mp.stale_days_threshold * 24 * 60 * 60 * 1000;
  const staleHighMs = mp.stale_high_priority_days * 24 * 60 * 60 * 1000;
  const repeatWindowMs = mp.repeat_window_days * 24 * 60 * 60 * 1000;

  type Ticket = { ticket_id: string; location_id: string; asset_id: string; issue_type: string; priority: string; openedMs: number; closedMs: number | null; vendor: string; notes: string; };
  const tickets: Ticket[] = [];
  for (const r of parsed.rows) {
    const openedMs = toMillis(r["opened_date"]) ?? parseDateOnly(r["opened_date"]) ?? null;
    if (openedMs === null) continue;
    const closedMs = toMillis(r["closed_date"]) ?? parseDateOnly(r["closed_date"]) ?? null;
    tickets.push({ ticket_id: r["ticket_id"] ?? "", location_id: r["location_id"] ?? "", asset_id: r["asset_id"] ?? "", issue_type: r["issue_type"] ?? "", priority: r["priority"] ?? "", openedMs, closedMs, vendor: r["vendor"] ?? "", notes: r["notes"] ?? "" });
  }

  for (const t of tickets) {
    if (t.closedMs !== null) continue;
    const ageMs = nowMs - t.openedMs;

    if (isHighPriority(t.priority) && ageMs >= staleHighMs) {
      findings.push({
        severity: "high",
        domain: "facility_maintenance",
        summary: `High-priority ticket is stale (> ${mp.stale_high_priority_days} days)`,
        evidence: { ticket_id: t.ticket_id, location_id: t.location_id, asset_id: t.asset_id, issue_type: t.issue_type, priority: t.priority, opened_date: new Date(t.openedMs).toISOString(), vendor: t.vendor, notes: t.notes },
        recommendation: maintRecommendations("high")
      });
    } else if (ageMs >= staleMs) {
      findings.push({
        severity: "medium",
        domain: "facility_maintenance",
        summary: `Ticket is stale (> ${mp.stale_days_threshold} days)`,
        evidence: { ticket_id: t.ticket_id, location_id: t.location_id, asset_id: t.asset_id, issue_type: t.issue_type, priority: t.priority, opened_date: new Date(t.openedMs).toISOString(), vendor: t.vendor, notes: t.notes },
        recommendation: maintRecommendations("medium")
      });
    }
  }

  const recent = tickets.filter(t => (nowMs - t.openedMs) <= repeatWindowMs);
  const keyCounts = new Map<string, number>();
  for (const t of recent) {
    const key = `${t.location_id}::${t.asset_id}::${t.issue_type}`;
    keyCounts.set(key, (keyCounts.get(key) ?? 0) + 1);
  }
  for (const [key, c] of keyCounts.entries()) {
    if (c >= mp.repeat_count_threshold) {
      const [location_id, asset_id, issue_type] = key.split("::");
      findings.push({
        severity: "high",
        domain: "facility_maintenance",
        summary: `Repeat maintenance issue: ${c} tickets in last ${mp.repeat_window_days} days (location=${location_id}, asset=${asset_id})`,
        evidence: { location_id, asset_id, issue_type, ticket_count: String(c) },
        recommendation: maintRecommendations("high")
      });
    }
  }

  const closed = tickets.filter(t => t.closedMs !== null && t.vendor);
  const vendorAgg = new Map<string, { totalDays: number; count: number }>();
  for (const t of closed) {
    const days = (Number(t.closedMs) - t.openedMs) / (24 * 60 * 60 * 1000);
    const cur = vendorAgg.get(t.vendor) ?? { totalDays: 0, count: 0 };
    cur.totalDays += Math.max(0, days);
    cur.count += 1;
    vendorAgg.set(t.vendor, cur);
  }
  const top = [...vendorAgg.entries()]
    .map(([vendor, v]) => ({ vendor, avgDays: v.totalDays / v.count, count: v.count }))
    .sort((a,b) => b.avgDays - a.avgDays)
    .slice(0, mp.top_n_vendors);

  if (top.length) {
    findings.push({
      severity: "low",
      domain: "facility_maintenance",
      summary: `Vendor lag (avg days-to-close) hotspots (top ${mp.top_n_vendors})`,
      evidence: Object.fromEntries(top.map((v, i) => [`vendor_${i+1}`, `${v.vendor} (avg=${v.avgDays.toFixed(1)}d, n=${v.count})`])),
      recommendation: maintRecommendations("low")
    });
  }
}

// --- Inventory reorder intelligence (v0.9) ---
type PurchaseOrderDraft = {
  vendor: string;
  location_id: string;
  business_date: string;
  lines: Array<{ sku: string; suggested_qty: number; on_hand_qty: number; par_level_qty: number; unit_cost?: number; est_line_cost?: number }>;
  est_total_cost?: number;
  notice_text: string;
};

function inventoryReorderEngine(findings: Finding[], cache: Record<string, { headers: string[]; rows: Record<string, string>[] }>, rp: ReorderPolicy): PurchaseOrderDraft[] {
  if (!existsSync("inputs/inventory_levels.csv")) return [];

  const parsed = cache["inputs/inventory_levels.csv"] ?? parseCsv("inputs/inventory_levels.csv");
  cache["inputs/inventory_levels.csv"] = parsed;

  const req = ["business_date", "location_id", "sku", "on_hand_qty"];
  const miss = missingFields(parsed.headers, req);
  if (miss.length > 0) {
    findings.push({
      severity: "low",
      domain: "data_quality",
      summary: `Missing required fields for inventory reorder evaluation (skipped)`,
      data_quality: { missing_required_fields: miss, input: "inventory_levels.csv", check_id: "inventory_reorder_engine" }
    });
    return [];
  }

  type Row = {
    business_date: string;
    location_id: string;
    sku: string;
    on_hand: number;
    par: number;
    unit_cost?: number;
    vendor: string;
    notes: string;
  };

  const rows: Row[] = [];
  for (const r of parsed.rows) {
    const on = parseNumber(r["on_hand_qty"]);
    if (on === null) continue;
    const par = parseNumber(r["par_level_qty"]) ?? rp.default_par_level_qty;
    const uc = parseNumber(r["unit_cost"]);
    rows.push({
      business_date: r["business_date"] ?? "",
      location_id: r["location_id"] ?? "",
      sku: r["sku"] ?? "",
      on_hand: on,
      par,
      unit_cost: uc ?? undefined,
      vendor: (r["vendor"] ?? "").trim() || "UNKNOWN_VENDOR",
      notes: r["notes"] ?? ""
    });
  }

  // Detect low/critical
  const lowCandidates: Row[] = [];
  const criticalCandidates: Row[] = [];

  for (const x of rows) {
    const criticalThreshold = x.par * rp.critical_stock_ratio;
    const lowThreshold = x.par * rp.low_stock_ratio;

    const isStockout = rp.stockout_is_high && x.on_hand <= 0;
    const isCritical = isStockout || x.on_hand <= criticalThreshold;
    const isLow = !isCritical && x.on_hand <= lowThreshold;

    if (isCritical) criticalCandidates.push(x);
    else if (isLow) lowCandidates.push(x);
  }

  for (const c of criticalCandidates) {
    const suggested = Math.max(0, Math.ceil(c.par - c.on_hand));
    findings.push({
      severity: "high",
      domain: "inventory_reorder",
      summary: `Critical stock risk (on_hand=${c.on_hand} <= ${Math.max(0, c.par * rp.critical_stock_ratio).toFixed(2)} of par=${c.par})`,
      evidence: {
        business_date: c.business_date,
        location_id: c.location_id,
        sku: c.sku,
        on_hand_qty: String(c.on_hand),
        par_level_qty: String(c.par),
        vendor: c.vendor,
        suggested_reorder_qty: String(suggested),
        unit_cost: c.unit_cost !== undefined ? String(c.unit_cost) : "",
        notes: c.notes
      },
      recommendation: reorderRecommendations("high")
    });
  }

  for (const c of lowCandidates) {
    const suggested = Math.max(0, Math.ceil(c.par - c.on_hand));
    findings.push({
      severity: "medium",
      domain: "inventory_reorder",
      summary: `Low stock detected (on_hand=${c.on_hand} <= ${Math.max(0, c.par * rp.low_stock_ratio).toFixed(2)} of par=${c.par})`,
      evidence: {
        business_date: c.business_date,
        location_id: c.location_id,
        sku: c.sku,
        on_hand_qty: String(c.on_hand),
        par_level_qty: String(c.par),
        vendor: c.vendor,
        suggested_reorder_qty: String(suggested),
        unit_cost: c.unit_cost !== undefined ? String(c.unit_cost) : "",
        notes: c.notes
      },
      recommendation: reorderRecommendations("medium")
    });
  }

  // Hotspots summaries
  const riskBySku = new Map<string, number>();
  const riskByLoc = new Map<string, number>();
  for (const r of [...criticalCandidates, ...lowCandidates]) {
    riskBySku.set(r.sku, (riskBySku.get(r.sku) ?? 0) + 1);
    riskByLoc.set(r.location_id, (riskByLoc.get(r.location_id) ?? 0) + 1);
  }

  const topN = rp.top_n;
  const topSkus = [...riskBySku.entries()].sort((a,b) => b[1]-a[1]).slice(0, topN);
  if (topSkus.length) {
    findings.push({
      severity: "low",
      domain: "inventory_reorder",
      summary: `Reorder-risk hotspot SKUs (top ${topN})`,
      evidence: Object.fromEntries(topSkus.map(([sku,cnt], i) => [`sku_${i+1}`, `${sku} (flags=${cnt})`])),
      recommendation: reorderRecommendations("low")
    });
  }

  const topLocs = [...riskByLoc.entries()].sort((a,b) => b[1]-a[1]).slice(0, topN);
  if (topLocs.length) {
    findings.push({
      severity: "low",
      domain: "inventory_reorder",
      summary: `Reorder-risk hotspot locations (top ${topN})`,
      evidence: Object.fromEntries(topLocs.map(([loc,cnt], i) => [`location_${i+1}`, `${loc} (flags=${cnt})`])),
      recommendation: reorderRecommendations("low")
    });
  }

  // Draft purchase order notices (group by vendor + location + business_date)
  const draftMap = new Map<string, PurchaseOrderDraft>();
  const candidates = [...criticalCandidates, ...lowCandidates];

  for (const r of candidates) {
    const suggested = Math.max(0, Math.ceil(r.par - r.on_hand));
    if (suggested <= 0) continue;

    const key = `${r.vendor}::${r.location_id}::${r.business_date}`;
    const cur = draftMap.get(key) ?? {
      vendor: r.vendor,
      location_id: r.location_id,
      business_date: r.business_date,
      lines: [],
      notice_text: ""
    };

    const line: any = { sku: r.sku, suggested_qty: suggested, on_hand_qty: r.on_hand, par_level_qty: r.par };
    if (r.unit_cost !== undefined) {
      line.unit_cost = r.unit_cost;
      line.est_line_cost = Number((r.unit_cost * suggested).toFixed(2));
    }
    cur.lines.push(line);
    draftMap.set(key, cur);
  }

  // finalize notice text + totals
  const drafts = [...draftMap.values()];
  for (const d of drafts) {
    let total = 0;
    for (const l of d.lines) if (l.est_line_cost) total += l.est_line_cost;

    if (total > 0) d.est_total_cost = Number(total.toFixed(2));

    const linesText = d.lines
      .map(l => `- SKU ${l.sku}: suggested_qty=${l.suggested_qty} (on_hand=${l.on_hand_qty}, par=${l.par_level_qty}${l.unit_cost ? `, unit_cost=$${l.unit_cost}` : ""}${l.est_line_cost ? `, est=$${l.est_line_cost}` : ""})`)
      .join("\n");

    d.notice_text =
`DRAFT PURCHASE ORDER NOTICE (NOT SENT)
Vendor: ${d.vendor}
Location: ${d.location_id}
Business Date: ${d.business_date}

Replenishment candidates:
${linesText}

${d.est_total_cost !== undefined ? `Estimated total cost: $${d.est_total_cost}` : `Estimated total cost: (unit_cost not provided)`}

Operator review required:
- Confirm open POs and lead times
- Validate unit-of-measure and par settings
- Approve quantities prior to submission
`;
  }

  return drafts;
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
  const maintPolicy = loadMaintPolicy("policies/maintenance.yaml");
  const reorderPolicy = loadReorderPolicy("policies/inventory_reorder.yaml");

  const cache: Record<string, { headers: string[]; rows: Record<string, string>[] }> = {};
  for (const inp of autoInputs) {
    try { cache[inp] = parseCsv(inp); }
    catch { findings.push({ severity: "high", domain: "ingestion", summary: `Unreadable input: ${inp}` }); }
  }

  // Base checks
  for (const chk of checks) {
    const inpPath = join("inputs", chk.input);
    if (!existsSync(inpPath)) continue;

    const parsed = cache[inpPath] ?? parseCsv(inpPath);
    cache[inpPath] = parsed;

    const missing = missingFields(parsed.headers, chk.required_fields);
    if (missing.length > 0) {
      findings.push({ severity: "low", domain: "data_quality", summary: `Missing required fields for check ${chk.id} (skipped evaluation)`, data_quality: { missing_required_fields: missing, input: chk.input, check_id: chk.id } });
      continue;
    }

    for (const row of parsed.rows) {
      if (evalRule(chk.rule, row)) {
        const base: Finding = { severity: chk.severity, domain: chk.domain, summary: `Policy match: ${chk.id}`, evidence: pickEvidence(chk.evidence_fields, row) };
        if (chk.domain === "email_intrusion") base.recommendation = emailRecommendations(chk.severity);
        findings.push(base);
      }
    }
  }

  // Email correlation
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
          findings.push({ severity: "high", domain: "email_intrusion", summary: `Repeated email security events for actor '${actor}' within ${EMAIL_WINDOW_MINUTES} minutes`, recommendation: emailRecommendations("high") });
          break;
        }
      }
    }
  }

  // Engines
  lossEngine(findings, cache, lossPolicy);
  maintenanceEngine(findings, cache, maintPolicy);
  const poDrafts = inventoryReorderEngine(findings, cache, reorderPolicy);

  if (autoInputs.length === 0) findings.push({ severity: "medium", domain: "ingestion", summary: "No inputs provided and inputs/ is empty." });

  const risk = computeRisk(findings);
  const payload: Ago1Run = { runId, timestamp, inputs: autoInputs, findings, risk, drafts: { purchase_orders: poDrafts } };

  const jsonOut = join("artifacts", `${runId}.json`);
  writeFileSync(jsonOut, JSON.stringify(payload, null, 2), "utf-8");

  // Drafts output (auditable, not sent)
  if (poDrafts.length) {
    const draftsOut = join("artifacts", `${runId}.purchase_orders.txt`);
    const body = poDrafts.map(d => d.notice_text).join("\n---\n\n");
    writeFileSync(draftsOut, body, "utf-8");
  }

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
  if (poDrafts.length) md.push(`- Review draft purchase order notices (artifacts/*.purchase_orders.txt) prior to any vendor submission.`);

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

  md.push(``);
  md.push(`## Draft Outputs`);
  md.push(`- Purchase Orders Drafted: ${poDrafts.length}`);

  writeFileSync(mdOut, md.join("\n"), "utf-8");
  writeFileSync(join("logs", `${runId}.log`), `AGO-1 ${runId} completed with ${findings.length} findings; risk=${risk.score}/${risk.level}; poDrafts=${poDrafts.length}\n`, "utf-8");

  console.log(`AGO-1 complete: ${runId}`);
  console.log(`Artifacts: ${jsonOut}, ${mdOut}`);
  if (poDrafts.length) console.log(`Draft PO notices: artifacts/${runId}.purchase_orders.txt`);
  console.log(`Risk: ${risk.score}/100 (${risk.level})`);
  console.log(`Findings: ${findings.length}`);
}

main();
TS

npm run build
