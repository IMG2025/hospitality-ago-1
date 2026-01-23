import { existsSync } from "fs";
// Domain metadata required by shared DomainEvaluator contract
export const pci = {
    id: "pci",
    name: "PCI Compliance",
    evaluate: (ctx) => {
        // Orchestrator injects parsed inputs on DomainContext. We keep tolerant typing.
        const anyCtx = ctx;
        const cache = anyCtx?.inputs ?? anyCtx?.cache ?? anyCtx?.inputs ?? anyCtx?.tables ?? {};
        const findings = [];
        if (!existsSync("inputs/pci_events.csv")) {
            return { findings };
        }
        const rows = cache?.["inputs/pci_events.csv"]?.rows ?? [];
        for (const row of rows) {
            if (row.event_type === "pci_violation") {
                findings.push({
                    severity: "high",
                    domain: "pci",
                    summary: "PCI compliance violation detected",
                    evidence: row,
                    recommendation: "Immediately investigate PCI violation; Preserve evidence for compliance review; Validate PCI scope and controls."
                });
            }
        }
        return { findings };
    }
};
