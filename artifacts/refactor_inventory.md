# AGO-1 Refactor Inventory (v0.11)

Generated: 2026-01-23T03:11:42Z

## Key Anchors in src/index.ts

### Functions (top-level)

33:function ensureDir(p: string) { if (!existsSync(p)) mkdirSync(p, { recursive: true }); }
34:function now() { return new Date().toISOString(); }
35:function readText(path: string): string { return readFileSync(path, "utf-8"); }
36:function listInputsDir(): string[] {
57:function parseYamlList(line: string): string[] {
64:function loadChecks(yamlPath: string): Check[] {
100:function loadLossPolicy(path: string): LossPolicy {
114:function loadMaintPolicy(path: string): MaintPolicy {
135:function loadReorderPolicy(path: string): ReorderPolicy {
150:function parseCsv(path: string): { headers: string[]; rows: Record<string, string>[] } {
167:function missingFields(headers: string[], required: string[]): string[] {
172:function evalRule(rule: Rule, row: Record<string, string>): boolean {
179:function pickEvidence(fields: string[], row: Record<string, string>): Record<string, string> {
185:function toMillis(ts?: string): number | null {
190:function parseDateOnly(x: string | undefined): number | null {
195:function parseNumber(x: string | undefined): number | null {
200:function maxSeverity(a: Severity, b: Severity): Severity {
206:function computeRisk(findings: Finding[]): RiskSummary {
317:function emailRecommendations(sev: Severity): string[] {
332:function lossRecommendations(sev: Severity): string[] {
346:function maintRecommendations(sev: Severity): string[] {
360:function reorderRecommendations(sev: Severity): string[] {
373:function isHighPriority(p: string): boolean {
379:function lossEngine(findings: Finding[], cache: Record<string, { headers: string[]; rows: Record<string, string>[] }>, lossPolicy: any) {
450:function maintenanceEngine(findings: Finding[], cache: Record<string, { headers: string[]; rows: Record<string, string>[] }>, mp: any) {
553:function inventoryReorderEngine(findings: Finding[], cache: Record<string, { headers: string[]; rows: Record<string, string>[] }>, rp: ReorderPolicy): PurchaseOrderDraft[] {
748:function main() {

### Domain Mentions (strings)

253:    if (f.domain === "data_quality") { low += 1; continue; }
262:    if (f.domain === "data_quality") continue;
387:    findings.push({ severity: "low", domain: "data_quality", summary: `Missing required fields for loss prevention evaluation (skipped)`, data_quality: { missing_required_fields: miss, input: "inventory_variance.csv", check_id: "loss_prevention_engine" } });
407:      domain: "loss_prevention",
428:        domain: "loss_prevention",
444:  if (topSkus.length) findings.push({ severity: "low", domain: "loss_prevention", summary: `Hotspot SKUs by total variance value (top ${topN})`, evidence: Object.fromEntries(topSkus.map(([sku,val], i) => [`sku_${i+1}`, `${sku} ($${Math.round(val)})`])), recommendation: lossRecommendations("low") });
447:  if (topLocs.length) findings.push({ severity: "low", domain: "loss_prevention", summary: `Hotspot locations by total variance value (top ${topN})`, evidence: Object.fromEntries(topLocs.map(([loc,val], i) => [`location_${i+1}`, `${loc} ($${Math.round(val)})`])), recommendation: lossRecommendations("low") });
458:    findings.push({ severity: "low", domain: "data_quality", summary: `Missing required fields for facility maintenance evaluation (skipped)`, data_quality: { missing_required_fields: miss, input: "maintenance.csv", check_id: "facility_maintenance_engine" } });
483:        domain: "facility_maintenance",
491:        domain: "facility_maintenance",
510:        domain: "facility_maintenance",
535:      domain: "facility_maintenance",
564:      domain: "data_quality",
620:      domain: "inventory_reorder",
641:      domain: "inventory_reorder",
671:      domain: "inventory_reorder",
682:      domain: "inventory_reorder",
779:      findings.push({ severity: "low", domain: "data_quality", summary: `Missing required fields for check ${chk.id} (skipped evaluation)`, data_quality: { missing_required_fields: missing, input: chk.input, check_id: chk.id } });
786:        if (chk.domain === "email_intrusion") base.recommendation = emailRecommendations(chk.severity);
815:          findings.push({ severity: "high", domain: "email_intrusion", summary: `Repeated email security events for actor '${actor}' within ${EMAIL_WINDOW_MINUTES} minutes`, recommendation: emailRecommendations("high") });
859:  if (findings.some(f => f.domain === "data_quality")) md.push(`- Address data gaps flagged under data_quality to improve assessment accuracy.`);

### Risk Scoring Anchors


### Input File Anchors


## Next Migration Order (recommended)

1. PCI (small surface, policy-driven)
2. Facility Maintenance
3. Inventory Reorder
4. Loss Prevention
5. Email Intrusion (largest + correlated logic)
