#!/usr/bin/env bash
set -euo pipefail

mkdir -p inputs docs

cat > docs/input_contracts.md <<'EOF'
# AGO-1 Input Contracts (v0.3)

## email_security.csv
Required columns:
- timestamp (ISO8601)
- event_type (e.g., login_success, login_failure, rule_created, rule_modified)
- actor (user/email)
- ip (source ip)
- geo (free text)
- detail (free text)

## pci_events.csv
Required columns:
- timestamp (ISO8601)
- system (e.g., pos, network, endpoint)
- event_type (e.g., admin_access_changed, device_added, config_changed)
- actor
- asset_id
- detail

## inventory_variance.csv
Required columns:
- business_date (YYYY-MM-DD)
- location_id
- sku
- expected_qty
- actual_qty
- variance_qty
- variance_value
- notes

## maintenance.csv
Required columns:
- opened_date (YYYY-MM-DD)
- location_id
- asset
- issue
- priority (low|medium|high)
- status (open|in_progress|closed)
- due_date (YYYY-MM-DD)
- last_update (ISO8601)
EOF

# Sample templates (empty but with headers)
cat > inputs/email_security.csv <<'EOF'
timestamp,event_type,actor,ip,geo,detail
EOF

cat > inputs/pci_events.csv <<'EOF'
timestamp,system,event_type,actor,asset_id,detail
EOF

cat > inputs/inventory_variance.csv <<'EOF'
business_date,location_id,sku,expected_qty,actual_qty,variance_qty,variance_value,notes
EOF

cat > inputs/maintenance.csv <<'EOF'
opened_date,location_id,asset,issue,priority,status,due_date,last_update
EOF

npm run build
