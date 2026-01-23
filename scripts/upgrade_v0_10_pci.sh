#!/usr/bin/env bash
set -euo pipefail

echo "Upgrading AGO-1 to v0.10 (PCI Risk Domain)"

# --- policies ---
mkdir -p policies
cat > policies/pci.yaml <<'YAML'
pci:
  name: "PCI Operational Risk Sentinel"
  scope:
    - access_control
    - network_security
    - system_integrity
    - logging
  severities:
    high:
      - pos_admin_login_off_hours
      - repeated_admin_failures
      - remote_access_enabled
    medium:
      - antivirus_disabled
      - patch_failure
      - firewall_change
    low:
      - user_role_change
      - single_admin_login
YAML

# --- input stub ---
mkdir -p inputs
test -f inputs/pci_events.csv || cat > inputs/pci_events.csv <<'CSV'
event_type,actor,location_id,ip,timestamp,detail
CSV

# --- register domain ---
node <<'NODE'
import fs from "fs";

const path = "src/domains.ts";
const src = fs.readFileSync(path, "utf-8");

if (!src.includes("pci")) {
  const out = src.replace(
    /export const DOMAINS = \[/,
    'export const DOMAINS = [\n  "pci",'
  );
  fs.writeFileSync(path, out);
}
NODE

# --- build ---
npm run build
