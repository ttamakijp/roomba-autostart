#!/usr/bin/env python3
"""ADR-0017 / ADR-0021 / ADR-0022 — Cost / Delivery / Lead time reporter.

Aggregates collector JSON from 3 ADR families into 1 markdown report:

- ADR-0017 (Phase 3 Cost)         — Claude / GH Actions / Cloud / PC / uptime
- ADR-0021 (Phase 7 Delivery)     — Milestones / Release train
- ADR-0022 (Phase 8 Lead time)    — DORA 4 metrics / CI speed / PR review

Thresholds in `scripts/cost-budget.yml` produce warn / alert sections.
`--issue` opens a GitHub Issue on alert (deduped via search).

Inputs (per軸, file path 渡し):

    --claude              JSON from cost-collect-claude.py
    --gh-actions          JSON from cost-collect-github-actions.sh
    --aws / --azure / --gcp   JSON from cloud collectors
    --pc-resource         JSON from cost-collect-pc-resource.ps1
    --runner-uptime       JSON from cost-collect-runner-uptime.ps1
    --milestones          JSON from cost-collect-milestones.py        (Phase 7)
    --release-train       JSON from cost-collect-release-train.sh     (Phase 7)
    --dora                JSON from cost-collect-dora.py              (Phase 8)
    --ci-speed            JSON from cost-collect-ci-speed.sh          (Phase 8)
    --pr-review-time      JSON from cost-collect-pr-review-time.sh    (Phase 8)
    --budget              Path to cost-budget.yml

Output: markdown to stdout (or to `--output <path>`).

Exit codes:
    0 success (whether or not warn/alert fired)
    2 invocation error (e.g. malformed budget yaml)

Refs: ADR-0017, ADR-0021, ADR-0022
"""

from __future__ import annotations

import argparse
import contextlib
import json
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Force UTF-8 on stdout. The report contains em-dash / Japanese / emoji,
# which would crash under Windows' default cp932 console encoding.
with contextlib.suppress(AttributeError, OSError):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")  # type: ignore[union-attr]


# ---------------------------------------------------------------------------
# Minimal YAML loader (no PyYAML dependency — keep collectors install-light).
# Supports only the simple key: value / nested-map shape used in
# cost-budget.yml.template. Lines starting with `#` and blank lines are
# ignored. Values are parsed as int / float / null / string.
# ---------------------------------------------------------------------------


def _parse_scalar(raw: str):
    s = raw.strip()
    if s == "" or s.lower() == "null" or s == "~":
        return None
    if s.lower() == "true":
        return True
    if s.lower() == "false":
        return False
    # strip inline comment
    if "#" in s:
        s = s.split("#", 1)[0].strip()
    if s == "":
        return None
    try:
        return int(s)
    except ValueError:
        pass
    try:
        return float(s)
    except ValueError:
        pass
    return s.strip('"').strip("'")


def _load_budget_yaml(path: Path) -> dict:
    if not path.is_file():
        return {}
    out: dict = {}
    current_key: str | None = None
    for raw in path.read_text(encoding="utf-8").splitlines():
        # ignore blank / comment-only
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        # top-level key (no leading space) ending in ':'
        if not raw.startswith((" ", "\t")) and stripped.endswith(":"):
            current_key = stripped[:-1].strip()
            out[current_key] = {}
            continue
        # nested key: value
        if (
            (raw.startswith(" ") or raw.startswith("\t"))
            and ":" in stripped
            and current_key is not None
        ):
            k, _, v = stripped.partition(":")
            out[current_key][k.strip()] = _parse_scalar(v)
            continue
    return out


# ---------------------------------------------------------------------------
# JSON load helpers
# ---------------------------------------------------------------------------


def _safe_load_json(path: str | None) -> object | None:
    if not path:
        return None
    p = Path(path)
    if not p.is_file():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None


def _is_unavailable(obj: object) -> bool:
    return isinstance(obj, dict) and bool(obj.get("unavailable"))


# ---------------------------------------------------------------------------
# Section renderers
# ---------------------------------------------------------------------------


