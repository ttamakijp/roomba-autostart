#!/usr/bin/env python3
"""ADR-0021 Phase 7 — GitHub Milestone progress collector.

`gh api repos/{owner}/{repo}/milestones` から open milestone 一覧を取得し、
ADR-0017 reporter 互換の JSON を stdout に出す。

slip_status は due_on 比較で 4 状態 (`on_track` / `slip_warn` /
`slip_alert` / `overdue`)。warn / alert の日数しきい値は `--warn-days` /
`--alert-days` (default 7 / 14)。

Graceful fallback: `gh` 不在 / 未認証 / API エラー時は
`{"unavailable":true,"reason":"<...>"}` を出して exit 0。

Refs: ADR-0021
"""

from __future__ import annotations

import argparse
import contextlib
import json
import shutil
import subprocess
import sys
from datetime import date, datetime

with contextlib.suppress(AttributeError, OSError):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]


def _emit_unavailable(reason: str) -> int:
    print(f"[cost-collect-milestones] WARN: {reason}", file=sys.stderr)
    json.dump({"unavailable": True, "reason": reason}, sys.stdout)
    return 0


def _detect_repo() -> str | None:
    """Detect owner/repo via gh CLI. Return None if not in a repo."""
    try:
        result = subprocess.run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        if result.returncode == 0:
            name = result.stdout.strip()
            if name and "/" in name:
                return name
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def _parse_iso(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


def _classify_slip(
    due_on: datetime | None,
    open_issues: int,
    today: date,
    warn_days: int,
    alert_days: int,
) -> str:
    if open_issues == 0:
        return "on_track"
    if due_on is None:
        return "on_track"
    delta = (due_on.date() - today).days
    if delta < 0:
        return "overdue"
    if delta <= alert_days:
        return "slip_alert"
    if delta <= warn_days:
        return "slip_warn"
    return "on_track"


def _fetch_milestones(repo: str) -> list[dict] | None:
    """Return list of milestone dicts, or None on API failure."""
    try:
        result = subprocess.run(
            [
                "gh",
                "api",
                "--paginate",
                f"repos/{repo}/milestones?state=open&per_page=100",
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
        if result.returncode != 0:
            return None
        # gh api --paginate concatenates JSON arrays — handle both cases.
        raw = result.stdout.strip()
        if not raw:
            return []
        # Try parse as single array first
        try:
            data = json.loads(raw)
            if isinstance(data, list):
                return data
        except json.JSONDecodeError:
            pass
        # Try line-delimited / concatenated arrays
        out: list[dict] = []
        for chunk in raw.replace("][", "],[").split("\n"):
            chunk = chunk.strip()
            if not chunk:
                continue
            try:
                d = json.loads(chunk)
                if isinstance(d, list):
                    out.extend(d)
            except json.JSONDecodeError:
                continue
        return out
    except (OSError, subprocess.SubprocessError):
        return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect milestone progress (ADR-0021).")
    parser.add_argument("--repo", default=None, help="owner/repo (default: auto-detect via gh)")
    parser.add_argument("--warn-days", type=int, default=7)
    parser.add_argument("--alert-days", type=int, default=14)
    parser.add_argument(
        "--today",
        default=None,
        help="Override today's date (YYYY-MM-DD) for tests.",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if args.dry_run:
        print("[cost-collect-milestones] dry-run: emitting unavailable stub", file=sys.stderr)
        json.dump({"unavailable": True, "reason": "dry-run"}, sys.stdout)
        return 0

    if not shutil.which("gh"):
        return _emit_unavailable("gh CLI not on PATH")

    try:
        auth = subprocess.run(
            ["gh", "auth", "status"], capture_output=True, text=True, check=False, timeout=10
        )
        if auth.returncode != 0:
            return _emit_unavailable("gh not authenticated (run: gh auth login)")
    except (OSError, subprocess.SubprocessError):
        return _emit_unavailable("gh auth status failed")

    repo = args.repo or _detect_repo()
    if not repo:
        return _emit_unavailable("could not detect repo (pass --repo owner/name)")

    raw_milestones = _fetch_milestones(repo)
    if raw_milestones is None:
        return _emit_unavailable(f"milestones API inaccessible for {repo}")

    if args.today:
        try:
            today = date.fromisoformat(args.today)
        except ValueError:
            today = date.today()
    else:
        today = date.today()

    milestones: list[dict] = []
    for m in raw_milestones:
        if not isinstance(m, dict):
            continue
        open_issues = int(m.get("open_issues") or 0)
        closed_issues = int(m.get("closed_issues") or 0)
        total = open_issues + closed_issues
        completion_pct = round(100.0 * closed_issues / total, 1) if total > 0 else 0.0
        due_on = _parse_iso(m.get("due_on"))
        slip_status = _classify_slip(due_on, open_issues, today, args.warn_days, args.alert_days)
        milestones.append(
            {
                "number": int(m.get("number") or 0),
                "title": str(m.get("title") or ""),
                "open_issues": open_issues,
                "closed_issues": closed_issues,
                "completion_percent": completion_pct,
                "due_on": m.get("due_on") or "",
                "slip_status": slip_status,
            }
        )

    out = {
        "repo": repo,
        "today": today.isoformat(),
        "milestones": milestones,
    }
    json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
