import fs from "fs";
import path from "path";
import { DOMAIN_REGISTRY } from "./domains/index.js";
function parseCsv(p) {
    const raw = fs.readFileSync(p, "utf8").trim().split(/\r?\n/);
    const headers = raw[0].split(",");
    const rows = raw.slice(1).map((l) => {
        const cols = l.split(",");
        const r = {};
        headers.forEach((h, i) => (r[h] = cols[i] ?? ""));
        return r;
    });
    return { headers, rows };
}
function loadInputs() {
    const dir = "inputs";
    const cache = {};
    if (!fs.existsSync(dir))
        return cache;
    for (const f of fs.readdirSync(dir)) {
        if (!f.endsWith(".csv"))
            continue;
        const full = path.join(dir, f);
        cache[full] = parseCsv(full);
    }
    return cache;
}
function run() {
    const cache = loadInputs();
    // Align to DomainContext contract from shared types
    const ctx = ({ inputs: cache });
    const findings = [];
    for (const [name, domain] of Object.entries(DOMAIN_REGISTRY)) {
        try {
            const out = domain.evaluate(ctx);
            // DomainResult compatibility: prefer out.findings, fallback to array
            const produced = Array.isArray(out) ? out :
                Array.isArray(out?.findings) ? out.findings :
                    [];
            findings.push(...produced);
        }
        catch (e) {
            findings.push({
                severity: "high",
                domain: name,
                summary: "Domain execution failed",
                evidence: { error: String(e) }
            });
        }
    }
    return findings;
}
const findings = run();
for (const f of findings) {
    console.log(`[${String(f.severity).toUpperCase()}] [${f.domain}] ${f.summary}`);
}
