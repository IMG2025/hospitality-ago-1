#!/usr/bin/env bash
set -euo pipefail

echo "Bootstrapping AGO-1…"

cat > package.json <<EOF
{
  "name": "coreidentity-ago-1",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "start": "node dist/index.js"
  },
  "devDependencies": {
    "typescript": "^5.7.3"
  }
}
EOF

cat > tsconfig.json <<EOF
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true
  },
  "include": ["src"]
}
EOF

cat > src/index.ts <<EOF
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
EOF

cat > README.md <<EOF
# CoreIdentity AGO-1

File-first governance & risk sentinel.

## Run
npm install
npm run build
node dist/index.js
EOF

npm install
npm run build
