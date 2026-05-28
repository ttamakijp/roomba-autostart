#!/usr/bin/env bash
# ADR-0021 Phase 7 Release train cadence collector.
#
# Fetches the most recent N releases via `gh release list` and computes:
#   - cadence_median_days: median day-gap between consecutive releases
#   - cadence_stddev_days: standard deviation of gaps
#   - since_last_commits: commit count since last release tag
#   - predicted_next_date: median-extrapolated next release date
#
# Output JSON shape:
#
#   {
#     "last_release": {"tag": "v3.5.10", "published_at": "2026-05-20T..."},
#     "sample_size": 5,
#     "cadence_median_days": 7.0,
#     "cadence_stddev_days": 1.4,
#     "since_last_commits": 12,
#     "predicted_next_date": "2026-05-27",
#     "cadence_drift_ratio": 0.20
#   }
#
# Graceful fallback: gh missing / unauthenticated / no releases →
# {"unavailable":true,"reason":"..."} on stdout, exit 0.
#
# Refs: ADR-0021
set -euo pipefail

WINDOW=5
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window)    WINDOW="$2"; shift 2 ;;
    --window=*)  WINDOW="${1#--window=}"; shift ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf >&2 "[cost-collect-release-train] ERROR: unknown option: %s\n" "$1"
      exit 2
      ;;
  esac
done

emit_unavailable() {
  local reason="$1"
  printf >&2 "[cost-collect-release-train] WARN: %s\n" "$reason"
  printf '{"unavailable":true,"reason":"%s"}\n' "$reason"
  exit 0
}

if [ "$DRY_RUN" -eq 1 ]; then
  printf >&2 "[cost-collect-release-train] dry-run\n"
  printf '{"unavailable":true,"reason":"dry-run"}\n'
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  emit_unavailable "gh CLI not on PATH"
fi

if ! gh auth status >/dev/null 2>&1; then
  emit_unavailable "gh not authenticated"
fi

# gh release list --json tagName,publishedAt --limit N
if ! raw="$(gh release list --json tagName,publishedAt --limit "$WINDOW" 2>/dev/null)"; then
  emit_unavailable "release list API inaccessible"
fi

# Count commits since last release tag. May fail in shallow clones, so use
# a graceful fallback to 0.
last_tag="$(printf '%s' "$raw" | python3 -c 'import json,sys; data=json.loads(sys.stdin.read() or "[]"); print(data[0]["tagName"] if data else "")' 2>/dev/null || true)"
since_commits=0
if [ -n "$last_tag" ]; then
  since_commits="$(git rev-list "${last_tag}..HEAD" --count 2>/dev/null || echo 0)"
fi

printf '%s' "$raw" | SINCE_COMMITS="$since_commits" python3 - <<'PYEOF'
import json
import os
import statistics
import sys
from datetime import datetime, timedelta, timezone

try:
    releases = json.loads(sys.stdin.read() or "[]")
except json.JSONDecodeError:
    print('{"unavailable":true,"reason":"non-JSON release list"}')
    sys.exit(0)

if not isinstance(releases, list):
    print('{"unavailable":true,"reason":"unexpected release list shape"}')
    sys.exit(0)

if len(releases) < 1:
    print('{"unavailable":true,"reason":"no releases yet"}')
    sys.exit(0)


def _parse(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


# releases returned newest-first by gh release list
dated = [(r.get("tagName"), _parse(r.get("publishedAt"))) for r in releases]
dated = [(t, d) for t, d in dated if d is not None]
last_tag, last_date = (dated[0] if dated else (None, None))

gaps_days = []
for (_, d1), (_, d2) in zip(dated[:-1], dated[1:]):
    delta = (d1 - d2).total_seconds() / 86400.0
    if delta > 0:
        gaps_days.append(delta)

out = {
    "last_release": {
        "tag": last_tag or "",
        "published_at": last_date.isoformat() if last_date else "",
    },
    "sample_size": len(dated),
    "cadence_median_days": None,
    "cadence_stddev_days": None,
    "since_last_commits": int(os.environ.get("SINCE_COMMITS") or 0),
    "predicted_next_date": None,
    "cadence_drift_ratio": None,
}

if gaps_days:
    median = statistics.median(gaps_days)
    out["cadence_median_days"] = round(median, 2)
    if len(gaps_days) >= 2:
        stddev = statistics.pstdev(gaps_days)
        out["cadence_stddev_days"] = round(stddev, 2)
        if median > 0:
            out["cadence_drift_ratio"] = round(stddev / median, 3)
    if last_date is not None and median > 0:
        predicted = last_date + timedelta(days=median)
        out["predicted_next_date"] = predicted.date().isoformat()

print(json.dumps(out))
PYEOF
