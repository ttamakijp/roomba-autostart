#!/usr/bin/env bash
# ADR-0022 Phase 8 CI speed collector.
#
# Aggregates workflow run durations via `gh run list --json`.
# Output JSON shape:
#
#   {
#     "window_runs": 100,
#     "workflows": [
#       {
#         "name": "ci",
#         "samples": 42,
#         "median_min": 3.5,
#         "p90_min": 5.2,
#         "worst_min": 9.1,
#         "success_rate": 0.95
#       }
#     ]
#   }
#
# Graceful fallback: gh missing / unauthenticated → unavailable stub.
#
# Refs: ADR-0022
set -euo pipefail

LIMIT=100
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
      printf >&2 "[cost-collect-ci-speed] ERROR: unknown option: %s\n" "$1"
      exit 2
      ;;
  esac
done

emit_unavailable() {
  local reason="$1"
  printf >&2 "[cost-collect-ci-speed] WARN: %s\n" "$reason"
  printf '{"unavailable":true,"reason":"%s"}\n' "$reason"
  exit 0
}

if [ "$DRY_RUN" -eq 1 ]; then
  printf >&2 "[cost-collect-ci-speed] dry-run\n"
  printf '{"unavailable":true,"reason":"dry-run"}\n'
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  emit_unavailable "gh CLI not on PATH"
fi

if ! gh auth status >/dev/null 2>&1; then
  emit_unavailable "gh not authenticated"
fi

# gh run list emits createdAt + updatedAt; duration = updated - created.
# Note: this is wall-clock between queued and final state; close enough for
# weekly trend observation.
if ! raw="$(gh run list --limit "$LIMIT" --json name,status,conclusion,createdAt,updatedAt 2>/dev/null)"; then
  emit_unavailable "run list API inaccessible"
fi

printf '%s' "$raw" | python3 - <<'PYEOF'
import json
import statistics
import sys
from datetime import datetime

try:
    runs = json.loads(sys.stdin.read() or "[]")
except json.JSONDecodeError:
    print('{"unavailable":true,"reason":"non-JSON run list"}')
    sys.exit(0)


def _parse(s):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


by_wf: dict[str, dict] = {}
for run in runs if isinstance(runs, list) else []:
    if not isinstance(run, dict):
        continue
    name = str(run.get("name") or "unknown")
    created = _parse(run.get("createdAt"))
    updated = _parse(run.get("updatedAt"))
    if created is None or updated is None:
        continue
    duration_min = (updated - created).total_seconds() / 60.0
    if duration_min < 0:
        continue
    bucket = by_wf.setdefault(
        name, {"durations": [], "success": 0, "total": 0}
    )
    bucket["durations"].append(duration_min)
    bucket["total"] += 1
    if (run.get("conclusion") or "").lower() == "success":
        bucket["success"] += 1


def _percentile(values, pct):
    if not values:
        return None
    s = sorted(values)
    idx = max(0, min(len(s) - 1, int(round((pct / 100.0) * (len(s) - 1)))))
    return s[idx]


workflows = []
for name, bucket in by_wf.items():
    durations = bucket["durations"]
    total = bucket["total"]
    if total == 0:
        continue
    workflows.append(
        {
            "name": name,
            "samples": total,
            "median_min": round(statistics.median(durations), 2),
            "p90_min": round(_percentile(durations, 90) or 0.0, 2),
            "worst_min": round(max(durations), 2),
            "success_rate": round(bucket["success"] / total, 3),
        }
    )

workflows.sort(key=lambda w: -w["median_min"])

out = {
    "window_runs": sum(w["samples"] for w in workflows),
    "workflows": workflows,
}
print(json.dumps(out))
PYEOF
