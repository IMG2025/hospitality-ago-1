# AGO-1 Input Contracts (v0.4)

These are *canonical targets*. Real exports may omit fields. AGO-1 will:
- operate with partial data
- produce `data_quality` findings for missing required fields per check
- never crash on missing columns

## email_security.csv (canonical)
- timestamp (ISO8601) [optional]
- event_type [required by some checks]
- actor (user/email) [optional]
- ip [optional]
- geo [optional]
- detail [optional/required depending on check]

## pci_events.csv (canonical)
- timestamp (ISO8601) [optional]
- system [optional]
- event_type [required by some checks]
- actor [optional]
- asset_id [optional]
- detail [optional/required depending on check]

## maintenance.csv (canonical)
- opened_date (YYYY-MM-DD) [optional]
- location_id [optional]
- asset [optional]
- issue [optional]
- priority (low|medium|high) [optional]
- status (open|in_progress|closed) [required by some checks]
- due_date (YYYY-MM-DD) [required by some checks]
- last_update (ISO8601) [optional]
