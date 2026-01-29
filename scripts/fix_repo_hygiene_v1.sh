#!/usr/bin/env bash
set -euo pipefail

echo "fix_repo_hygiene_v1: ignore build outputs + untrack accidental artifacts (idempotent)"

# Ensure scripts dir exists (it does, but be safe)
mkdir -p scripts

# 1) Ensure .gitignore has required entries
touch .gitignore

ensure_line() {
  local line="$1"
  if ! grep -qxF "$line" .gitignore; then
    echo "$line" >> .gitignore
  fi
}

# Ignore build output and dependencies
ensure_line "node_modules/"
ensure_line "dist/"
ensure_line "*.log"

# 2) If dist/ is currently tracked, untrack it (but keep files locally)
if git ls-files --error-unmatch dist >/dev/null 2>&1 || git ls-files | grep -q '^dist/'; then
  git rm -r --cached dist >/dev/null 2>&1 || true
fi

# 3) If anything under node_modules is tracked (should never happen), untrack it
if git ls-files | grep -q '^node_modules/'; then
  git rm -r --cached node_modules >/dev/null 2>&1 || true
fi

# 4) Build must succeed
npm run build
