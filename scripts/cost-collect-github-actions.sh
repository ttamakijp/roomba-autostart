#!/usr/bin/env bash
# ADR-0017 Phase 3 GitHub Actions usage collector.
#
# Fetches the current user's Actions billing summary via `gh api` and emits
# JSON on stdout in the shape expected by `scripts/cost-report.py`:
#
#   {
#     "total_minutes_used": 320,
#     "included_minutes": 2000,
#     "paid_minutes_used": 0,
#     "days_left_in_billing_cycle": 12,
#     "billing_cycle_end_date": "2026-06-01"
#   }
#
# If `gh` is unavailable or unauthenticated, emit a stub object with
# `"unavailable": true` and exit 0 (graceful fallback — reporter marks
# this row as observation-unavailable; we do not fail CI).
#
# Usage:
#   bash scripts/cost-collect-github-actions.sh [--user <user>] [--dry-run]
#
# Refs: ADR-0017
set -euo pipefail

USER_ARG=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)    USER_ARG="$2"; shift 2 ;;
    --user=*)  USER_ARG="${1#--user=}"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf >&2 "[cost-collect-github-actions] ERROR: unknown option: %s\n" "$1"
      exit 2
      ;;
  esac
done

emit_unavailable() {
  local reason="$1"
  printf >&2 "[cost-collect-github-actions] WARN: %s — emitting unavailable stub.\n" "$reason"
  printf '{"unavailable":true,"reason":"%s"}\n' "$reason"
  exit 0
}

if [ "$DRY_RUN" -eq 1 ]; then
  printf >&2 "[cost-collect-github-actions] dry-run: emitting unavailable stub.\n"
  printf '{"unavailable":true,"reason":"dry-run"}\n'
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  emit_unavailable "gh CLI not on PATH"
fi

if ! gh auth status >/dev/null 2>&1; then
  emit_unavailable "gh not authenticated (run: gh auth login)"
fi

if [ -z "$USER_ARG" ]; then
  USER_ARG="$(gh api user --jq .login 2>/dev/null || true)"
fi
if [ -z "$USER_ARG" ]; then
  emit_unavailable "could not determine GitHub user"
fi

# gh api: GET /users/{user}/settings/billing/actions
# Returns: { total_minutes_used, total_paid_minutes_used, included_minutes,
#            minutes_used_breakdown, days_left_in_billing_cycle? }
# The endpoint shape has shifted historically — handle absent fields with
# `// 0` and `// ""` in jq so we always emit a complete schema.
if ! raw="$(gh api "users/${USER_ARG}/settings/billing/actions" 2>/dev/null)"; then
  emit_unavailable "billing endpoint inaccessible (token may lack 'user' or 'read:billing' scope)"
fi

# Compose normalized output. days_left / billing_cycle_end_date may be absent
# depending on the account type — emit 0 / "" when missing.
printf '%s' "$raw" | python3 - <<'PYEOF'
import json
import sys

try:
    data = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print('{"unavailable":true,"reason":"non-JSON billing response"}')
    sys.exit(0)

if not isinstance(data, dict):
    print('{"unavailable":true,"reason":"unexpected billing response"}')
    sys.exit(0)

out = {
    "total_minutes_used": int(data.get("total_minutes_used") or 0),
    "included_minutes": int(data.get("included_minutes") or 0),
    "paid_minutes_used": int(data.get("total_paid_minutes_used") or 0),
    "days_left_in_billing_cycle": int(data.get("days_left_in_billing_cycle") or 0),
    "billing_cycle_end_date": data.get("billing_cycle_end_date") or "",
}
print(json.dumps(out))
PYEOF
