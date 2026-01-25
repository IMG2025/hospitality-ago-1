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
