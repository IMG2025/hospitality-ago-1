#!/usr/bin/env bash
set -euo pipefail

echo "Fix v0.12.9: normalize Finding rendering (strict-safe, idempotent)"

node <<'NODE'
import fs from "fs";

const path = "src/index.ts";
let src = fs.readFileSync(path, "utf8");

// Remove prior v0.12.9 block if present
src = src.replace(
  /\n\/\/ BEGIN v0\.12\.9 FINDING_RENDER[\s\S]*?\n\/\/ END v0\.12\.9 FINDING_RENDER\s*\n?/g,
  "\n"
);

// Target the findings render loop
const loopRegex =
  /for\s*\(\s*const\s+f\s+of\s+findings\s*\)\s*\{[\s\S]*?\n\s*\}/m;

const match = src.match(loopRegex);
if (!match) {
  throw new Error("Could not locate findings render loop");
}

const replacement = `for (const f of findings) {
  // BEGIN v0.12.9 FINDING_RENDER
  const ev =
    f.evidence && typeof f.evidence === "object"
      ? Object.entries(f.evidence)
          .map(([k, v]) => \`\${k}=\${String(v)}\`)
          .join(", ")
      : "";

  const rec =
    Array.isArray(f.recommendation)
      ? f.recommendation.join("; ")
      : typeof f.recommendation === "string"
      ? f.recommendation
      : "";

  const dq =
    f.data_quality
      ? \`missing=\${(f.data_quality.missing_required_fields ?? []).join("|")} input=\${f.data_quality.input ?? ""}\`
      : "";

  lines.push([
    f.domain,
    f.severity,
    f.summary,
    ev,
    rec,
    dq
  ].join("\\t"));
  // END v0.12.9 FINDING_RENDER
}`;

src = src.replace(loopRegex, replacement);

fs.writeFileSync(path, src, "utf8");
console.log("v0.12.9 patch applied.");
NODE

# Must end with build (per rule)
npm run build
