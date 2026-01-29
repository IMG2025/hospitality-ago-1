#!/usr/bin/env bash
set -euo pipefail

write_if_changed() {
  local path="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  mkdir -p "$(dirname "$path")"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    echo "UNCHANGED: $path"
    return 0
  fi
  mv "$tmp" "$path"
  echo "WROTE: $path"
}

# ---------------------------------------
# Plugin surface (core-facing registration)
# ---------------------------------------
write_if_changed src/plugin.ts <<'TS'
import type { HospitalityAction, HospitalityInputs, HospitalityResult } from "./hospitality/contract.js";
import { validateHospitalityInputs } from "./hospitality/validate.js";
import { executeHospitality } from "./hospitality/executor.js";

/**
 * Minimal “core-facing” registry interface.
 * We intentionally mirror only what we need to avoid deep coupling.
 */
export type CoreDomainRegistry = {
  registerExecutor(spec: Readonly<{
    domain_id: string;
    executor_id: string;
    supported_task_types: readonly ("EXECUTE" | "ANALYZE" | "ESCALATE")[];
    required_scopes: Readonly<Record<"EXECUTE" | "ANALYZE" | "ESCALATE", readonly string[]>>;
    // Domain-specific scope requirements (optional) enforced inside domain execution
    domain_action_scopes?: Readonly<Record<string, readonly string[]>>;
    validate_inputs: (raw: unknown) => unknown;
    execute: (raw: unknown) => unknown;
  }>): void;
};

export const HOSPITALITY_EXECUTOR_ID = "hospitalityExecutor";
export const HOSPITALITY_DOMAIN_ID = "hospitality";

export const HOSPITALITY_ACTIONS: readonly HospitalityAction[] = [
  "RATE_UPDATE",
  "TARIFF_SYNC",
  "VENDOR_INVOICE_CHECK",
] as const;

/**
 * Contract-locked scopes:
 * - Domain gate scope lives in core’s domain.json (hospitality:execute etc.)
 * - Action scopes are enforced here (fine-grained).
 */
export const HOSPITALITY_ACTION_SCOPES: Readonly<Record<HospitalityAction, readonly string[]>> = {
  RATE_UPDATE: ["hospitality:rates:write"],
  TARIFF_SYNC: ["hospitality:tariffs:sync"],
  VENDOR_INVOICE_CHECK: ["hospitality:vendor_invoices:read"],
} as const;

export function registerHospitality(registry: CoreDomainRegistry): void {
  registry.registerExecutor({
    domain_id: HOSPITALITY_DOMAIN_ID,
    executor_id: HOSPITALITY_EXECUTOR_ID,
    supported_task_types: ["EXECUTE"],
    required_scopes: {
      EXECUTE: ["task:execute", "hospitality:execute"],
      ANALYZE: ["task:analyze"],
      ESCALATE: ["task:escalate"],
    },
    domain_action_scopes: HOSPITALITY_ACTION_SCOPES,
    validate_inputs: (raw: unknown) => validateHospitalityInputs(raw) as HospitalityInputs,
    execute: (raw: unknown) => executeHospitality(raw) as HospitalityResult,
  });
}
TS

# ---------------------------------------
# Export plugin entry
# ---------------------------------------
if [[ -f src/index.ts ]]; then
  # ensure plugin export exists (idempotent append)
  if ! grep -q 'export \* from "\.\/plugin\.js";' src/index.ts; then
    printf '\nexport * from "./plugin.js";\n' >> src/index.ts
    echo "APPENDED: src/index.ts"
  else
    echo "UNCHANGED: src/index.ts"
  fi
else
  write_if_changed src/index.ts <<'TS'
export * from "./hospitality/contract.js";
export * from "./hospitality/validate.js";
export * from "./hospitality/executor.js";
export * from "./plugin.js";
TS
fi

# ---------------------------------------
# Smoke: local registry + call
# ---------------------------------------
write_if_changed scripts/smoke_plugin_registration.sh <<'BASH2'
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
BASH2

chmod +x scripts/smoke_plugin_registration.sh

# Required ending build (and we run smoke against dist)
npm run build
./scripts/smoke_plugin_registration.sh
npm run build
