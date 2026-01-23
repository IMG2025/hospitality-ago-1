#!/usr/bin/env bash
set -euo pipefail

mkdir -p src artifacts logs policies inputs docs

# --- Update policies/checks.yaml to include required/optional fields + rules ---
cat > policies/checks.yaml <<'YAML'
checks:
  - id: email_forwarding_rule_created
    domain: email_intrusion
    severity: high
    input: email_security.csv
    required_fields: [event_type, detail]
    optional_fields: [timestamp, actor, ip, geo]
    rule:
      type: contains_any
      field: event_type
      values: [rule_created, rule_modified]
    evidence_fields: [event_type, detail, actor, ip, geo, timestamp]

  - id: email_suspicious_login_failures
    domain: email_intrusion
    severity: medium
    input: email_security.csv
    required_fields: [event_type]
    optional_fields: [timestamp, actor, ip, geo, detail]
    rule:
      type: equals
      field: event_type
      value: login_failure
    evidence_fields: [event_type, actor, ip, geo, timestamp]

  - id: pci_admin_access_change
    domain: pci
    severity: high
    input: pci_events.csv
    required_fields: [event_type, detail]
    optional_fields: [timestamp, system, actor, asset_id]
    rule:
      type: contains_any
      field: event_type
      values: [admin_access_changed, config_changed]
    evidence_fields: [event_type, system, actor, asset_id, timestamp, detail]

  - id: maintenance_ticket_overdue
    domain: maintenance
    severity: medium
    input: maintenance.csv
    required_fields: [status, due_date]
    optional_fields: [opened_date, location_id, asset, issue, priority, last_update]
    rule:
      type: equals
      field: status
      value: open
    evidence_fields: [status, due_date, asset, issue, location_id, priority, opened_date]
YAML

# --- Update input contracts doc to explicitly allow missing fields ---
cat > docs/input_contracts.md <<'EOF'
# AGO-1 Input Contracts (v0.4)

These are *canonical targets*. Real exports may omit fields. AGO-1 will:
- operate with partial data
- produce `data_quality` findings for missing required fields per check
- never crash on missing columns

## email_security.csv (canonical)
- timestamp (ISO8601) [optional]
- event_type [required by some checks]
- actor (user/email) [optional]
- ip [optional]
- geo [optional]
- detail [optional/required depending on check]

## pci_events.csv (canonical)
- timestamp (ISO8601) [optional]
- system [optional]
- event_type [required by some checks]
- actor [optional]
- asset_id [optional]
- detail [optional/required depending on check]

## maintenance.csv (canonical)
- opened_date (YYYY-MM-DD) [optional]
- location_id [optional]
- asset [optional]
- issue [optional]
- priority (low|medium|high) [optional]
- status (open|in_progress|closed) [required by some checks]
- due_date (YYYY-MM-DD) [required by some checks]
- last_update (ISO8601) [optional]
EOF

# --- Templates (headers only) ---
cat > inputs/email_security.csv <<'EOF'
timestamp,event_type,actor,ip,geo,detail
EOF
cat > inputs/pci_events.csv <<'EOF'
timestamp,system,event_type,actor,asset_id,detail
EOF
cat > inputs/maintenance.csv <<'EOF'
opened_date,location_id,asset,issue,priority,status,due_date,last_update
EOF

# --- Replace src/index.ts with data-tolerant ingestion + checks ---
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
type Ago1Run = { runId: string; timestamp: string; inputs: string[]; findings: Finding[] };

function ensureDir(p: string) { if (!existsSync(p)) mkdirSync(p, { recursive: true }); }
function now() { return new Date().toISOString(); }
function readText(path: string): string { return readFileSync(path, "utf-8"); }

function listInputsDir(): string[] {
  if (!existsSync("inputs")) return [];
  return readdirSync("inputs")
    .filter(f => f.endsWith(".csv"))
    .map(f => join("inputs", f));
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
  // expects: [a, b, c]
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
      cur = {
        id: t.split(":")[1].trim(),
        required_fields: [],
        optional_fields: [],
        evidence_fields: [],
        rule: null
      };
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
    for (let j = 0; j < headers.length; j++) {
      row[headers[j]] = (parts[j] ?? "").trim();
    }
    rows.push(row);
  }

  return { headers, rows };
}

function hasAllFields(headers: string[], required: string[]): string[] {
  const set = new Set(headers);
  return required.filter(f => !set.has(f));
}

function evalRule(rule: Rule, row: Record<string, string>): boolean {
  const v = (row[rule.field] ?? "").toLowerCase();
  if (rule.type === "equals") return v === rule.value.toLowerCase();
  if (rule.type === "contains_any") {
    const values = rule.values.map(x => x.toLowerCase());
    return values.some(x => v.includes(x));
  }
  return false;
}

function pickEvidence(fields: string[], row: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const f of fields) {
    if (row[f] !== undefined && row[f] !== "") out[f] = row[f];
  }
  return out;
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

  // Load each input once
  const cache: Record<string, { headers: string[]; rows: Record<string, string>[] }> = {};
  for (const inp of autoInputs) {
    try {
      cache[inp] = parseCsv(inp);
    } catch {
      findings.push({ severity: "high", domain: "ingestion", summary: `Unreadable input: ${inp}` });
    }
  }

  // Evaluate checks
  for (const chk of checks) {
    const inpPath = join("inputs", chk.input);
    if (!existsSync(inpPath)) continue;

    const parsed = cache[inpPath] ?? parseCsv(inpPath);
    cache[inpPath] = parsed;

    const missing = hasAllFields(parsed.headers, chk.required_fields);
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

  const payload: Ago1Run = { runId, timestamp, inputs: autoInputs, findings };

  const jsonOut = join("artifacts", `${runId}.json`);
  writeFileSync(jsonOut, JSON.stringify(payload, null, 2), "utf-8");

  const mdOut = join("artifacts", `${runId}.md`);
  const mdLines: string[] = [];
  mdLines.push(`# AGO-1 Report`);
  mdLines.push(``);
  mdLines.push(`Run ID: \`${runId}\``);
  mdLines.push(`Timestamp: \`${timestamp}\``);
  mdLines.push(``);
  mdLines.push(`## Findings (${findings.length})`);
  if (findings.length === 0) mdLines.push(`- None`);
  for (const f of findings) {
    const ev = f.evidence ? Object.entries(f.evidence).map(([k,v]) => `${k}=${v}`).join(", ") : "";
    const dq = f.data_quality ? ` missing=${f.data_quality.missing_required_fields.join("|")} input=${f.data_quality.input}` : "";
    mdLines.push(`- **${f.severity.toUpperCase()}** [${f.domain}] ${f.summary}${ev ? ` — _${ev}_` : ""}${dq ? ` — _${dq}_` : ""}`);
  }
  mdLines.push(``);
  mdLines.push(`## Inputs`);
  if (autoInputs.length === 0) mdLines.push(`- None`);
  for (const i of autoInputs) mdLines.push(`- \`${i}\``);

  writeFileSync(mdOut, mdLines.join("\n"), "utf-8");
  writeFileSync(join("logs", `${runId}.log`), `AGO-1 ${runId} completed with ${findings.length} findings\n`, "utf-8");

  console.log(`AGO-1 complete: ${runId}`);
  console.log(`Artifacts: ${jsonOut}, ${mdOut}`);
  console.log(`Findings: ${findings.length}`);
}

main();
TS

npm run build
