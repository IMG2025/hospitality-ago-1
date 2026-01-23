#!/usr/bin/env bash
set -euo pipefail

echo "Upgrading AGO-1 to v0.10 (PCI Risk Domain) [fixed for src/index.ts]"

mkdir -p policies inputs

# --- Policy pack (idempotent overwrite) ---
cat > policies/pci.yaml <<'YAML'
pci:
  name: "PCI Operational Risk Sentinel"
  mode: "file-first"
  boundaries:
    - no cardholder_data
    - artifacts_only
  windows:
    repeated_minutes: 60
  severities:
    high:
      - pos_admin_login_off_hours
      - remote_access_enabled
      - firewall_rule_changed
      - repeated_admin_failures
    medium:
      - antivirus_disabled
      - patch_failed
      - log_retention_gap
    low:
      - user_role_changed
      - single_admin_login
YAML

# --- Input stub (only create if missing) ---
if [ ! -f inputs/pci_events.csv ]; then
cat > inputs/pci_events.csv <<'CSV'
event_type,actor,location_id,ip,timestamp,detail
CSV
fi

# --- Patch src/index.ts (idempotent) ---
node - <<'NODE'
const fs = require("fs");

const file = "src/index.ts";
const src = fs.readFileSync(file, "utf8");

function fail(msg){ console.error("ERROR:", msg); process.exit(1); }
function write(out){ fs.writeFileSync(file, out, "utf8"); console.log("Patched src/index.ts"); }

if (!src.includes("function computeRisk(")) fail("computeRisk not found in src/index.ts");

// 1) Ensure computeRisk cap table includes pci_compliance (idempotent)
let out = src;
if (!out.includes("pci_compliance")) {
  out = out.replace(
    "ingestion: 20",
    "ingestion: 20,\n    pci_compliance: 35"
  );
}

// 2) Add PCI evaluation helpers + evaluator (idempotent)
// We will insert just BEFORE the line that contains: // --- Recommendations ---
const insertAnchor = "\n\n// --- Recommendations ---";
const anchorIdx = out.indexOf(insertAnchor);
if (anchorIdx === -1) fail("Anchor not found: // --- Recommendations ---");

if (!out.includes("PCI Compliance")) {
  const pciBlock = `

// --- PCI Compliance (file-first) ---
type PciEvent = {
  event_type: string;
  actor?: string;
  location_id?: string;
  ip?: string;
  timestamp?: string;
  detail?: string;
};

function isOffHours(ts?: string): boolean {
  if (!ts) return false;
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return false;
  const hr = d.getUTCHours();
  return (hr < 11 || hr > 23); // coarse UTC heuristic; improves with real tz later
}

function pciRecommendations(sev: Severity): string {
  if (sev === "high") return "Initiate same-day security review; confirm POS/admin changes; preserve logs and access records; validate remote access and firewall changes; coordinate with POS vendor if needed.";
  if (sev === "medium") return "Validate endpoint protections (AV/patching), confirm logging/retention, and document remediation steps for audit readiness.";
  return "Record change for audit trail; confirm change approval and least-privilege alignment.";
}

function evalPciCompliance(rows: PciEvent[]): Finding[] {
  const findings: Finding[] = [];
  if (!rows || rows.length === 0) return findings;

  // Normalize
  const events = rows
    .filter(r => (r.event_type || "").trim().length > 0)
    .map(r => ({
      event_type: (r.event_type || "").trim(),
      actor: (r.actor || "").trim() || "unknown",
      location_id: (r.location_id || "").trim() || "unknown",
      ip: (r.ip || "").trim() || "unknown",
      timestamp: (r.timestamp || "").trim(),
      detail: (r.detail || "").trim()
    }));

  // Simple rules
  for (const e of events) {
    const off = isOffHours(e.timestamp);
    const et = e.event_type;

    // HIGH signals
    if (et === "remote_access_enabled" || et === "firewall_rule_changed") {
      findings.push({
        severity: "high",
        domain: "pci_compliance",
        summary: \`PCI-relevant change: \${et} (loc=\${e.location_id}, actor=\${e.actor})\`,
        recommendation: pciRecommendations("high"),
        evidence: { event_type: et, location_id: e.location_id, actor: e.actor, ip: e.ip, timestamp: e.timestamp, detail: e.detail }
      });
    }

    if (et === "pos_admin_login" && off) {
      findings.push({
        severity: "high",
        domain: "pci_compliance",
        summary: \`POS admin login off-hours (loc=\${e.location_id}, actor=\${e.actor})\`,
        recommendation: pciRecommendations("high"),
        evidence: { event_type: et, location_id: e.location_id, actor: e.actor, ip: e.ip, timestamp: e.timestamp, detail: e.detail }
      });
    }

    // MEDIUM signals
    if (et === "antivirus_disabled" || et === "patch_failed" || et === "log_retention_gap") {
      findings.push({
        severity: "medium",
        domain: "pci_compliance",
        summary: \`PCI control weakness: \${et} (loc=\${e.location_id})\`,
        recommendation: pciRecommendations("medium"),
        evidence: { event_type: et, location_id: e.location_id, actor: e.actor, ip: e.ip, timestamp: e.timestamp, detail: e.detail }
      });
    }

    // LOW signals
    if (et === "user_role_changed" || et === "single_admin_login") {
      findings.push({
        severity: "low",
        domain: "pci_compliance",
        summary: \`PCI audit trail event: \${et} (loc=\${e.location_id})\`,
        recommendation: pciRecommendations("low"),
        evidence: { event_type: et, location_id: e.location_id, actor: e.actor, ip: e.ip, timestamp: e.timestamp, detail: e.detail }
      });
    }
  }

  // Correlation: repeated admin failures within 60 minutes per actor/location
  const windowMs = 60 * 60 * 1000;
  const failures = events.filter(e => e.event_type === "admin_auth_failed" && e.timestamp);
  const byKey = new Map<string, number[]>();
  for (const f of failures) {
    const t = new Date(f.timestamp).getTime();
    if (Number.isNaN(t)) continue;
    const key = \`\${f.actor}|\${f.location_id}\`;
    const arr = byKey.get(key) ?? [];
    arr.push(t);
    byKey.set(key, arr);
  }

  for (const [key, times] of byKey.entries()) {
    times.sort((a,b)=>a-b);
    let count = 1;
    for (let i=1; i<times.length; i++) {
      if (times[i] - times[i-1] <= windowMs) count++;
      else count = 1;
      if (count >= 3) {
        const [actor, location_id] = key.split("|");
        findings.push({
          severity: "high",
          domain: "pci_compliance",
          summary: \`Repeated admin auth failures within 60 minutes (actor=\${actor}, loc=\${location_id})\`,
          recommendation: pciRecommendations("high"),
          evidence: { actor, location_id, failure_count: String(count) }
        });
        break;
      }
    }
  }

  return findings;
}
`;
  out = out.slice(0, anchorIdx) + pciBlock + out.slice(anchorIdx);
}

