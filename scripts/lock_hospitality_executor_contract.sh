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

# --------------------------
# Contract: Types + Errors
# --------------------------
write_if_changed src/hospitality/contract.ts <<'TS'
export type IsoDate = string;

export type HospitalityAction =
  | "RATE_UPDATE"
  | "TARIFF_SYNC"
  | "VENDOR_INVOICE_CHECK";

export type RateUpdateInput = Readonly<{
  action: "RATE_UPDATE";
  property_id: string;
  room_type?: string | null;
  date_start: IsoDate;
  date_end: IsoDate;
  new_rate_cents: number;
  currency: string; // e.g., USD
}>;

export type TariffSyncSource = "HTS" | "INTERNAL" | "VENDOR";

export type TariffSyncInput = Readonly<{
  action: "TARIFF_SYNC";
  source: TariffSyncSource;
  effective_date: IsoDate;
  categories?: readonly string[]; // optional, if omitted means "all"
}>;

export type VendorInvoiceCheckInput = Readonly<{
  action: "VENDOR_INVOICE_CHECK";
  vendor_id: string;
  invoice_id: string;
  amount_cents: number;
  currency: string;
}>;

export type HospitalityInputs =
  | RateUpdateInput
  | TariffSyncInput
  | VendorInvoiceCheckInput;

export type HospitalityOk = Readonly<{
  status: "OK";
  action: HospitalityAction;
  result: string;
  output: Readonly<Record<string, unknown>>;
}>;

export type HospitalityErrorCode =
  | "INPUT_ACTION_REQUIRED"
  | "INPUT_ACTION_INVALID"
  | "INPUT_PROPERTY_ID_REQUIRED"
  | "INPUT_DATE_START_REQUIRED"
  | "INPUT_DATE_END_REQUIRED"
  | "INPUT_RATE_CENTS_REQUIRED"
  | "INPUT_CURRENCY_REQUIRED"
  | "INPUT_SOURCE_REQUIRED"
  | "INPUT_EFFECTIVE_DATE_REQUIRED"
  | "INPUT_VENDOR_ID_REQUIRED"
  | "INPUT_INVOICE_ID_REQUIRED"
  | "INPUT_AMOUNT_CENTS_REQUIRED";

export type HospitalityErr = Readonly<{
  status: "ERROR";
  action: HospitalityAction | "UNKNOWN";
  error: HospitalityErrorCode;
  message: string;
}>;

export type HospitalityResult = HospitalityOk | HospitalityErr;
TS

# --------------------------
# Contract: Validator
# --------------------------
write_if_changed src/hospitality/validate.ts <<'TS'
import type {
  HospitalityAction,
  HospitalityInputs,
  HospitalityResult,
  TariffSyncSource,
} from "./contract.js";

function isObject(x: unknown): x is Record<string, unknown> {
  return typeof x === "object" && x !== null;
}

function reqString(o: Record<string, unknown>, k: string, err: { code: any; msg: string }): string {
  const v = o[k];
  if (typeof v !== "string" || v.trim() === "") throw new Error(`${err.code}::${err.msg}`);
  return v;
}

function optStringOrNull(o: Record<string, unknown>, k: string): string | null | undefined {
  const v = o[k];
  if (v === undefined) return undefined;
  if (v === null) return null;
  if (typeof v === "string") return v;
  throw new Error(`INPUT_${k.toUpperCase()}_INVALID::${k} must be string|null`);
}

function reqNumber(o: Record<string, unknown>, k: string, err: { code: any; msg: string }): number {
  const v = o[k];
  if (typeof v !== "number" || Number.isNaN(v)) throw new Error(`${err.code}::${err.msg}`);
  return v;
}

function optStringArray(o: Record<string, unknown>, k: string): readonly string[] | undefined {
  const v = o[k];
  if (v === undefined) return undefined;
  if (!Array.isArray(v)) throw new Error(`INPUT_${k.toUpperCase()}_INVALID::${k} must be string[]`);
  for (const item of v) {
    if (typeof item !== "string") throw new Error(`INPUT_${k.toUpperCase()}_INVALID::${k} must be string[]`);
  }
  return v as readonly string[];
}

