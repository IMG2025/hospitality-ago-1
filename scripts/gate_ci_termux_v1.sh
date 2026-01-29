#!/usr/bin/env bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

echo "OK: Hospitality Termux gate: start"
npm test

# Enforce clean tree after tests (prevents untracked drift artifacts)
if [[ -n "$(git status --porcelain)" ]]; then
  echo "FAIL: working tree not clean after tests:"
  git status --porcelain
  exit 1
fi

npm run build
echo "OK: Hospitality Termux gate: green + clean tree"