// 3) Wire ingestion into main run (idempotent)
// We look for the place where other CSV inputs are loaded and findings are pushed.
// We'll inject near the other domain evaluations by searching for "inventory_levels.csv" as a stable anchor.
if (!out.includes("inputs/pci_events.csv")) {
  // Insert just after the last known input mention if present; else after "files" ingestion begins.
  const anchor = "inputs/maintenance.csv";
  const aIdx = out.indexOf(anchor);
  if (aIdx === -1) {
    // fallback: near start of main() after files are resolved
    const fallback = "const findings: Finding[] = [];";
    const fIdx = out.indexOf(fallback);
    if (fIdx === -1) fail("Could not find insertion point for PCI ingestion");
    const insertAt = fIdx + fallback.length;
    out = out.slice(0, insertAt) + "\n\n  // PCI input (optional)\n  // NOTE: file-first; no cardholder data\n" + out.slice(insertAt);
  } else {
    // Inject a pci read/eval block near other file reads; best-effort
    const insertAt = aIdx + anchor.length;
    out = out.slice(0, insertAt) + "\n" + out.slice(insertAt);
  }

  // Now inject a concrete PCI block by replacing the first occurrence of the maintenance ingestion section end marker.
  // We'll search for a safe anchor: "evalFacilityMaintenance" call presence.
  const callAnchor = "evalFacilityMaintenance";
  const cIdx = out.indexOf(callAnchor);
  if (cIdx === -1) {
    // If facility maintenance isn't present, we still inject near end before report generation by anchoring on "const risk = computeRisk"
    const rAnchor = "const risk = computeRisk(findings);";
    const rIdx = out.indexOf(rAnchor);
    if (rIdx === -1) fail("Could not find risk compute anchor to inject PCI");
    const pciRun = `
  // --- PCI Compliance (optional) ---
  const pciRows = readCsvMaybe("inputs/pci_events.csv");
  if (pciRows.ok) {
    findings.push(...evalPciCompliance(pciRows.rows as any));
  } else if (pciRows.reason) {
    findings.push({ severity: "low", domain: "data_quality", summary: \`PCI input skipped: \${pciRows.reason}\`, recommendation: "Provide inputs/pci_events.csv when available." });
  }
`;
    out = out.slice(0, rIdx) + pciRun + out.slice(rIdx);
  } else {
    // inject after the facility maintenance evaluation block (best-effort)
    // find a nearby "findings.push(" after facility maintenance and insert after next newline
    const rAnchor = "const risk = computeRisk(findings);";
    const rIdx = out.indexOf(rAnchor);
    if (rIdx === -1) fail("Could not find risk compute anchor");
    const pciRun = `
  // --- PCI Compliance (optional) ---
  const pciRows = readCsvMaybe("inputs/pci_events.csv");
  if (pciRows.ok) {
    findings.push(...evalPciCompliance(pciRows.rows as any));
  } else if (pciRows.reason) {
    findings.push({ severity: "low", domain: "data_quality", summary: \`PCI input skipped: \${pciRows.reason}\`, recommendation: "Provide inputs/pci_events.csv when available." });
  }
`;
    out = out.slice(0, rIdx) + pciRun + out.slice(rIdx);
  }
}

// 4) Ensure helper exists: readCsvMaybe (idempotent)
// If your code already has a tolerant reader, we reuse it. If not, we add a minimal one.
if (!out.includes("function readCsvMaybe(")) {
  const anchor = "function readText(";
  const aIdx = out.indexOf(anchor);
  if (aIdx === -1) fail("Could not find anchor to insert readCsvMaybe");
  const insert = `
function readCsvMaybe(path: string): { ok: true; rows: any[] } | { ok: false; reason: string } {
  try {
    if (!existsSync(path)) return { ok: false, reason: "missing file" };
    const txt = readText(path).trim();
    if (!txt) return { ok: false, reason: "empty file" };
    // assumes existing parseCsv function is present
    const rows = parseCsv(txt);
    if (!rows || rows.length === 0) return { ok: false, reason: "no rows" };
    return { ok: true, rows };
  } catch (e: any) {
    return { ok: false, reason: e?.message || "read error" };
  }
}

`;
  out = out.slice(0, aIdx) + insert + out.slice(aIdx);
}

fs.writeFileSync(file, out, "utf8");
console.log("PCI policy + ingestion wired.");
NODE

npm run build
