#!/usr/bin/env bash
set -euo pipefail

CORE_TARBALL="$HOME/work/ago-1-core/ago-1-core-0.1.0.tgz"

if [[ ! -f "$CORE_TARBALL" ]]; then
  echo "ERROR: ago-1-core tarball not found at $CORE_TARBALL"
  exit 1
fi

# Install core as a dependency
npm install "$CORE_TARBALL"

# Sanity check: ensure it resolves
node - <<'NODE'
import * as core from "ago-1-core";
if (!core.intakeAndDispatch) {
  throw new Error("ago-1-core missing intakeAndDispatch");
}
console.log("ago-1-core linked successfully");
NODE

npm run build
