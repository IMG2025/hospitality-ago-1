#!/usr/bin/env bash
set -euo pipefail

node - <<'NODE'
import { executeHospitality } from "./dist/index.js";

const rate = executeHospitality({
  action: "RATE_UPDATE",
  property_id: "PROP-001",
  room_type: null,
  date_start: "2026-02-01",
  date_end: "2026-02-07",
  new_rate_cents: 18900,
  currency: "USD",
});
console.log("RATE:", rate);

const tariff = executeHospitality({
  action: "TARIFF_SYNC",
  source: "HTS",
  effective_date: "2026-02-01",
  categories: ["steel", "aluminum"],
});
console.log("TARIFF:", tariff);

const invoice = executeHospitality({
  action: "VENDOR_INVOICE_CHECK",
  vendor_id: "VEND-9",
  invoice_id: "INV-1001",
  amount_cents: 502500,
  currency: "USD",
});
console.log("INVOICE:", invoice);

const bad = executeHospitality({
  action: "RATE_UPDATE",
  // property_id missing
  date_start: "2026-02-01",
  date_end: "2026-02-07",
  new_rate_cents: 18900,
  currency: "USD",
});
console.log("BAD:", bad);
NODE
