import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
const WINDOW_MINUTES = 15;
function ensureDir(p) { if (!existsSync(p))
    mkdirSync(p, { recursive: true }); }
function now() { return new Date().toISOString(); }
function readText(path) { return readFileSync(path, "utf-8"); }
function listInputsDir() {
    if (!existsSync("inputs"))
        return [];
    return readdirSync("inputs").filter(f => f.endsWith(".csv")).map(f => join("inputs", f));
}
function parseYamlList(line) {
    const arr = line.split(":").slice(1).join(":").trim();
    const inside = arr.replace(/^\[/, "").replace(/\]$/, "");
    if (!inside.trim())
        return [];
    return inside.split(",").map(s => s.trim()).filter(Boolean);
}
function loadChecks(yamlPath) {
    const raw = readText(yamlPath).split(/\r?\n/);
    const checks = [];
    let cur = null;
    let inRule = false;
    for (const line of raw) {
        const t = line.trim();
        if (!t || t.startsWith("#"))
            continue;
        if (t.startsWith("- id:")) {
            if (cur)
                checks.push(cur);
            cur = { id: t.split(":")[1].trim(), required_fields: [], optional_fields: [], evidence_fields: [], rule: null };
            inRule = false;
            continue;
        }
        if (!cur)
            continue;
        if (t.startsWith("domain:"))
            cur.domain = t.split(":")[1].trim();
        else if (t.startsWith("severity:"))
            cur.severity = t.split(":")[1].trim();
        else if (t.startsWith("input:"))
            cur.input = t.split(":")[1].trim();
        else if (t.startsWith("required_fields:"))
            cur.required_fields = parseYamlList(t);
        else if (t.startsWith("optional_fields:"))
            cur.optional_fields = parseYamlList(t);
        else if (t.startsWith("evidence_fields:"))
            cur.evidence_fields = parseYamlList(t);
        else if (t.startsWith("rule:"))
            inRule = true;
        else if (inRule && t.startsWith("type:"))
            cur.rule = { type: t.split(":")[1].trim() };
        else if (inRule && t.startsWith("field:"))
            cur.rule.field = t.split(":")[1].trim();
        else if (inRule && t.startsWith("value:"))
            cur.rule.value = t.split(":")[1].trim();
        else if (inRule && t.startsWith("values:"))
            cur.rule.values = parseYamlList(t);
    }
    if (cur)
        checks.push(cur);
    return checks.filter(c => c.id && c.domain && c.severity && c.input && c.rule && c.rule.field);
}
function parseCsv(path) {
    const text = readText(path);
    const lines = text.split(/\r?\n/).filter(l => l.trim().length > 0);
    if (lines.length === 0)
        return { headers: [], rows: [] };
    const headers = lines[0].split(",").map(h => h.trim());
    const rows = [];
    for (let i = 1; i < lines.length; i++) {
        const parts = lines[i].split(",");
        const row = {};
        for (let j = 0; j < headers.length; j++)
            row[headers[j]] = (parts[j] ?? "").trim();
        rows.push(row);
    }
    return { headers, rows };
}
function missingFields(headers, required) {
    const set = new Set(headers);
    return required.filter(f => !set.has(f));
}
function evalRule(rule, row) {
    const v = (row[rule.field] ?? "").toLowerCase();
    if (rule.type === "equals")
        return v === rule.value.toLowerCase();
    if (rule.type === "contains_any")
        return rule.values.map(x => x.toLowerCase()).some(x => v.includes(x));
    return false;
}
function pickEvidence(fields, row) {
    const out = {};
    for (const f of fields)
        if (row[f] !== undefined && row[f] !== "")
            out[f] = row[f];
    return out;
}
function toMillis(ts) {
    if (!ts)
        return null;
    const d = new Date(ts);
    return isNaN(d.getTime()) ? null : d.getTime();
}
function maxSeverity(a, b) {
    const rank = { low: 1, medium: 2, high: 3 };
    return rank[a] >= rank[b] ? a : b;
}
function computeRisk(findings) {
    const weights = { high: 30, medium: 12, low: 3 };
    let high = 0, medium = 0, low = 0;
    for (const f of findings) {
        if (f.domain === "data_quality") {
            low += 1;
            continue;
        }
        if (f.severity === "high")
            high++;
        else if (f.severity === "medium")
            medium++;
        else
            low++;
    }
    const raw = high * weights.high + medium * weights.medium + low * weights.low;
    const score = Math.max(0, Math.min(100, Math.round(100 * (1 - Math.exp(-raw / 60)))));
    let level = "low";
    if (score >= 80)
        level = "critical";
    else if (score >= 55)
        level = "high";
    else if (score >= 25)
        level = "moderate";
    const domainMap = new Map();
    for (const f of findings) {
        if (f.domain === "data_quality")
            continue;
        const cur = domainMap.get(f.domain) ?? { count: 0, max: "low" };
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
function emailRecommendations(sev) {
    if (sev === "high")
        return [
            "Review mailbox forwarding and inbox rules immediately.",
            "Force password reset for affected account(s).",
            "Review OAuth grants and recent sign-in activity.",
            "Preserve logs and artifacts for incident response."
        ];
    if (sev === "medium")
        return [
            "Review recent sign-in and rule change activity.",
            "Confirm whether changes were authorized.",
            "Increase monitoring for the next 24 hours."
        ];
    return [
        "No immediate action required.",
        "Continue monitoring email security events."
    ];
}
function main() {
    const runId = `ago1_${Date.now()}`;
    const timestamp = now();
    ensureDir("artifacts");
    ensureDir("logs");
    const argvInputs = process.argv.slice(2);
    const autoInputs = argvInputs.length ? argvInputs : listInputsDir();
    const findings = [];
    const checks = existsSync("policies/checks.yaml") ? loadChecks("policies/checks.yaml") : [];
    const cache = {};
    for (const inp of autoInputs) {
        try {
            cache[inp] = parseCsv(inp);
        }
        catch {
            findings.push({ severity: "high", domain: "ingestion", summary: `Unreadable input: ${inp}` });
        }
    }
    // Base rule evaluation
    for (const chk of checks) {
        const inpPath = join("inputs", chk.input);
        if (!existsSync(inpPath))
            continue;
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
                const base = {
                    severity: chk.severity,
                    domain: chk.domain,
                    summary: `Policy match: ${chk.id}`,
                    evidence: pickEvidence(chk.evidence_fields, row)
                };
                findings.push(base);
            }
        }
    }
    // Email intrusion correlation & escalation
    const emailFindings = findings.filter(f => f.domain === "email_intrusion");
    if (existsSync("inputs/email_security.csv")) {
        const parsed = cache["inputs/email_security.csv"] ?? parseCsv("inputs/email_security.csv");
        cache["inputs/email_security.csv"] = parsed;
        const byActor = new Map();
        for (const r of parsed.rows) {
            const actor = r["actor"] || "unknown";
            const ts = toMillis(r["timestamp"]);
            if (!ts)
                continue;
            const arr = byActor.get(actor) ?? [];
            arr.push(ts);
            byActor.set(actor, arr);
        }
        for (const [actor, times] of byActor.entries()) {
            times.sort((a, b) => a - b);
            let count = 1;
            for (let i = 1; i < times.length; i++) {
                const diffMin = (times[i] - times[i - 1]) / 60000;
                if (diffMin <= WINDOW_MINUTES)
                    count++;
                else
                    count = 1;
                if (count >= 2) {
                    findings.push({
                        severity: "high",
                        domain: "email_intrusion",
                        summary: `Repeated email security events for actor '${actor}' within ${WINDOW_MINUTES} minutes`,
                        recommendation: emailRecommendations("high")
                    });
                    break;
                }
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
    const md = [];
    md.push(`# AGO-1 Report`);
    md.push(``);
    md.push(`Run ID: \`${runId}\``);
    md.push(`Timestamp: \`${timestamp}\``);
    md.push(``);
    md.push(`## Executive Summary`);
    md.push(`- Risk Score: **${risk.score}/100** (**${risk.level.toUpperCase()}**)`);
    md.push(`- Findings: HIGH=${risk.counts.high}, MEDIUM=${risk.counts.medium}, LOW=${risk.counts.low} (data_quality counted as LOW)`);
    if (risk.top_domains.length)
        md.push(`- Top Domains: ${risk.top_domains.map(d => `${d.domain}(${d.count}, max=${d.maxSeverity})`).join(", ")}`);
    else
        md.push(`- Top Domains: None`);
    md.push(``);
    md.push(`### Recommended Next Steps`);
    if (risk.level === "critical" || risk.level === "high") {
        md.push(`- Initiate same-day human review of HIGH findings and preserve evidence.`);
    }
    else if (risk.level === "moderate") {
        md.push(`- Review MEDIUM findings within 72 hours.`);
    }
    else {
        md.push(`- No urgent action. Continue monitoring and validate data coverage.`);
    }
    if (findings.some(f => f.domain === "data_quality")) {
        md.push(`- Address data gaps flagged under data_quality to improve assessment accuracy.`);
    }
    md.push(``);
    md.push(`## Findings (${findings.length})`);
    if (findings.length === 0)
        md.push(`- None`);
    for (const f of findings) {
        const ev = f.evidence ? Object.entries(f.evidence).map(([k, v]) => `${k}=${v}`).join(", ") : "";
        const rec = f.recommendation ? ` | rec: ${f.recommendation.join("; ")}` : "";
        const dq = f.data_quality ? ` missing=${f.data_quality.missing_required_fields.join("|")} input=${f.data_quality.input}` : "";
        md.push(`- **${f.severity.toUpperCase()}** [${f.domain}] ${f.summary}${ev ? ` — _${ev}_` : ""}${dq ? ` — _${dq}_` : ""}${rec}`);
    }
    md.push(``);
    md.push(`## Inputs`);
    if (autoInputs.length === 0)
        md.push(`- None`);
    for (const i of autoInputs)
        md.push(`- \`${i}\``);
    writeFileSync(mdOut, md.join("\n"), "utf-8");
    writeFileSync(join("logs", `${runId}.log`), `AGO-1 ${runId} completed with ${findings.length} findings; risk=${risk.score}/${risk.level}\n`, "utf-8");
    console.log(`AGO-1 complete: ${runId}`);
    console.log(`Artifacts: ${jsonOut}, ${mdOut}`);
    console.log(`Risk: ${risk.score}/100 (${risk.level})`);
    console.log(`Findings: ${findings.length}`);
}
main();
