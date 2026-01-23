import { writeFileSync, mkdirSync, existsSync } from "fs";
import { join } from "path";

const runId = "ago1_" + Date.now();
const outDir = "artifacts";
if (!existsSync(outDir)) mkdirSync(outDir);

const payload = {
  runId,
  timestamp: new Date().toISOString(),
  findings: []
};

const out = join(outDir, runId + ".json");
writeFileSync(out, JSON.stringify(payload, null, 2));
console.log("AGO-1 run complete:", out);
