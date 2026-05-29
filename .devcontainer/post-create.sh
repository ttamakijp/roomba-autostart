#!/usr/bin/env bash
# ADR-0013 Python devcontainer post-create.
#
# Pinned to match a typical Python CI baseline (ruff>=0.15 + pytest>=8 +
# pytest-cov>=7). Adjust pins in your project's pyproject.toml / requirements.
set -euo pipefail

log() { printf "\n=== %s ===\n" "$*"; }

log "Python deps"
pip install --user --upgrade pip
if [ -f requirements.txt ]; then pip install --user -r requirements.txt; fi
if [ -f requirements-dev.txt ]; then pip install --user -r requirements-dev.txt; fi
pip install --user 'ruff>=0.15' 'pytest>=8' 'pytest-cov>=7'

# Optional: install dev-templates hooks if .githooks/ is present (e.g. after
# apply-to-project.sh --profile leak-only).
if [ -d .githooks ] && [ -f scripts/setup-hooks.sh ]; then
  log "git hooks"
  bash scripts/setup-hooks.sh
fi

printf "\n✓ Python devcontainer ready. Try: 'pytest' or 'ruff check .'\n"