function parseAction(o: Record<string, unknown>): HospitalityAction {
  const a = o["action"];
  if (typeof a !== "string" || a.trim() === "") throw new Error("INPUT_ACTION_REQUIRED::action required");
  if (a === "RATE_UPDATE" || a === "TARIFF_SYNC" || a === "VENDOR_INVOICE_CHECK") return a;
  throw new Error("INPUT_ACTION_INVALID::unsupported action");
}

function parseSource(o: Record<string, unknown>): TariffSyncSource {
  const s = o["source"];
  if (typeof s !== "string" || s.trim() === "") throw new Error("INPUT_SOURCE_REQUIRED::source required");
  if (s === "HTS" || s === "INTERNAL" || s === "VENDOR") return s;
  throw new Error("INPUT_SOURCE_REQUIRED::source must be HTS|INTERNAL|VENDOR");
}

export function validateHospitalityInputs(raw: unknown): HospitalityInputs {
  if (!isObject(raw)) throw new Error("INPUT_ACTION_REQUIRED::inputs must be an object");
  const action = parseAction(raw);

  if (action === "RATE_UPDATE") {
    return {
      action,
      property_id: reqString(raw, "property_id", {
        code: "INPUT_PROPERTY_ID_REQUIRED",
        msg: "property_id required",
      }),
      room_type: optStringOrNull(raw, "room_type"),
      date_start: reqString(raw, "date_start", {
        code: "INPUT_DATE_START_REQUIRED",
        msg: "date_start required",
      }),
      date_end: reqString(raw, "date_end", {
        code: "INPUT_DATE_END_REQUIRED",
        msg: "date_end required",
      }),
      new_rate_cents: reqNumber(raw, "new_rate_cents", {
        code: "INPUT_RATE_CENTS_REQUIRED",
        msg: "new_rate_cents required",
      }),
      currency: reqString(raw, "currency", {
        code: "INPUT_CURRENCY_REQUIRED",
        msg: "currency required",
      }),
    };
  }

  if (action === "TARIFF_SYNC") {
    return {
      action,
      source: parseSource(raw),
      effective_date: reqString(raw, "effective_date", {
        code: "INPUT_EFFECTIVE_DATE_REQUIRED",
        msg: "effective_date required",
      }),
      categories: optStringArray(raw, "categories"),
    };
  }

  // VENDOR_INVOICE_CHECK
  return {
    action,
    vendor_id: reqString(raw, "vendor_id", {
      code: "INPUT_VENDOR_ID_REQUIRED",
      msg: "vendor_id required",
    }),
    invoice_id: reqString(raw, "invoice_id", {
      code: "INPUT_INVOICE_ID_REQUIRED",
      msg: "invoice_id required",
    }),
    amount_cents: reqNumber(raw, "amount_cents", {
      code: "INPUT_AMOUNT_CENTS_REQUIRED",
      msg: "amount_cents required",
    }),
    currency: reqString(raw, "currency", {
      code: "INPUT_CURRENCY_REQUIRED",
      msg: "currency required",
    }),
  };
}

export function toContractError(e: unknown): HospitalityResult {
  const msg = e instanceof Error ? e.message : String(e);

  // Pattern: CODE::message
  const parts = msg.split("::");
  const code = (parts[0] || "INPUT_ACTION_REQUIRED") as any;
  const message = parts.slice(1).join("::") || msg;

  // If action parsing failed we may not know it
  const action: any =
    code === "INPUT_ACTION_REQUIRED" || code === "INPUT_ACTION_INVALID" ? "UNKNOWN" : "UNKNOWN";

  return { status: "ERROR", action, error: code, message };
}
TS

# --------------------------
# Contract: Executor (deterministic stub)
# --------------------------
write_if_changed src/hospitality/executor.ts <<'TS'
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
TS

# --------------------------
# Public entry
# --------------------------
write_if_changed src/index.ts <<'TS'
export * from "./hospitality/contract.js";
export * from "./hospitality/validate.js";
export * from "./hospitality/executor.js";
TS

# --------------------------
# Smoke script (no test framework)
# --------------------------
write_if_changed scripts/smoke_hospitality_contract.sh <<'BASH2'
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
BASH2

chmod +x scripts/smoke_hospitality_contract.sh

# Build required by rule
npm run build

# Smoke check against dist
./scripts/smoke_hospitality_contract.sh

# Build again at end to satisfy the invariant even if smoke ran
npm run build