def _render_claude(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## Claude API", ""]

    if data is None or _is_unavailable(data):
        reason = (
            (data or {}).get("reason", "no data source available")
            if isinstance(data, dict)
            else "no input"
        )
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    rows = data if isinstance(data, list) else []
    if not rows:
        lines.append("- 直近期間の使用なし")
        lines.append("")
        return "\n".join(lines), warns, alerts

    total_usd = round(sum(float(r.get("usd") or 0) for r in rows), 2)
    per_model: dict[str, float] = {}
    for r in rows:
        m = str(r.get("model") or "unknown")
        per_model[m] = per_model.get(m, 0.0) + float(r.get("usd") or 0)
    per_model_sorted = sorted(per_model.items(), key=lambda kv: -kv[1])

    lines.append(f"- 直近: **${total_usd:.2f}**")
    lines.append("- モデル別:")
    for m, v in per_model_sorted:
        lines.append(f"  - `{m}`: ${v:.2f}")

    # Budget check (monthly_usd). Compare *total observed in window* against
    # monthly threshold — this is a conservative early-warning trigger.
    warn_th = budget.get("monthly_usd_warn")
    alert_th = budget.get("monthly_usd_alert")
    if alert_th is not None and total_usd >= float(alert_th):
        alerts.append(f"Claude API spend ${total_usd:.2f} ≥ alert ${alert_th}")
    elif warn_th is not None and total_usd >= float(warn_th):
        warns.append(f"Claude API spend ${total_usd:.2f} ≥ warn ${warn_th}")
    if warn_th is not None:
        remaining_pct = max(0.0, 100.0 - (total_usd / float(warn_th)) * 100.0) if warn_th else 0.0
        lines.append(f"- 予算 ${warn_th} (warn) — 残り {remaining_pct:.0f}%")

    lines.append("")
    return "\n".join(lines), warns, alerts


def _render_gh_actions(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## GitHub Actions", ""]

    if data is None or _is_unavailable(data):
        reason = (data or {}).get("reason", "no data") if isinstance(data, dict) else "no input"
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    used = int(data.get("total_minutes_used") or 0)
    included = int(data.get("included_minutes") or 0)
    paid = int(data.get("paid_minutes_used") or 0)
    days_left = int(data.get("days_left_in_billing_cycle") or 0)

    remaining = max(0, included - used)
    lines.append(f"- 使用: **{used} min** / 残 {remaining} min (included {included})")
    if paid > 0:
        lines.append(f"- 課金分: {paid} min")
    if days_left > 0:
        lines.append(f"- 請求サイクル残: {days_left} 日")
    lines.append(
        "- ADR-0016 self-hosted runner で消化大幅減 (削減効果は workflow `runs-on` で確認)"
    )

    warn_th = budget.get("monthly_minutes_warn")
    alert_th = budget.get("monthly_minutes_alert")
    if alert_th is not None and used >= int(alert_th):
        alerts.append(f"GH Actions used {used} min ≥ alert {alert_th} min")
    elif warn_th is not None and used >= int(warn_th):
        warns.append(f"GH Actions used {used} min ≥ warn {warn_th} min")

    lines.append("")
    return "\n".join(lines), warns, alerts


def _render_cloud(name: str, data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = [f"## Cloud ({name.upper()})", ""]

    if data is None or _is_unavailable(data):
        reason = (
            (data or {}).get("reason", "no data")
            if isinstance(data, dict)
            else "collector not enabled"
        )
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    mtd = float(data.get("month_to_date_usd") or 0)
    lines.append(f"- 月初〜本日: **${mtd:.2f}**")
    by_svc = data.get("by_service") or []
    if isinstance(by_svc, list) and by_svc:
        lines.append("- サービス別 (上位 5):")
        for entry in by_svc[:5]:
            if isinstance(entry, dict):
                lines.append(
                    f"  - {entry.get('service', 'unknown')}: ${float(entry.get('usd') or 0):.2f}"
                )

    warn_th = budget.get("monthly_usd_warn")
    alert_th = budget.get("monthly_usd_alert")
    if alert_th is not None and mtd >= float(alert_th):
        alerts.append(f"{name.upper()} spend ${mtd:.2f} ≥ alert ${alert_th}")
    elif warn_th is not None and mtd >= float(warn_th):
        warns.append(f"{name.upper()} spend ${mtd:.2f} ≥ warn ${warn_th}")

    lines.append("")
    return "\n".join(lines), warns, alerts


def _render_pc(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## PC リソース (runner 同居)", ""]

    if data is None or _is_unavailable(data):
        reason = (data or {}).get("reason", "no data") if isinstance(data, dict) else "no input"
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    cpu = float(data.get("cpu_total_pct_avg") or 0)
    ram_pct = float(data.get("ram_used_pct_avg") or 0)
    runner_cpu = float(data.get("runner_cpu_pct_avg") or 0)
    lines.append(f"- CPU 平均: {cpu:.1f}% (runner 寄与: {runner_cpu:.1f}%)")
    lines.append(f"- RAM 使用: {ram_pct:.1f}%")
    procs = data.get("runner_processes") or []
    if isinstance(procs, list) and procs:
        lines.append("- runner プロセス:")
        for p in procs:
            if isinstance(p, dict):
                lines.append(
                    f"  - {p.get('name', '?')} (pid {p.get('pid', '?')}): {float(p.get('cpu_pct_avg') or 0):.1f}%"
                )
    own_warn = data.get("warning") or ""
    if own_warn:
        warns.append(f"PC resource: {own_warn}")

    warn_th = budget.get("runner_cpu_pct_warn")
    alert_th = budget.get("runner_cpu_pct_alert")
    if alert_th is not None and runner_cpu >= float(alert_th):
        alerts.append(f"runner CPU {runner_cpu:.1f}% ≥ alert {alert_th}%")
    elif warn_th is not None and runner_cpu >= float(warn_th):
        warns.append(f"runner CPU {runner_cpu:.1f}% ≥ warn {warn_th}%")

    lines.append("")
    return "\n".join(lines), warns, alerts


def _render_uptime(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## Runner uptime SLI", ""]

    if data is None or _is_unavailable(data):
        reason = (data or {}).get("reason", "no data") if isinstance(data, dict) else "no input"
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    tasks = data.get("tasks") or []
    overall = float(data.get("overall_uptime_pct") or 0)
    window = int(data.get("window_days") or 7)
    lines.append(f"- 過去 {window} 日 overall: **{overall:.1f}%**")
    if isinstance(tasks, list) and tasks:
        for t in tasks:
            if not isinstance(t, dict):
                continue
            name = t.get("name") or "?"
            pct = float(t.get("uptime_pct") or 0)
            state = t.get("state") or "?"
            line = f"  - `{name}`: {pct:.1f}% (state: {state})"
            tw = t.get("warning") or ""
            if tw:
                warns.append(f"{name}: {tw}")
                line += f" — ⚠ {tw}"
            lines.append(line)

    warn_th = budget.get("uptime_pct_warn")
    alert_th = budget.get("uptime_pct_alert")
    if alert_th is not None and overall < float(alert_th):
        alerts.append(f"runner uptime {overall:.1f}% < alert {alert_th}%")
    elif warn_th is not None and overall < float(warn_th):
        warns.append(f"runner uptime {overall:.1f}% < warn {warn_th}%")

    lines.append("")
    return "\n".join(lines), warns, alerts


# ---------------------------------------------------------------------------
# Phase 7 (Delivery) renderers — ADR-0021
# ---------------------------------------------------------------------------


def _render_milestones(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## Delivery predictability — Milestones", ""]

    if data is None or _is_unavailable(data):
        reason = (data or {}).get("reason", "no data") if isinstance(data, dict) else "no input"
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    milestones = data.get("milestones") or []
    repo = data.get("repo") or "?"
    if not isinstance(milestones, list) or not milestones:
        lines.append(f"- repo `{repo}`: open milestone なし")
        lines.append("")
        return "\n".join(lines), warns, alerts

    lines.append(f"- repo: `{repo}` ({len(milestones)} open milestone)")
    for m in milestones:
        if not isinstance(m, dict):
            continue
        title = m.get("title") or "?"
        comp = float(m.get("completion_percent") or 0)
        open_n = int(m.get("open_issues") or 0)
        closed_n = int(m.get("closed_issues") or 0)
        slip = str(m.get("slip_status") or "on_track")
        due = m.get("due_on") or ""
        badge = {
            "on_track": "🟢",
            "slip_warn": "🟡",
            "slip_alert": "🟠",
            "overdue": "🔴",
        }.get(slip, "🟢")
        due_label = due.split("T")[0] if due else "(no due)"
        lines.append(
            f"  - {badge} `{title}` {comp:.1f}% ({closed_n}/{closed_n + open_n}) "
            f"due {due_label} — {slip}"
        )
        if slip == "slip_alert" or slip == "overdue":
            alerts.append(f"milestone '{title}' status={slip} (due {due_label})")
        elif slip == "slip_warn":
            warns.append(f"milestone '{title}' status=slip_warn (due {due_label})")

    lines.append("")
    return "\n".join(lines), warns, alerts


def _render_release_train(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## Delivery predictability — Release train", ""]

    if data is None or _is_unavailable(data):
        reason = (data or {}).get("reason", "no data") if isinstance(data, dict) else "no input"
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    last = data.get("last_release") or {}
    last_tag = (last or {}).get("tag") or "(none)"
    median = data.get("cadence_median_days")
    stddev = data.get("cadence_stddev_days")
    drift = data.get("cadence_drift_ratio")
    since = int(data.get("since_last_commits") or 0)
    predicted = data.get("predicted_next_date") or "(unknown)"
    sample_size = int(data.get("sample_size") or 0)

    lines.append(f"- 直近 release: `{last_tag}` (sample={sample_size})")
    if median is not None:
        lines.append(f"- 中央値 cadence: **{median} 日** (stddev: {stddev})")
    if drift is not None:
        lines.append(f"- drift 比 (stddev/median): {drift}")
    lines.append(f"- 直近 commit (since last tag): {since}")
    lines.append(f"- 予測次回: **{predicted}**")

    drift_th = budget.get("release_cadence_drift_warn")
    if drift_th is not None and drift is not None and float(drift) >= float(drift_th):
        warns.append(f"release cadence drift {drift} ≥ warn {drift_th}")

    lines.append("")
    return "\n".join(lines), warns, alerts


# ---------------------------------------------------------------------------
# Phase 8 (Lead time / DORA) renderers — ADR-0022
# ---------------------------------------------------------------------------


def _render_dora(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## Lead time / DORA — 4 metrics", ""]

    if data is None or _is_unavailable(data):
        reason = (data or {}).get("reason", "no data") if isinstance(data, dict) else "no input"
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    window = int(data.get("window_weeks") or 12)
    deploy_freq = data.get("deploy_freq_per_week")
    lead = data.get("change_lead_time_hours_median")
    lt_n = int(data.get("change_lead_time_sample_size") or 0)
    failure = data.get("change_failure_rate")
    fail_n = int(data.get("change_failure_count") or 0)
    fail_total = int(data.get("change_total_count") or 0)
    mttr = data.get("mttr_hours_median")
    mttr_n = int(data.get("mttr_sample_size") or 0)

    lines.append(f"- window: 直近 {window} 週")
    lines.append(
        f"  - **Deploy frequency**: {deploy_freq if deploy_freq is not None else 'n/a'} / week"
    )
    lines.append(
        f"  - **Change lead time**: {lead if lead is not None else 'n/a'} h (median, n={lt_n})"
    )
    lines.append(
        f"  - **Change failure rate**: "
        f"{failure if failure is not None else 'n/a'} ({fail_n}/{fail_total})"
    )
    lines.append(f"  - **MTTR**: {mttr if mttr is not None else 'n/a'} h (median, n={mttr_n})")
    note = data.get("mttr_note") or ""
    if note:
        lines.append(f"  - _{note}_")

    # Thresholds
    min_deploy = budget.get("deploy_freq_min_per_week")
    if (
        min_deploy is not None
        and deploy_freq is not None
        and float(deploy_freq) < float(min_deploy)
    ):
        warns.append(f"deploy freq {deploy_freq}/wk < min {min_deploy}/wk")

    max_lead = budget.get("change_lead_time_max_hours")
    if max_lead is not None and lead is not None and float(lead) > float(max_lead):
        warns.append(f"change lead time {lead}h > max {max_lead}h")

    max_failure = budget.get("change_failure_rate_max")
    if max_failure is not None and failure is not None and float(failure) > float(max_failure):
        alerts.append(f"change failure rate {failure} > max {max_failure}")

    max_mttr = budget.get("mttr_max_hours")
    if max_mttr is not None and mttr is not None and float(mttr) > float(max_mttr):
        alerts.append(f"MTTR {mttr}h > max {max_mttr}h")

    lines.append("")
    return "\n".join(lines), warns, alerts


def _render_ci_speed(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## Lead time / DORA — CI speed", ""]

    if data is None or _is_unavailable(data):
        reason = (data or {}).get("reason", "no data") if isinstance(data, dict) else "no input"
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    workflows = data.get("workflows") or []
    window_runs = int(data.get("window_runs") or 0)
    lines.append(f"- 直近 {window_runs} 実行 (workflow 別 / median 降順)")
    if isinstance(workflows, list):
        for wf in workflows[:10]:
            if not isinstance(wf, dict):
                continue
            name = wf.get("name") or "?"
            median = float(wf.get("median_min") or 0)
            p90 = float(wf.get("p90_min") or 0)
            worst = float(wf.get("worst_min") or 0)
            success = float(wf.get("success_rate") or 0)
            samples = int(wf.get("samples") or 0)
            lines.append(
                f"  - `{name}` median {median:.1f}m / p90 {p90:.1f}m / worst {worst:.1f}m "
                f"(success {success * 100:.0f}%, n={samples})"
            )

    lines.append("")
    return "\n".join(lines), warns, alerts


def _render_pr_review_time(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## Lead time / DORA — PR review time", ""]

    if data is None or _is_unavailable(data):
        reason = (data or {}).get("reason", "no data") if isinstance(data, dict) else "no input"
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    window_prs = int(data.get("window_prs") or 0)
    samples = int(data.get("sample_size") or 0)
    no_review = int(data.get("no_review_count") or 0)
    first = data.get("created_to_first_review_hours_median")
    approve = data.get("first_review_to_approved_hours_median")

    lines.append(f"- 直近 {window_prs} merged PR (review あり: {samples}, なし: {no_review})")
    lines.append(
        f"  - **created → first review**: {first if first is not None else 'n/a'} h (median)"
    )
    lines.append(
        f"  - **first review → approved**: {approve if approve is not None else 'n/a'} h (median)"
    )

    lines.append("")
    return "\n".join(lines), warns, alerts


# ---------------------------------------------------------------------------
# Issue auto-open (only on alert)
# ---------------------------------------------------------------------------


def _render_adr_drafts(data: object, budget: dict) -> tuple[str, list[str], list[str]]:
    warns: list[str] = []
    alerts: list[str] = []
    lines: list[str] = ["## ADR Draft trends", ""]

    if data is None or _is_unavailable(data):
        reason = (data or {}).get("reason", "no data") if isinstance(data, dict) else "no input"
        lines.append(f"- 観測: **unavailable** ({reason})")
        lines.append("")
        return "\n".join(lines), warns, alerts

    if not isinstance(data, dict):
        lines.append("- 観測: unexpected shape")
        lines.append("")
        return "\n".join(lines), warns, alerts

    pending = int(data.get("pending") or 0)
    rejected = int(data.get("rejected") or 0)
    accepted = int(data.get("accepted") or 0)
    stale = int(data.get("stale") or 0)
    threshold = int(data.get("stale_threshold_days") or 90)

    lines.append(f"- pending (議論中 draft): **{pending}**")
    lines.append(f"- rejected (却下済 draft): {rejected}")
    lines.append(f"- accepted (昇格済 ADR): {accepted}")
    lines.append(f"- stale (>= {threshold} 日経過 draft): **{stale}**")

    stale_th = budget.get("stale_drafts_warn")
    if stale_th is not None and stale >= int(stale_th):
        warns.append(f"stale ADR drafts {stale} >= warn {stale_th}")
    pending_th = budget.get("pending_drafts_warn")
    if pending_th is not None and pending >= int(pending_th):
        warns.append(f"pending ADR drafts {pending} >= warn {pending_th}")

    lines.append("")
    return "\n".join(lines), warns, alerts


def _open_issue_if_alert(title: str, body: str) -> None:
    if not shutil.which("gh"):
        print("[cost-report] WARN: gh CLI absent; cannot open issue", file=sys.stderr)
        return

    # Dedup: skip if an open issue with the same title (or our marker label)
    # already exists.
    try:
        existing = subprocess.run(
            ["gh", "issue", "list", "--state", "open", "--search", title, "--json", "title"],
            capture_output=True,
            text=True,
            check=False,
        )
        if existing.returncode == 0 and existing.stdout.strip():
            payload = json.loads(existing.stdout)
            for item in payload:
                if isinstance(item, dict) and item.get("title") == title:
                    print(
                        f"[cost-report] open issue '{title}' already exists; not opening duplicate",
                        file=sys.stderr,
                    )
                    return
    except (json.JSONDecodeError, OSError):
        pass

    rc = subprocess.run(
        ["gh", "issue", "create", "--title", title, "--body", body],
        capture_output=True,
        text=True,
        check=False,
    )
    if rc.returncode != 0:
        print(
            f"[cost-report] WARN: gh issue create failed: {rc.stderr.strip()}",
            file=sys.stderr,
        )


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------


def build_report(
    *,
    claude_data: object,
    gh_actions_data: object,
    aws_data: object,
    azure_data: object,
    gcp_data: object,
    pc_data: object,
    uptime_data: object,
    budget: dict,
    today: str | None = None,
    milestones_data: object = None,
    release_train_data: object = None,
    dora_data: object = None,
    ci_speed_data: object = None,
    pr_review_time_data: object = None,
    adr_drafts_data: object = None,
) -> tuple[str, list[str], list[str]]:
    """Pure render function — exposed for unit tests."""
    today = today or date.today().isoformat()

    body: list[str] = [
        f"# Observation Report — {today}",
        "",
        "_ADR-0017 (Cost) / ADR-0021 (Delivery) / ADR-0022 (Lead time) — weekly 集約_",
        "",
    ]
    all_warns: list[str] = []
    all_alerts: list[str] = []

    body.append("# Cost (ADR-0017 Phase 3)")
    body.append("")

    for section, data, b_key in [
        (_render_claude, claude_data, "claude"),
        (_render_gh_actions, gh_actions_data, "github_actions"),
        (_render_pc, pc_data, "pc_resource"),
        (_render_uptime, uptime_data, "runner_uptime"),
    ]:
        text, w, a = section(data, budget.get(b_key, {}))
        body.append(text)
        all_warns.extend(w)
        all_alerts.extend(a)

    for name, data, b_key in [
        ("aws", aws_data, "cloud_aws"),
        ("azure", azure_data, "cloud_azure"),
        ("gcp", gcp_data, "cloud_gcp"),
    ]:
        text, w, a = _render_cloud(name, data, budget.get(b_key, {}))
        body.append(text)
        all_warns.extend(w)
        all_alerts.extend(a)

    # Phase 7 (Delivery predictability) — ADR-0021
    body.append("# Delivery predictability (ADR-0021 Phase 7)")
    body.append("")
    delivery_budget = budget.get("delivery", {}) if isinstance(budget, dict) else {}
    for section, data in [
        (_render_milestones, milestones_data),
        (_render_release_train, release_train_data),
    ]:
        text, w, a = section(data, delivery_budget)
        body.append(text)
        all_warns.extend(w)
        all_alerts.extend(a)

    # Phase 8 (Lead time / DORA) — ADR-0022
    body.append("# Lead time / DORA (ADR-0022 Phase 8)")
    body.append("")
    lead_time_budget = budget.get("lead_time", {}) if isinstance(budget, dict) else {}
    for section, data in [
        (_render_dora, dora_data),
        (_render_ci_speed, ci_speed_data),
        (_render_pr_review_time, pr_review_time_data),
    ]:
        text, w, a = section(data, lead_time_budget)
        body.append(text)
        all_warns.extend(w)
        all_alerts.extend(a)

    # ADR-0023 — ADR Draft trends (Q2 architecture-drift precision)
    body.append("# ADR Draft trends (ADR-0023)")
    body.append("")
    adr_drafts_budget = budget.get("adr_drafts", {}) if isinstance(budget, dict) else {}
    text, w, a = _render_adr_drafts(adr_drafts_data, adr_drafts_budget)
    body.append(text)
    all_warns.extend(w)
    all_alerts.extend(a)

    # Warn / alert summary at the top of the report (after the title) is
    # easier to skim, but we also keep a dedicated section at the bottom
    # for the issue body.
    warn_section = ["## 警告 / Alert", ""]
    if all_alerts:
        warn_section.append("### 🚨 Alert")
        for a in all_alerts:
            warn_section.append(f"- {a}")
        warn_section.append("")
    if all_warns:
        warn_section.append("### ⚠ Warn")
        for w in all_warns:
            warn_section.append(f"- {w}")
        warn_section.append("")
    if not all_alerts and not all_warns:
        warn_section.append("- (なし)")
        warn_section.append("")

    body.append("\n".join(warn_section))
    return "\n".join(body), all_warns, all_alerts


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Aggregate cost observation report (ADR-0017).")
    parser.add_argument("--claude", default=None)
    parser.add_argument("--gh-actions", default=None)
    parser.add_argument("--aws", default=None)
    parser.add_argument("--azure", default=None)
    parser.add_argument("--gcp", default=None)
    parser.add_argument("--pc-resource", default=None)
    parser.add_argument("--runner-uptime", default=None)
    # ADR-0021 Phase 7
    parser.add_argument("--milestones", default=None)
    parser.add_argument("--release-train", default=None)
    # ADR-0022 Phase 8
    parser.add_argument("--dora", default=None)
    parser.add_argument("--ci-speed", default=None)
    parser.add_argument("--pr-review-time", default=None)
    # ADR-0023
    parser.add_argument("--adr-drafts", default=None)
    parser.add_argument("--budget", default=None)
    parser.add_argument(
        "--issue",
        action="store_true",
        help="Open a GitHub Issue when at least one alert fires.",
    )
    parser.add_argument(
        "--output", default=None, help="Write report to this path instead of stdout."
    )
    parser.add_argument(
        "--today", default=None, help="Override today's date (YYYY-MM-DD) for tests."
    )
    args = parser.parse_args(argv)

    if args.budget:
        budget_path = Path(args.budget)
    else:
        candidate = REPO_ROOT / "cost-budget.yml"
        if candidate.is_file():
            budget_path = candidate
        else:
            budget_path = REPO_ROOT / "scripts" / "cost-budget.yml.template"

    budget = _load_budget_yaml(budget_path) if budget_path.is_file() else {}

    md, warns, alerts = build_report(
        claude_data=_safe_load_json(args.claude),
        gh_actions_data=_safe_load_json(args.gh_actions),
        aws_data=_safe_load_json(args.aws),
        azure_data=_safe_load_json(args.azure),
        gcp_data=_safe_load_json(args.gcp),
        pc_data=_safe_load_json(args.pc_resource),
        uptime_data=_safe_load_json(args.runner_uptime),
        milestones_data=_safe_load_json(args.milestones),
        release_train_data=_safe_load_json(args.release_train),
        dora_data=_safe_load_json(args.dora),
        ci_speed_data=_safe_load_json(args.ci_speed),
        pr_review_time_data=_safe_load_json(args.pr_review_time),
        adr_drafts_data=_safe_load_json(args.adr_drafts),
        budget=budget,
        today=args.today,
    )

    if args.output:
        Path(args.output).write_text(md, encoding="utf-8")
    else:
        sys.stdout.write(md)
        if not md.endswith("\n"):
            sys.stdout.write("\n")

    if args.issue and alerts:
        title = f"[cost-observation] alert {date.today().isoformat()}: {len(alerts)} threshold(s) exceeded"
        _open_issue_if_alert(title, md)

    return 0


if __name__ == "__main__":
    sys.exit(main())
