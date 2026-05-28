#!/usr/bin/env bash
# ADR-0008 (L5 drift check): detect drift in GitHub repository settings.
#
# Settings tracked here are those that ADR-0005 / ADR-0008 establish as
# load-bearing for the multi-layer defense. Drift = someone (or some
# automation) changed them via the GitHub UI or the API without going
# through git review.
#
# Usage:
#   scripts/check-repo-settings.sh <owner>/<repo>
#
# Required:
#   gh CLI authenticated. Read scope on the target repo is sufficient.
#
# Behavior on missing fields:
#   Some fields (delete_branch_on_merge, squash_merge_commit_*, etc.) require
#   admin-level permission on the GitHub API and are NULL in responses fetched
#   with the default GITHUB_TOKEN. These are reported as [skipped: insufficient
#   permission] rather than as drift, to avoid false-positive failures in
#   PR / cron contexts. Drift is only reported when a field IS readable AND
#   differs from the expected baseline.
#
# Exit codes:
#   0  no drift (or all drift fields unreadable due to permissions)
#   1  drift detected on at least one readable field
#   2  invocation error
set -euo pipefail

trap 'rc=$?; printf >&2 "\nFATAL: check-repo-settings.sh exited unexpectedly (rc=%d) at line %s: %s\n" "$rc" "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}"; exit "$rc"' ERR

# ADR-0012 host guard: this script is GitHub-specific (gh api). Skip with
# exit 0 (not fail) if the current cwd's origin is not github — keeps CI
# matrix builds with mixed-host targets from breaking.
SCRIPT_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR_LOCAL/_host-detect.sh" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR_LOCAL/_host-detect.sh"
  CURRENT_HOST="$(detect_host)"
  FORCE_FLAG=""
  for arg in "$@"; do [ "$arg" = "--force" ] && FORCE_FLAG=1; done
  if [ "$CURRENT_HOST" != "github" ] && [ -z "$FORCE_FLAG" ]; then
    printf "i  check-repo-settings: skip (GitHub-specific; detected host: %s)\n" "$CURRENT_HOST"
    printf "   Use --force to run anyway (gh CLI must still be authenticated).\n"
    exit 0
  fi
fi

# Strip --force from positional args before the existing parser. Use the
# `set -- "${arr[@]+...}"` idiom so an empty array doesn't materialize a
# single empty positional arg (which would break the `$# -ne 1` check below).
ARGS=()
for arg in "$@"; do [ "$arg" != "--force" ] && ARGS+=("$arg"); done
if [ ${#ARGS[@]} -gt 0 ]; then set -- "${ARGS[@]}"; else set --; fi

if [ $# -ne 1 ]; then
  printf >&2 "Usage: %s [--force] <owner>/<repo>\n" "$0"
  exit 2
fi

REPO="$1"

if ! command -v gh >/dev/null 2>&1; then
  printf >&2 "ERROR: gh CLI not available\n"
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
  printf >&2 "ERROR: python required for JSON parsing\n"
  exit 2
fi

PYTHON="$(command -v python3 || command -v python)"

# Fetch settings once. The API returns a JSON object with admin-scoped fields
# included if the token has admin permission, or omitted/null if not.
settings_json="$(gh api "repos/$REPO" 2>/dev/null || true)"
if [ -z "$settings_json" ]; then
  printf >&2 "ERROR: failed to fetch repo settings for %s (auth? typo?)\n" "$REPO"
  exit 2
fi

# Expected settings derived from ADR-0005 (squash strategy) and the PR-A2
# QCDSME+α Phase 1 baseline. Each entry is `<field>|<expected>`.
EXPECTED=(
  'delete_branch_on_merge|true'
  'squash_merge_commit_title|PR_TITLE'
  'squash_merge_commit_message|PR_BODY'
  'has_issues|true'
  'has_wiki|true'
  'has_projects|true'
  'allow_squash_merge|true'
  'archived|false'
  'visibility|public'
)

# Parse all fields via a single Python call. Output one line per field:
#   <field>=<value-or-empty>
parsed="$("$PYTHON" -c "
import sys, json
d = json.loads(sys.stdin.read())
for f in '''$(printf '%s\n' "${EXPECTED[@]}" | sed 's/|.*//')'''.split():
    v = d.get(f)
    if v is None:
        print(f + '=__MISSING__')
    elif isinstance(v, bool):
        print(f + '=' + ('true' if v else 'false'))
    else:
        print(f + '=' + str(v))
" <<< "$settings_json")"

drift=0
skipped=0
for entry in "${EXPECTED[@]}"; do
  field="${entry%%|*}"
  expected="${entry#*|}"
  actual="$(printf '%s\n' "$parsed" | grep "^${field}=" | head -1 | sed 's/^[^=]*=//' || true)"
  if [ "$actual" = "__MISSING__" ] || [ -z "$actual" ]; then
    printf "  SKIP:  %s (field not readable with current token permissions)\n" "$field"
    skipped=$((skipped + 1))
  elif [ "$actual" = "$expected" ]; then
    printf "  OK:    %s = %s\n" "$field" "$expected"
  else
    printf "  DRIFT: %s = %s (expected: %s)\n" "$field" "$actual" "$expected"
    drift=$((drift + 1))
  fi
done

if [ "$drift" -gt 0 ]; then
  printf >&2 "\ncheck-repo-settings: %d field(s) drifted from the ADR-0008 baseline.\n" "$drift"
  if [ "$skipped" -gt 0 ]; then
    printf >&2 "  (%d additional field(s) were unreadable and not evaluated.)\n" "$skipped"
  fi
  printf >&2 "  Resolutions:\n"
  printf >&2 "    - Restore each field via 'gh repo edit %s --<flag>' or the\n" "$REPO"
  printf >&2 "      claude-bootstrap/templates/general/scripts/setup-repo-defaults.sh script.\n"
  printf >&2 "    - If the change is intentional, update EXPECTED[] in this script\n"
  printf >&2 "      AND open an ADR documenting why the baseline changed.\n"
  exit 1
fi

echo ""
total=${#EXPECTED[@]}
checked=$((total - skipped))
echo "check-repo-settings: ${checked} of ${total} field(s) checked, no drift detected."
if [ "$skipped" -gt 0 ]; then
  echo "  ${skipped} field(s) unreadable with current token (admin-level settings). Consider running this locally with a PAT for full coverage."
fi
exit 0
