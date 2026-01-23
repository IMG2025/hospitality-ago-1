import type { DomainEvaluator, Finding, DomainContext } from "../shared/types.js";
import { existsSync } from "fs";

// Domain metadata required by shared DomainEvaluator contract
export const pci: DomainEvaluator = {
  id: "pci",
  name: "PCI Compliance",
  evaluate: (ctx: DomainContext) => {
    // Orchestrator injects parsed inputs on DomainContext. We keep tolerant typing.
    const anyCtx = ctx as any;
    const cache = anyCtx?.inputs ?? anyCtx?.cache ?? anyCtx?.inputs ?? anyCtx?.tables ?? {};
    const findings: Finding[] = [];

    if (!existsSync("inputs/pci_events.csv")) {
      return { findings };
    }

    const rows = cache?.["inputs/pci_events.csv"]?.rows ?? [];
    for (const row of rows) {
      if ((row as any).event_type === "pci_violation") {
        findings.push({
          severity: "high",
          domain: "pci",
          summary: "PCI compliance violation detected",
          evidence: row as any,
          recommendation:
            "Immediately investigate PCI violation; Preserve evidence for compliance review; Validate PCI scope and controls."
        } as any);
      }
    }

    return { findings };
  }
};
