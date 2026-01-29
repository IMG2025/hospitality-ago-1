#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

npm run build >/dev/null

node - <<'NODE'
async function main() {
  const entrypoints = [
    "./dist/index.js",
  ];
  const ok = [];
  for (const p of entrypoints) {
    try {
      await import(p);
      ok.push(p);
    } catch (e) {
      console.error("FAIL: dist import failed:", p);
      console.error(String((e && e.stack) || e));
      process.exit(1);
    }
  }
  console.log("OK: Hospitality dist entrypoints importable:", ok);
}
main();
NODE
