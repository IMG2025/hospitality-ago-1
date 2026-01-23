export type Severity = "low" | "medium" | "high";

export type Finding = {
  severity: Severity;
  domain: string;
  summary: string;
  recommendation?: string;
  evidence?: Record<string, any>;
};

export type DomainResult = {
  findings: Finding[];
};

export type DomainContext = {
  // file-first inputs (paths resolved by orchestrator)
  inputs: {
    [key: string]: string;
  };

  // run metadata
  runId: string;
  nowISO: string;

  // optional knobs (kept generic on purpose)
  config?: Record<string, any>;
};

export interface DomainEvaluator {
  /** stable identifier used in reports */
  id: string;

  /** human label */
  name: string;

  /** execute evaluation. Must never throw. */
  evaluate(ctx: DomainContext): Promise<DomainResult> | DomainResult;
}
