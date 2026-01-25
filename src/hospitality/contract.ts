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
