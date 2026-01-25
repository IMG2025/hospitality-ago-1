import type { HospitalityInputs, HospitalityResult } from "./contract.js";
import { validateHospitalityInputs, toContractError } from "./validate.js";

export function executeHospitality(rawInputs: unknown): HospitalityResult {
  try {
    const input: HospitalityInputs = validateHospitalityInputs(rawInputs);

    if (input.action === "RATE_UPDATE") {
      return {
        status: "OK",
        action: input.action,
        result: "STUB_APPLIED",
        output: {
          mode: "CONTRACT_LOCKED",
          property_id: input.property_id,
          room_type: input.room_type ?? null,
          date_range: { start: input.date_start, end: input.date_end },
          new_rate_cents: input.new_rate_cents,
          currency: input.currency,
        },
      };
    }

    if (input.action === "TARIFF_SYNC") {
      return {
        status: "OK",
        action: input.action,
        result: "STUB_SYNCED",
        output: {
          mode: "CONTRACT_LOCKED",
          source: input.source,
          effective_date: input.effective_date,
          categories: input.categories ?? [],
        },
      };
    }

    // VENDOR_INVOICE_CHECK
    return {
      status: "OK",
      action: input.action,
      result: "STUB_CHECK_COMPLETE",
      output: {
        mode: "CONTRACT_LOCKED",
        vendor_id: input.vendor_id,
        invoice_id: input.invoice_id,
        amount_cents: input.amount_cents,
        currency: input.currency,
        flags: [],
      },
    };
  } catch (e) {
    return toContractError(e);
  }
}
