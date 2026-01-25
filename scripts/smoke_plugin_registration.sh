#!/usr/bin/env bash
set -euo pipefail

node - <<'NODE'
import { registerHospitality } from "./dist/index.js";

/** Minimal local registry implementation */
const registry = {
  executors: new Map(),
  registerExecutor(spec) {
    if (this.executors.has(spec.domain_id)) throw new Error("duplicate domain executor: " + spec.domain_id);
    this.executors.set(spec.domain_id, spec);
  }
};

registerHospitality(registry);

const spec = registry.executors.get("hospitality");
if (!spec) throw new Error("hospitality not registered");

const ok = spec.execute({
  action: "RATE_UPDATE",
  property_id: "PROP-001",
  room_type: null,
  date_start: "2026-02-01",
  date_end: "2026-02-07",
  new_rate_cents: 18900,
  currency: "USD",
});

console.log("REGISTER OK:", { domain_id: spec.domain_id, executor_id: spec.executor_id });
console.log("EXEC OK:", ok);
NODE
