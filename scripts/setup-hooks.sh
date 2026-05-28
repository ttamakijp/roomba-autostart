#!/usr/bin/env bash
# Activate repo-local git hooks under .githooks/.
# Run once per clone:
#   bash scripts/setup-hooks.sh
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Required hooks. Listed explicitly so a missing file early-fails this
# setup script instead of silently producing an unprotected clone.
REQUIRED_HOOKS=(pre-commit pre-push)
for h in "${REQUIRED_HOOKS[@]}"; do
  if [ ! -f ".githooks/$h" ]; then
    echo "error: required hook .githooks/$h is missing" >&2
    exit 1
  fi
done

git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true

echo "Hooks activated."
echo "  core.hooksPath = $(git config core.hooksPath)"
echo "  Hooks:"
ls -1 .githooks | sed 's/^/    /'
