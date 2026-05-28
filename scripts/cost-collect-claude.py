#!/usr/bin/env python3
"""ADR-0017 Phase 3 Claude API 使用量 collector.

Anthropic Admin API (`GET /v1/organizations/usage_report/messages`) から
過去 N 日 (default 7) の使用量を取得して、`cost-report.py` が食える形の
JSON 配列を stdout に出す。

優先順位:

1. `ANTHROPIC_ADMIN_API_KEY` 環境変数が立っていれば Admin API を叩く
2. ない場合は `--csv <path>` を読む (Anthropic Console から手動 export
   した CSV)。Console export は `date,model,input_tokens,output_tokens,
   cache_creation,cache_read,usd` の 7 列を想定
3. 両方 unavailable なら **graceful fallback**: 空配列 `[]` を stdout、
   warning メッセージを stderr に出して exit 0 (= 本 collector は **欠落
   時に CI を fail させない**。レポート側で「Claude API: 観測 unavailable」
   として表示)

通常 API key (`ANTHROPIC_API_KEY`) ではなく **Admin API key** (`ANTHROPIC_ADMIN_API_KEY`)
が必須。Admin API key は Anthropic Console の Settings > Admin > API Keys から
発行する。通常 key で叩くと 401 が返り、本 script は manual CSV fallback に
切り替える。

Output schema (1 行 = 1 日 1 model の集計):

    [
      {
        "date": "2026-05-20",
        "model": "claude-opus-4-7",
        "input_tokens": 12345,
        "output_tokens": 6789,
        "cache_creation_tokens": 100,
        "cache_read_tokens": 200,
        "usd": 1.23
      },
      ...
    ]

USD は **Admin API が返してこない** (token 数のみ)。価格表 (`MODEL_PRICING`)
で input/output/cache を別単価で乗算して概算する。価格表が古いと推定誤差が
出るため、定期的な手動更新が必要 (TODO: pricing API が公開されたら自動化)。

Refs: ADR-0017
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

ADMIN_API_BASE = "https://api.anthropic.com"
USAGE_ENDPOINT = "/v1/organizations/usage_report/messages"
ANTHROPIC_VERSION = "2023-06-01"

# Per-1M-token pricing in USD. Conservative estimates; update when official
# pricing changes. Unknown models fall back to "default" (Opus rate, so we
# over-estimate rather than under-estimate cost).
MODEL_PRICING: dict[str, dict[str, float]] = {
    # claude-opus-4-7 (current latest Opus, 1M token tier price)
    "claude-opus-4-7": {
        "input": 15.0,
        "output": 75.0,
        "cache_creation": 18.75,
        "cache_read": 1.50,
    },
    "claude-opus-4-6": {
        "input": 15.0,
        "output": 75.0,
        "cache_creation": 18.75,
        "cache_read": 1.50,
    },
    "claude-sonnet-4-6": {
        "input": 3.0,
        "output": 15.0,
        "cache_creation": 3.75,
        "cache_read": 0.30,
    },
    "claude-haiku-4-5": {
        "input": 1.0,
        "output": 5.0,
        "cache_creation": 1.25,
        "cache_read": 0.10,
    },
    "default": {
        "input": 15.0,
        "output": 75.0,
        "cache_creation": 18.75,
        "cache_read": 1.50,
    },
}


def _estimate_usd(
    model: str,
    input_tokens: int,
    output_tokens: int,
    cache_creation: int,
    cache_read: int,
) -> float:
    """Estimate USD cost from token counts using MODEL_PRICING."""
    price = MODEL_PRICING.get(model, MODEL_PRICING["default"])
    cost = (
        input_tokens * price["input"]
        + output_tokens * price["output"]
        + cache_creation * price["cache_creation"]
        + cache_read * price["cache_read"]
    ) / 1_000_000.0
    return round(cost, 4)


def _fetch_admin_api(
    admin_key: str,
    days: int,
) -> list[dict] | None:
    """Hit Anthropic Admin API. Return None if API is unreachable / unauthorized."""
    end = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    start = end - timedelta(days=days)
    params = {
        "starting_at": start.isoformat().replace("+00:00", "Z"),
        "ending_at": end.isoformat().replace("+00:00", "Z"),
        "bucket_width": "1d",
        "limit": str(min(days, 31)),
        "group_by[]": "model",
    }
    qs = urllib.parse.urlencode(params, doseq=True)
    url = f"{ADMIN_API_BASE}{USAGE_ENDPOINT}?{qs}"
    req = urllib.request.Request(
        url,
        headers={
            "X-Api-Key": admin_key,
            "anthropic-version": ANTHROPIC_VERSION,
            "accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(
            f"[cost-collect-claude] WARN: Admin API HTTP {e.code} — "
            f"falling back to CSV mode if --csv given (key may be a regular "
            f"API key, not an Admin API key).",
            file=sys.stderr,
        )
        return None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        print(
            f"[cost-collect-claude] WARN: Admin API unreachable ({e}); falling back.",
            file=sys.stderr,
        )
        return None

    rows: list[dict] = []
    for bucket in payload.get("data", []) or []:
        starting_at = bucket.get("starting_at", "")
        date_str = starting_at.split("T")[0] if starting_at else ""
        for result in bucket.get("results", []) or []:
            model = result.get("model") or "unknown"
            inp = int(result.get("uncached_input_tokens") or 0)
            out = int(result.get("output_tokens") or 0)
            cache_creation_obj = result.get("cache_creation") or {}
            cache_creation = int(
                (cache_creation_obj.get("ephemeral_5m_input_tokens") or 0)
                + (cache_creation_obj.get("ephemeral_1h_input_tokens") or 0)
            )
            cache_read = int(result.get("cache_read_input_tokens") or 0)
            rows.append(
                {
                    "date": date_str,
                    "model": model,
                    "input_tokens": inp,
                    "output_tokens": out,
                    "cache_creation_tokens": cache_creation,
                    "cache_read_tokens": cache_read,
                    "usd": _estimate_usd(model, inp, out, cache_creation, cache_read),
                }
            )
    return rows


def _fetch_csv(csv_path: str) -> list[dict]:
    """Read Anthropic Console manual CSV export."""
    rows: list[dict] = []
    with open(csv_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            model = (row.get("model") or "unknown").strip()
            inp = int(row.get("input_tokens") or 0)
            out = int(row.get("output_tokens") or 0)
            cache_creation = int(row.get("cache_creation") or 0)
            cache_read = int(row.get("cache_read") or 0)
            usd_raw = row.get("usd") or ""
            try:
                usd = (
                    float(usd_raw)
                    if usd_raw
                    else _estimate_usd(model, inp, out, cache_creation, cache_read)
                )
            except ValueError:
                usd = _estimate_usd(model, inp, out, cache_creation, cache_read)
            rows.append(
                {
                    "date": (row.get("date") or "").strip(),
                    "model": model,
                    "input_tokens": inp,
                    "output_tokens": out,
                    "cache_creation_tokens": cache_creation,
                    "cache_read_tokens": cache_read,
                    "usd": round(usd, 4),
                }
            )
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Collect Claude API usage (ADR-0017).")
    parser.add_argument(
        "--days",
        type=int,
        default=7,
        help="Number of days to fetch (default: 7, max: 31 for daily bucket).",
    )
    parser.add_argument(
        "--csv",
        type=str,
        default=None,
        help="Path to manual CSV export from Anthropic Console (fallback "
        "when ANTHROPIC_ADMIN_API_KEY is unavailable).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Skip API and CSV; emit empty array + note to stderr (used for "
        "syntax / smoke testing).",
    )
    args = parser.parse_args(argv)

    if args.dry_run:
        print(
            "[cost-collect-claude] dry-run: emitting empty []",
            file=sys.stderr,
        )
        json.dump([], sys.stdout)
        return 0

    admin_key = os.environ.get("ANTHROPIC_ADMIN_API_KEY")
    rows: list[dict] | None = None

    if admin_key:
        rows = _fetch_admin_api(admin_key, args.days)

    if rows is None and args.csv:
        try:
            rows = _fetch_csv(args.csv)
        except FileNotFoundError:
            print(
                f"[cost-collect-claude] WARN: --csv path not found: {args.csv}",
                file=sys.stderr,
            )

    if rows is None:
        print(
            "[cost-collect-claude] WARN: no data source available "
            "(ANTHROPIC_ADMIN_API_KEY missing AND --csv not given or unreadable). "
            "Emitting empty array — report will mark Claude API as 'unavailable'.",
            file=sys.stderr,
        )
        rows = []

    json.dump(rows, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
