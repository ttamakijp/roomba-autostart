#!/usr/bin/env python3
"""ADR-0022 Phase 8 — DORA 4 metrics collector.

Computes the 4 DORA metrics from GitHub data via `gh api`:

- **deploy_freq_per_week**: median tag/release count per ISO week
  (window: trailing 12 weeks by default)
- **change_lead_time_hours_median**: PR `created_at` → `merged_at` median
- **change_failure_rate**: heuristic — fraction of merged PRs whose title
  matches `^(fix|hotfix|revert):` over the same window
- **mttr_hours_median**: median `created_at` → `closed_at` for issues with
  the `incident` label

Graceful fallback emits `{"unavailable":true,"reason":"..."}` on stdout
and exits 0 if `gh` is missing, unauthenticated, or repo detection fails.

If a single metric cannot be computed (e.g. no `incident` label, no tags),
that metric is set to `null` but the overall payload remains available.

Refs: ADR-0022
"""

from __future__ import annotations

import argparse
import contextlib
import json
import re
import shutil
import statistics
import subprocess
import sys
from datetime import datetime, timedelta, timezone

with contextlib.suppress(AttributeError, OSError):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]


FAILURE_TITLE_RE = re.compile(r"^\s*(fix|hotfix|revert)(\(.+?\))?\s*:", re.IGNORECASE)


def _emit_unavailable(reason: str) -> int:
    print(f"[cost-collect-dora] WARN: {reason}", file=sys.stderr)
    json.dump({"unavailable": True, "reason": reason}, sys.stdout)
    return 0


def _parse_iso(s: str | None):
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError):
        return None


def _detect_repo() -> str | None:
    try:
        r = subprocess.run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        if r.returncode == 0 and "/" in r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def _gh_api_json(args: list[str], timeout: int = 30):
    try:
        r = subprocess.run(
            ["gh"] + args, capture_output=True, text=True, check=False, timeout=timeout
        )
        if r.returncode != 0:
            return None
        raw = r.stdout.strip()
        if not raw:
            return []
        return json.loads(raw)
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return None


def _compute_deploy_freq(releases, window_weeks: int, now: datetime) -> float | None:
    if not isinstance(releases, list):
        return None
    cutoff = now - timedelta(weeks=window_weeks)
    by_week: dict[str, int] = {}
    for r in releases:
        if not isinstance(r, dict):
            continue
        d = _parse_iso(r.get("publishedAt") or r.get("createdAt"))
        if d is None or d < cutoff:
            continue
        # ISO week label (YYYY-Www)
        iso = d.isocalendar()
        key = f"{iso[0]}-W{iso[1]:02d}"
        by_week[key] = by_week.get(key, 0) + 1
    if not by_week:
        return 0.0
    return round(statistics.median(by_week.values()), 2)


def _compute_lead_time(prs, window_weeks: int, now: datetime) -> tuple[float | None, int]:
    """Return (median_hours, sample_size)."""
    if not isinstance(prs, list):
        return None, 0
    cutoff = now - timedelta(weeks=window_weeks)
    hours: list[float] = []
    for pr in prs:
        if not isinstance(pr, dict):
            continue
        merged = _parse_iso(pr.get("mergedAt"))
        if merged is None or merged < cutoff:
            continue
        created = _parse_iso(pr.get("createdAt"))
        if created is None:
            continue
        h = (merged - created).total_seconds() / 3600.0
        if h >= 0:
            hours.append(h)
    if not hours:
        return None, 0
    return round(statistics.median(hours), 2), len(hours)


def _compute_failure_rate(prs, window_weeks: int, now: datetime) -> tuple[float | None, int, int]:
    """Return (rate, failure_count, total)."""
    if not isinstance(prs, list):
        return None, 0, 0
    cutoff = now - timedelta(weeks=window_weeks)
    total = 0
    failures = 0
    for pr in prs:
        if not isinstance(pr, dict):
            continue
        merged = _parse_iso(pr.get("mergedAt"))
        if merged is None or merged < cutoff:
            continue
        total += 1
        title = str(pr.get("title") or "")
        if FAILURE_TITLE_RE.match(title):
            failures += 1
    if total == 0:
        return None, 0, 0
    return round(failures / total, 3), failures, total


