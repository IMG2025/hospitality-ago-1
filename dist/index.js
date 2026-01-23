import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
function ensureDir(p) { if (!existsSync(p))
    mkdirSync(p, { recursive: true }); }
function now() { return new Date().toISOString(); }
function readText(path) { return readFileSync(path, "utf-8"); }
function listInputsDir() {
    if (!existsSync("inputs"))
        return [];
    return readdirSync("inputs")
        .filter(f => f.endsWith(".csv"))
        .map(f => join("inputs", f));
}
function parseYamlList(line) {
    // expects: [a, b, c]
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
        for (let j = 0; j < headers.length; j++) {
            row[headers[j]] = (parts[j] ?? "").trim();
        }
        rows.push(row);
    }
    return { headers, rows };
}
function hasAllFields(headers, required) {
    const set = new Set(headers);
    return required.filter(f => !set.has(f));
}
function evalRule(rule, row) {
    const v = (row[rule.field] ?? "").toLowerCase();
    if (rule.type === "equals")
        return v === rule.value.toLowerCase();
    if (rule.type === "contains_any") {
        const values = rule.values.map(x => x.toLowerCase());
        return values.some(x => v.includes(x));
    }
    return false;
}
function pickEvidence(fields, row) {
    const out = {};
    for (const f of fields) {
        if (row[f] !== undefined && row[f] !== "")
            out[f] = row[f];
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
    const findings = [];
    const checks = existsSync("policies/checks.yaml") ? loadChecks("policies/checks.yaml") : [];
    // Load each input once
    const cache = {};
    for (const inp of autoInputs) {
        try {
            cache[inp] = parseCsv(inp);
        }
        catch {
            findings.push({ severity: "high", domain: "ingestion", summary: `Unreadable input: ${inp}` });
        }
    }
    // Evaluate checks
    for (const chk of checks) {
        const inpPath = join("inputs", chk.input);
        if (!existsSync(inpPath))
            continue;
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
    const payload = { runId, timestamp, inputs: autoInputs, findings };
    const jsonOut = join("artifacts", `${runId}.json`);
    writeFileSync(jsonOut, JSON.stringify(payload, null, 2), "utf-8");
    const mdOut = join("artifacts", `${runId}.md`);
    const mdLines = [];
    mdLines.push(`# AGO-1 Report`);
    mdLines.push(``);
    mdLines.push(`Run ID: \`${runId}\``);
    mdLines.push(`Timestamp: \`${timestamp}\``);
    mdLines.push(``);
    mdLines.push(`## Findings (${findings.length})`);
    if (findings.length === 0)
        mdLines.push(`- None`);
    for (const f of findings) {
        const ev = f.evidence ? Object.entries(f.evidence).map(([k, v]) => `${k}=${v}`).join(", ") : "";
        const dq = f.data_quality ? ` missing=${f.data_quality.missing_required_fields.join("|")} input=${f.data_quality.input}` : "";
        mdLines.push(`- **${f.severity.toUpperCase()}** [${f.domain}] ${f.summary}${ev ? ` — _${ev}_` : ""}${dq ? ` — _${dq}_` : ""}`);
    }
    mdLines.push(``);
    mdLines.push(`## Inputs`);
    if (autoInputs.length === 0)
        mdLines.push(`- None`);
    for (const i of autoInputs)
        mdLines.push(`- \`${i}\``);
    writeFileSync(mdOut, mdLines.join("\n"), "utf-8");
    writeFileSync(join("logs", `${runId}.log`), `AGO-1 ${runId} completed with ${findings.length} findings\n`, "utf-8");
    console.log(`AGO-1 complete: ${runId}`);
    console.log(`Artifacts: ${jsonOut}, ${mdOut}`);
    console.log(`Findings: ${findings.length}`);
}
main();
