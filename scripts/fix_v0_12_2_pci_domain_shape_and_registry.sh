#!/usr/bin/env bash
set -euo pipefail

echo "Fixing PCI domain to conform to DomainEvaluator + registry wiring"

node <<'NODE'
import fs from "fs";

function writeIfChanged(path, next) {
  const prev = fs.readFileSync(path, "utf8");
  if (prev === next) {
    console.log(`No change: ${path}`);
    return false;
  }
  fs.writeFileSync(path, next, "utf8");
  console.log(`Updated: ${path}`);
  return true;
}

let changed = false;

/**
 * 1) Fix src/domains/pci.ts
 * Goal:
 * - export const pci: DomainEvaluator = { evaluate(ctx) { ... } }
 * - keep existing implementation body as-is, wrapping if needed
 */
{
  const path = "src/domains/pci.ts";
  let src = fs.readFileSync(path, "utf8");

  // If already exports "pci" and has "evaluate(", consider it fixed.
  const alreadyObject =
    /export\s+const\s+pci\s*:\s*DomainEvaluator\s*=\s*\{\s*evaluate\s*\(/m.test(src) ||
    /export\s+const\s+pci\s*=\s*\{\s*evaluate\s*\(/m.test(src);

  if (!alreadyObject) {
    // Try to locate a function-style export we can wrap.
    // Common patterns we may have:
    // - export const pciEvaluator: DomainEvaluator = ({cache, policies}) => { ... }
    // - export const pciEvaluator = ({cache, policies}) => { ... }
    // We will wrap the function body into evaluate().
    const fnHeader = src.match(/export\s+const\s+pciEvaluator(?:\s*:\s*DomainEvaluator)?\s*=\s*\(\s*\{\s*cache\s*,\s*policies\s*\}\s*\)\s*=>\s*\{/m);

    if (!fnHeader) {
      throw new Error("Could not find export const pciEvaluator = ({ cache, policies }) => { ... } in src/domains/pci.ts");
    }

    // Replace the header with an object-form DomainEvaluator.
    src = src.replace(
      /export\s+const\s+pciEvaluator(?:\s*:\s*DomainEvaluator)?\s*=\s*\(\s*\{\s*cache\s*,\s*policies\s*\}\s*\)\s*=>\s*\{/m,
      "export const pci: DomainEvaluator = {\n  evaluate({ cache, policies }) {\n"
    );

    // Replace the *final* closing "};" of the function export with object close.
    // We do a conservative approach: if the file ends with "};", convert to "  }\n};"
    // If it ends with "}\n", we won't guess—fail loudly.
    if (/\n\}\s*;\s*$/m.test(src)) {
      src = src.replace(/\n\}\s*;\s*$/m, "\n  }\n};\n");
    } else if (/\n\}\s*$/m.test(src)) {
      // If no semicolon, still close properly.
      src = src.replace(/\n\}\s*$/m, "\n  }\n};\n");
    } else {
      throw new Error("Could not locate function export terminator to close pci DomainEvaluator object.");
    }

    // Ensure DomainEvaluator is imported (if not already).
    if (!/DomainEvaluator/.test(src)) {
      // Insert near top after existing imports.
      // If there's already an import from shared/types.js, don't duplicate.
      if (/from\s+["']\.\.\/shared\/types\.js["']/.test(src)) {
        // Add DomainEvaluator to existing import type list if present.
        src = src.replace(
          /import\s+type\s+\{\s*([^}]+)\s*\}\s+from\s+["']\.\.\/shared\/types\.js["'];?/m,
          (m, inner) => {
            const parts = inner.split(",").map(s => s.trim()).filter(Boolean);
            if (!parts.includes("DomainEvaluator")) parts.unshift("DomainEvaluator");
            return `import type { ${parts.join(", ")} } from "../shared/types.js";`;
          }
        );
      } else {
        src = `import type { DomainEvaluator } from "../shared/types.js";\n` + src;
      }
    } else {
      // If DomainEvaluator is referenced but not imported, add it.
      const hasImport = /import\s+type\s+\{[^}]*DomainEvaluator[^}]*\}\s+from\s+["']\.\.\/shared\/types\.js["']/.test(src);
      if (!hasImport) {
        if (/from\s+["']\.\.\/shared\/types\.js["']/.test(src)) {
          src = src.replace(
            /import\s+type\s+\{\s*([^}]+)\s*\}\s+from\s+["']\.\.\/shared\/types\.js["'];?/m,
            (m, inner) => {
              const parts = inner.split(",").map(s => s.trim()).filter(Boolean);
              if (!parts.includes("DomainEvaluator")) parts.unshift("DomainEvaluator");
              return `import type { ${parts.join(", ")} } from "../shared/types.js";`;
            }
          );
        } else {
          src = `import type { DomainEvaluator } from "../shared/types.js";\n` + src;
        }
      }
    }

    // Remove old pciEvaluator export if still referenced anywhere (should be replaced by header change).
    // (No-op if already replaced.)
    changed = writeIfChanged(path, src) || changed;
  } else {
    console.log("PCI domain already in object-form (evaluate).");
  }
}

/**
 * 2) Fix src/domains/index.ts
 * Goal:
 * - import { pci } from "./pci.js";
 * - DOMAIN_REGISTRY: { pci }
 */
{
  const path = "src/domains/index.ts";
  let src = fs.readFileSync(path, "utf8");

  // Replace import { pciEvaluator } with { pci }
  src = src.replace(
    /import\s+\{\s*pciEvaluator\s*\}\s+from\s+["']\.\/pci\.js["'];?/m,
    'import { pci } from "./pci.js";'
  );

  // Replace registry value pci: pciEvaluator -> pci: pci
  src = src.replace(/pci\s*:\s*pciEvaluator\b/m, "pci: pci");

  changed = writeIfChanged(path, src) || changed;
}

console.log(changed ? "v0.12.2 patch applied." : "v0.12.2 patch already satisfied (idempotent).");
NODE

npm run build
