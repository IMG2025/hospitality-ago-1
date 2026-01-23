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