def _compute_mttr(issues, window_weeks: int, now: datetime) -> tuple[float | None, int]:
    """Return (median_hours, sample_size). Operates only on issues that
    were closed and had the `incident` label (caller filters by label)."""
    if not isinstance(issues, list):
        return None, 0
    cutoff = now - timedelta(weeks=window_weeks)
    hours: list[float] = []
    for issue in issues:
        if not isinstance(issue, dict):
            continue
        closed = _parse_iso(issue.get("closedAt"))
        if closed is None or closed < cutoff:
            continue
        created = _parse_iso(issue.get("createdAt"))
        if created is None:
            continue
        h = (closed - created).total_seconds() / 3600.0
        if h >= 0:
            hours.append(h)
    if not hours:
        return None, 0
    return round(statistics.median(hours), 2), len(hours)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect DORA 4 metrics (ADR-0022).")
    parser.add_argument("--repo", default=None)
    parser.add_argument("--window-weeks", type=int, default=12)
    parser.add_argument("--limit", type=int, default=200, help="Max PRs / issues to scan")
    parser.add_argument("--incident-label", default="incident")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if args.dry_run:
        print("[cost-collect-dora] dry-run", file=sys.stderr)
        json.dump({"unavailable": True, "reason": "dry-run"}, sys.stdout)
        return 0

    if not shutil.which("gh"):
        return _emit_unavailable("gh CLI not on PATH")

    try:
        auth = subprocess.run(
            ["gh", "auth", "status"], capture_output=True, text=True, check=False, timeout=10
        )
        if auth.returncode != 0:
            return _emit_unavailable("gh not authenticated")
    except (OSError, subprocess.SubprocessError):
        return _emit_unavailable("gh auth status failed")

    repo = args.repo or _detect_repo()
    if not repo:
        return _emit_unavailable("could not detect repo")

    now = datetime.now(timezone.utc)

    releases = _gh_api_json(
        [
            "release",
            "list",
            "--repo",
            repo,
            "--limit",
            str(args.limit),
            "--json",
            "tagName,publishedAt,createdAt",
        ]
    )
    prs = _gh_api_json(
        [
            "pr",
            "list",
            "--repo",
            repo,
            "--state",
            "merged",
            "--limit",
            str(args.limit),
            "--json",
            "number,title,createdAt,mergedAt",
        ]
    )
    incident_issues = _gh_api_json(
        [
            "issue",
            "list",
            "--repo",
            repo,
            "--state",
            "closed",
            "--limit",
            str(args.limit),
            "--label",
            args.incident_label,
            "--json",
            "number,title,createdAt,closedAt",
        ]
    )

    deploy_freq = _compute_deploy_freq(releases or [], args.window_weeks, now)
    lead_time, lt_samples = _compute_lead_time(prs or [], args.window_weeks, now)
    failure_rate, fail_n, fail_total = _compute_failure_rate(prs or [], args.window_weeks, now)
    mttr, mttr_samples = _compute_mttr(incident_issues or [], args.window_weeks, now)

    out = {
        "repo": repo,
        "window_weeks": args.window_weeks,
        "deploy_freq_per_week": deploy_freq,
        "change_lead_time_hours_median": lead_time,
        "change_lead_time_sample_size": lt_samples,
        "change_failure_rate": failure_rate,
        "change_failure_count": fail_n,
        "change_total_count": fail_total,
        "mttr_hours_median": mttr,
        "mttr_sample_size": mttr_samples,
        "incident_label": args.incident_label,
    }

    if incident_issues is None:
        out["mttr_note"] = (
            f"incident_issues query failed — label '{args.incident_label}' "
            "may be absent; MTTR set to null"
        )

    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
