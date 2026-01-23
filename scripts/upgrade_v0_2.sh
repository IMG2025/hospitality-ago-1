#!/usr/bin/env bash
set -euo pipefail

mkdir -p src/policies src/ingest artifacts logs

# Policy checks config (simple, deterministic)
cat > policies/checks.yaml <<'YAML'
checks:
  - id: email_forwarding_rule_created
    domain: email_intrusion
    severity: high
    match:
      file: email_security.csv
      contains: ["forward", "rule", "created"]

  - id: pci_admin_access_change
    domain: pci
    severity: high
    match:
      file: pci_events.csv
      contains: ["admin", "access", "changed"]

  - id: inventory_variance_spike
    domain: loss_prevention
    severity: medium
    match:
      file: inventory_variance.csv
      contains: ["variance", "spike"]

  - id: maintenance_ticket_overdue
    domain: maintenance
    severity: medium
    match:
      file: maintenance.csv
      contains: ["overdue"]
YAML

# Replace src/index.ts with v0.2 logic (still minimal, file-first)
cat > src/index.ts <<'TS'
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

type Severity = "low" | "medium" | "high";
type Finding = { severity: Severity; domain: string; summary: string; evidence?: string };
type Ago1Run = { runId: string; timestamp: string; inputs: string[]; findings: Finding[] };

function ensureDir(p: string) { if (!existsSync(p)) mkdirSync(p, { recursive: true }); }

function now() { return new Date().toISOString(); }

function readText(path: string): string {
  return readFileSync(path, "utf-8");
}

// Ultra-simple YAML parser for our limited structure (no deps)
// This intentionally supports only what we wrote in policies/checks.yaml.
function loadChecks(yamlPath: string) {
  const raw = readText(yamlPath).split(/\r?\n/);
  const checks: Array<{id:string; domain:string; severity:Severity; file:string; contains:string[]}> = [];
  let cur: any = null;

  for (const line of raw) {
    const t = line.trim();
    if (t.startsWith("- id:")) {
      if (cur) checks.push(cur);
      cur = { id: t.split(":")[1].trim(), contains: [] as string[] };
    } else if (cur && t.startsWith("domain:")) cur.domain = t.split(":")[1].trim();
    else if (cur && t.startsWith("severity:")) cur.severity = t.split(":")[1].trim() as Severity;
    else if (cur && t.startsWith("file:")) cur.file = t.split(":")[1].trim();
    else if (cur && t.startsWith("contains:")) {
      const arr = t.substring("contains:".length).trim();
      // format: ["a", "b"]
      const items = arr.replace(/^\[/,"").replace(/\]$/,"").split(",").map(s=>s.trim().replace(/^"|"$/g,"")).filter(Boolean);
      cur.contains = items;
    }
  }
  if (cur) checks.push(cur);
  return checks;
}

function listInputsDir(): string[] {
  if (!existsSync("inputs")) return [];
  return readdirSync("inputs").filter(f => f.endsWith(".csv") || f.endsWith(".txt")).map(f => join("inputs", f));
}

function main() {
  const runId = `ago1_${Date.now()}`;
  const timestamp = now();
  ensureDir("artifacts");
  ensureDir("logs");

  const inputs = process.argv.slice(2);
  const autoInputs = inputs.length ? inputs : listInputsDir();
  const findings: Finding[] = [];

  let checks: ReturnType<typeof loadChecks> = [];
  if (existsSync("policies/checks.yaml")) checks = loadChecks("policies/checks.yaml");

  for (const chk of checks) {
    const target = join("inputs", chk.file);
    if (!existsSync(target)) continue;

    const text = readText(target).toLowerCase();
    const hit = chk.contains.every(k => text.includes(k.toLowerCase()));
    if (hit) {
      findings.push({
        severity: chk.severity,
        domain: chk.domain,
        summary: `Policy match: ${chk.id}`,
        evidence: `inputs/${chk.file} contains ${chk.contains.join(", ")}`
      });
    }
  }

  if (autoInputs.length === 0) {
    findings.push({ severity: "medium", domain: "ingestion", summary: "No inputs provided and inputs/ is empty." });
  }

  const payload: Ago1Run = { runId, timestamp, inputs: autoInputs, findings };

  const jsonOut = join("artifacts", `${runId}.json`);
  writeFileSync(jsonOut, JSON.stringify(payload, null, 2), "utf-8");

  const mdOut = join("artifacts", `${runId}.md`);
  const md = [
    `# AGO-1 Report`,
    ``,
    `Run ID: \`${runId}\``,
    `Timestamp: \`${timestamp}\``,
    ``,
    `## Findings (${findings.length})`,
    ...(findings.length ? findings.map(f => `- **${f.severity.toUpperCase()}** [${f.domain}] ${f.summary}${f.evidence ? ` — _${f.evidence}_` : ""}`) : [`- None`]),
    ``,
    `## Inputs`,
    ...(autoInputs.length ? autoInputs.map(i => `- \`${i}\``) : [`- None`])
  ].join("\n");
  writeFileSync(mdOut, md, "utf-8");

  writeFileSync(join("logs", `${runId}.log`), `AGO-1 ${runId} completed with ${findings.length} findings\n`, "utf-8");

  console.log(`AGO-1 complete: ${runId}`);
  console.log(`Artifacts: ${jsonOut}, ${mdOut}`);
  console.log(`Findings: ${findings.length}`);
}

main();
TS

npm run build
