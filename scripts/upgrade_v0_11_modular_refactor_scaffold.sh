#!/usr/bin/env bash
set -euo pipefail

echo "Upgrading AGO-1 to v0.11 (modular refactor scaffold: no behavior change)"

mkdir -p src/domains src/shared artifacts

# -----------------------------
# Shared types (minimal contract)
# -----------------------------
# Idempotent write: overwrite is fine in v0.x while we stabilize structure.
cat > src/shared/types.ts <<'TS'
export type Severity = "low" | "medium" | "high";

export type Finding = {
  severity: Severity;
  domain: string;
  summary: string;
  recommendation?: string;
  evidence?: Record<string, any>;
};

export type DomainResult = {
  findings: Finding[];
};

export type DomainContext = {
  // file-first inputs (paths resolved by orchestrator)
  inputs: {
    [key: string]: string;
  };

  // run metadata
  runId: string;
  nowISO: string;

  // optional knobs (kept generic on purpose)
  config?: Record<string, any>;
};

export interface DomainEvaluator {
  /** stable identifier used in reports */
  id: string;

  /** human label */
  name: string;

  /** execute evaluation. Must never throw. */
  evaluate(ctx: DomainContext): Promise<DomainResult> | DomainResult;
}
TS

# -----------------------------
# Domain registry (scaffold)
# -----------------------------
cat > src/domains/index.ts <<'TS'
import type { DomainEvaluator } from "../shared/types";

/**
 * v0.11 scaffold: registry exists, but orchestrator wiring happens in v0.12+
 * Keep this list ordered and explicit.
 */
export const DOMAIN_REGISTRY: DomainEvaluator[] = [];
TS

# -----------------------------
# Refactor inventory generator
# -----------------------------
cat > scripts/refactor_inventory.sh <<'SH2'
#!/usr/bin/env bash
set -euo pipefail

mkdir -p artifacts

echo "# AGO-1 Refactor Inventory (v0.11)" > artifacts/refactor_inventory.md
echo "" >> artifacts/refactor_inventory.md
echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> artifacts/refactor_inventory.md
echo "" >> artifacts/refactor_inventory.md

echo "## Key Anchors in src/index.ts" >> artifacts/refactor_inventory.md
echo "" >> artifacts/refactor_inventory.md

# list top-level functions and key domain strings with line numbers
if [ -f src/index.ts ]; then
  echo "### Functions (top-level)" >> artifacts/refactor_inventory.md
  echo "" >> artifacts/refactor_inventory.md
  grep -nE '^(export )?function [a-zA-Z0-9_]+' src/index.ts >> artifacts/refactor_inventory.md || true
  echo "" >> artifacts/refactor_inventory.md

  echo "### Domain Mentions (strings)" >> artifacts/refactor_inventory.md
  echo "" >> artifacts/refactor_inventory.md
  grep -nE '"(email_intrusion|loss_prevention|facility_maintenance|inventory_reorder|pci|pci_compliance|data_quality)"' src/index.ts >> artifacts/refactor_inventory.md || true
  echo "" >> artifacts/refactor_inventory.md

  echo "### Risk Scoring Anchors" >> artifacts/refactor_inventory.md
  echo "" >> artifacts/refactor_inventory.md
  grep -nE 'function computeRisk\\(|Risk Score|Executive Summary|Top Domains' src/index.ts >> artifacts/refactor_inventory.md || true
  echo "" >> artifacts/refactor_inventory.md

  echo "### Input File Anchors" >> artifacts/refactor_inventory.md
  echo "" >> artifacts/refactor_inventory.md
  grep -nE 'inputs\\/([a-zA-Z0-9_\\-]+)\\.csv' src/index.ts >> artifacts/refactor_inventory.md || true
else
  echo "ERROR: src/index.ts not found" >> artifacts/refactor_inventory.md
fi

echo "" >> artifacts/refactor_inventory.md
echo "## Next Migration Order (recommended)" >> artifacts/refactor_inventory.md
echo "" >> artifacts/refactor_inventory.md
echo "1. PCI (small surface, policy-driven)" >> artifacts/refactor_inventory.md
echo "2. Facility Maintenance" >> artifacts/refactor_inventory.md
echo "3. Inventory Reorder" >> artifacts/refactor_inventory.md
echo "4. Loss Prevention" >> artifacts/refactor_inventory.md
echo "5. Email Intrusion (largest + correlated logic)" >> artifacts/refactor_inventory.md

echo "Wrote artifacts/refactor_inventory.md"
SH2
chmod +x scripts/refactor_inventory.sh

# -----------------------------
# Optional: ensure npm script exists (no edits if already present)
# -----------------------------
# No package.json mutation in v0.11 to reduce risk.

# Generate inventory now (idempotent)
./scripts/refactor_inventory.sh

# Must end with build (per rule)
npm run build
