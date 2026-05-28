#!/usr/bin/env bash
# ADR-0008 fool-proof: detect expansion of the .gitleaks.toml allowlist
# without an accompanying ADR justification. Anyone widening the allowlist
# silently is bypassing the gitleaks layer of the 5-layer defense, so a PR
# that grows it must reference the ADR that authorized the change.
#
# Usage:
#   scripts/check-config-drift.sh [<base-ref>]
#       base-ref defaults to origin/main.
#
# CI usage (.github/workflows/leak-scan.yml or settings-drift.yml):
#   scripts/check-config-drift.sh "${GITHUB_BASE_REF:-origin/main}"
#
# Exit codes:
#   0  no drift, or drift is justified by ADR reference
#   1  drift detected without ADR reference (or PR body unavailable)
#   2  invocation error
#
# Local exec example (compare current working tree against origin/main):
#   git fetch origin main
#   scripts/check-config-drift.sh origin/main
set -euo pipefail

trap 'rc=$?; printf >&2 "\nFATAL: check-config-drift.sh exited unexpectedly (rc=%d) at line %s: %s\n" "$rc" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}"; exit "$rc"' ERR

# ADR-0012 host guard: gitleaks config + PR-body-based justification are
# GitHub-specific (gh CLI / GH_PR_BODY). Skip on non-github hosts unless
# --force is passed.
SCRIPT_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_LOCAL/_host-detect.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR_LOCAL/_host-detect.sh"
  CURRENT_HOST="$(detect_host)"
  FORCE_FLAG=""
  for arg in "$@"; do [ "$arg" = "--force" ] && FORCE_FLAG=1; done
  if [ "$CURRENT_HOST" != "github" ] && [ -z "$FORCE_FLAG" ]; then
    printf "i  check-config-drift: skip (GitHub-specific; detected host: %s)\n" "$CURRENT_HOST"
    printf "   Use --force to run anyway.\n"
    exit 0
  fi
fi

# Strip --force from positional args (same empty-array idiom as
# check-repo-settings.sh — see comment there).
ARGS=()
for arg in "$@"; do [ "$arg" != "--force" ] && ARGS+=("$arg"); done
if [ ${#ARGS[@]} -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

BASE_REF="${1:-origin/main}"
CONFIG_FILE=".gitleaks.toml"

if [ ! -f "$CONFIG_FILE" ]; then
  printf >&2 "ERROR: %s not found in repo root\n" "$CONFIG_FILE"
  exit 2
fi

# Resolve the base ref (allow fetch-then-call usage).
if ! git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
  printf >&2 "ERROR: cannot resolve base ref '%s' (fetch first?)\n" "$BASE_REF"
  exit 2
fi

# Count added lines in .gitleaks.toml between BASE_REF and HEAD/working tree.
# Use a unified diff and count `^+` lines that aren't the diff header.
added_lines="$(git diff --no-color "$BASE_REF" -- "$CONFIG_FILE" 2>/dev/null \
  | grep -E '^\+[^+]' \
  | grep -cE 'allowlist|paths|regexes' \
  || true)"

if [ "${added_lines:-0}" -eq 0 ]; then
  echo "check-config-drift: no allowlist-related additions vs $BASE_REF — OK."
  exit 0
fi

printf "check-config-drift: detected %d new allowlist-related line(s) vs %s.\n" "$added_lines" "$BASE_REF"

# Check for an ADR reference. Sources, in order of preference:
#   1. GH_PR_BODY env var (set by the CI workflow with `gh pr view`)
#   2. PR body via `gh pr view` if in CI with GH_TOKEN
#   3. Local commit message scan (HEAD ^ BASE_REF range) — fallback for
#      local execution where there's no PR yet.
pr_body=""
if [ -n "${GH_PR_BODY:-}" ]; then
  pr_body="$GH_PR_BODY"
elif command -v gh >/dev/null 2>&1 && [ -n "${GITHUB_REF:-}" ]; then
  pr_body="$(gh pr view --json body --jq .body 2>/dev/null || true)"
fi

# Local fallback: scan recent commits for ADR mentions.
local_commits=""
local_commits="$(git log --format='%B' "$BASE_REF..HEAD" 2>/dev/null || true)"

# Justification source: PR body OR commit messages must contain "ADR-".
combined="${pr_body}
${local_commits}"

if printf '%s' "$combined" | grep -qE 'ADR-[0-9]{4}'; then
  echo "check-config-drift: ADR reference found in PR body or commit messages — drift justified."
  exit 0
fi

printf >&2 "\ncheck-config-drift: drift detected WITHOUT ADR justification.\n"
printf >&2 "  base ref: %s\n" "$BASE_REF"
printf >&2 "  added allowlist-related lines: %d\n" "$added_lines"
printf >&2 "  PR body / commit messages scanned: no ADR-NNNN reference.\n"
printf >&2 "\n  Required action:\n"
printf >&2 "    1. Add an ADR (docs/adr/00XX-*.md) explaining why the allowlist needs widening.\n"
printf >&2 "    2. Reference it in either the PR body or a commit footer:\n"
printf >&2 "         Refs: ADR-00XX\n"
printf >&2 "    3. Re-run this check (push a commit or update the PR description).\n"
exit 1
