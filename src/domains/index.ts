import type { DomainEvaluator } from "../shared/types.js";
import { pci } from "./pci.js";

export const DOMAIN_REGISTRY: Record<string, DomainEvaluator> = {
  pci: pci
};
