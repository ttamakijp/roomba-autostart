#!/usr/bin/env bash
# ADR-0022 Phase 8 PR review time collector.
#
# Measures two latencies on recently-merged PRs:
#   - created_to_first_review: PR opened → first non-author review comment
#   - first_review_to_approved: first review → approved (or merged if never
#     formally approved)
#
# Output JSON shape:
#
#   {
#     "window_prs": 50,
#     "sample_size": 32,
#     "created_to_first_review_hours_median": 5.4,
#     "first_review_to_approved_hours_median": 1.2,
#     "no_review_count": 18
#   }
#
# Refs: ADR-0022
set -euo pipefail

LIMIT=50
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --limit)    LIMIT="$2"; shift 2 ;;
    --limit=*)  LIMIT="${1#--limit=}"; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf >&2 "[cost-collect-pr-review-time] ERROR: unknown option: %s\n" "$1"
      exit 2
      ;;
  esac
done

emit_unavailable() {
  local reason="$1"
  printf >&2 "[cost-collect-pr-review-time] WARN: %s\n" "$reason"
  printf '{"unavailable":true,"reason":"%s"}\n' "$reason"
  exit 0
}

if [ "$DRY_RUN" -eq 1 ]; then
  printf >&2 "[cost-collect-pr-review-time] dry-run\n"
  printf '{"unavailable":true,"reason":"dry-run"}\n'
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  emit_unavailable "gh CLI not on PATH"
fi

if ! gh auth status >/dev/null 2>&1; then
  emit_unavailable "gh not authenticated"
fi

# gh pr list --json includes reviews[] only if requested. createdAt, mergedAt,
# author.login are also needed.
if ! raw="$(gh pr list --state merged --limit "$LIMIT" \
    --json number,author,createdAt,mergedAt,reviews 2>/dev/null)"; then
  emit_unavailable "pr list API inaccessible"
fi

printf '%s' "$raw" | python3 - <<'PYEOF'
import json
import statistics
import sys
from datetime import datetime

try:
    prs = json.loads(sys.stdin.read() or "[]")
except json.JSONDecodeError:
    print('{"unavailable":true,"reason":"non-JSON pr list"}')
    sys.exit(0)


def _parse(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


first_review_hours: list[float] = []
review_to_approved_hours: list[float] = []
no_review = 0
total = 0

for pr in prs if isinstance(prs, list) else []:
    if not isinstance(pr, dict):
        continue
    total += 1
    created = _parse(pr.get("createdAt"))
    merged = _parse(pr.get("mergedAt"))
    if created is None:
        continue
    author = ((pr.get("author") or {}).get("login") or "").lower()
    reviews = pr.get("reviews") or []

    # Filter out reviews authored by the PR author (self-comments) and
    # COMMENTED-only entries with no body.
    non_author_reviews = []
    for rv in reviews:
        if not isinstance(rv, dict):
            continue
        rv_author = ((rv.get("author") or {}).get("login") or "").lower()
        if rv_author and rv_author == author:
            continue
        non_author_reviews.append(rv)

    if not non_author_reviews:
        no_review += 1
        continue

    # Sort by submittedAt
    parsed = []
    for rv in non_author_reviews:
        ts = _parse(rv.get("submittedAt"))
        if ts is not None:
            parsed.append((ts, str(rv.get("state") or "").upper()))
    if not parsed:
        no_review += 1
        continue
    parsed.sort(key=lambda x: x[0])

    first_ts = parsed[0][0]
    first_review_hours.append((first_ts - created).total_seconds() / 3600.0)

    # First APPROVED, else merged time
    approved_ts = None
    for ts, state in parsed:
        if state == "APPROVED":
            approved_ts = ts
            break
    end_ts = approved_ts or merged
    if end_ts is not None and end_ts >= first_ts:
        review_to_approved_hours.append((end_ts - first_ts).total_seconds() / 3600.0)


def _median(values):
    return round(statistics.median(values), 2) if values else None


out = {
    "window_prs": total,
    "sample_size": len(first_review_hours),
    "no_review_count": no_review,
    "created_to_first_review_hours_median": _median(first_review_hours),
    "first_review_to_approved_hours_median": _median(review_to_approved_hours),
}
print(json.dumps(out))
PYEOF
