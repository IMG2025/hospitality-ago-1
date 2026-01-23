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
