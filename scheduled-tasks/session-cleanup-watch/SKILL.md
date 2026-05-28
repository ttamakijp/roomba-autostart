---
name: session-cleanup-watch
description: |
  Poll active Claude sessions every 15 minutes from Cowork, check their declared end-time in `~/.cowork/session-time-budget-state.json`, and send proactive alerts to sessions that are 30 / 15 / 5 minutes away from their deadline. External safety net that runs independently of the in-session `session-time-budget` skill — catches the case where the in-session skill itself stops responding. See ADR-0014.
schedule:
  cronExpression: "*/15 * * * *"
  notifyOnCompletion: false
version: 1.0.0
audience: [claude]
license: Internal use
---

> Dispatch の scheduled-tasks MCP に登録する際は、上記
> `schedule.cronExpression` をそのまま `cronExpression` パラメータに
> 渡す。導入手順は同ディレクトリ [`README.md`](../README.md) を参照。

# session-cleanup-watch

## Overview

ADR-0014 L3 層: dev-templates Phase 4 (Operations 軸) の session
hygiene を **session の外側から** 監視する scheduled-task。

L2 (`skills/session-time-budget/SKILL.md`) は session 内部で動作するため、
主モデルが暴走 / hang / context 喪失で skill が機能停止すると alert が
止まる。L3 がこれを補う:

- 15 分毎 polling
- `~/.cowork/session-time-budget-state.json` から end_time を読む
- 残時間 30 / 15 / 5 分以内の session に proactive alert を送る
- 既に L2 / L3 が同じ milestone を送ったかは state の `alerts_sent`
  を見て重複回避

## Keywords

session, watch, polling, end-of-day, hygiene, cleanup, operations,
ADR-0014, Phase 4

## 実行手順

### Step 1: state 読み込み

```bash
STATE_FILE="$HOME/.cowork/session-time-budget-state.json"
if [ ! -f "$STATE_FILE" ]; then
  # state 未初期化 = 監視対象なし、idle (no notification)
  exit 0
fi
```

### Step 2: アクティブ session 一覧取得

`mcp__session_info__list_sessions` を 1 回呼び出し、`is_child: false`
かつ `state in [running, awaiting_approval]` の session を抽出。

### Step 3: 各 session の deadline 確認

各 active session について:

```bash
# state.json から end_time を取得 (jq 等で)
end_time=$(bash scripts/session-state.sh get "$session_id" 2>/dev/null)
if [ -z "$end_time" ] || [ "$end_time" = "null" ]; then
  # この session は end_time 未宣言 (unknown) → skip
  continue
fi
```

現在時刻と比較し、残時間を計算:

| 残時間 | milestone | alert 送信 |
|---|---|---|
| > 35 分 | none | 沈黙 |
| 25-35 分 | `30m` | alerts_sent に "30m" が無ければ送る |
| 10-20 分 | `15m` | alerts_sent に "15m" が無ければ送る |
| 0-7 分 | `5m` | alerts_sent に "5m" が無ければ送る |
| < 0 (超過) | `overdue` | alerts_sent に "overdue" が無ければ送る |

### Step 4: alert 送信

該当 session に対して `mcp__cowork__send_message`:

```
⏰ session 終了 <N> 分前です (external watch from session-cleanup-watch)。
- 宣言済 end_time: <ISO8601>
- 推奨アクション: skill `session-time-budget` の Phase 4 cleanup checklist を実行
- 進行中タスクは中断して cleanup 優先

詳細: ADR-0014 / skills/session-time-budget/SKILL.md
```

`overdue` の場合は文言を変える:

```
⏰⏰ session 終了予定時刻を超過しています。直ちに cleanup checklist を
完了し、handoff note を出力してください。
```

### Step 5: state 更新

```bash
bash scripts/session-state.sh alert "$session_id" "<30m|15m|5m|overdue>"
```

`alerts_sent` 配列に追加。同 session 内の L2 skill とこのタスクが
重複送信しないための共有 state。

### Step 6: cleanup 完了 session の掃除

`cleanup_completed: true` かつ `started_at + 24h` を超えた session
entry は state から削除 (state file 肥大化防止):

```bash
bash scripts/session-state.sh purge --older-than 24h
```

### Step 7: 通知ポリシー

| 状況 | 通知 |
|---|---|
| 監視対象 0 session | 沈黙 (notifyOnCompletion: false) |
| alert 送信 1 件以上 | 親に "<N> session に milestone alert 送信" を 1 行通知 |
| state file 破損 | 親に "state file 破損、バックアップ作成・再初期化" を通知 |

## 関連

- ADR-0014: 3 層実装の設計判断 (本タスクは L3)
- `skills/session-time-budget/SKILL.md`: L2 内部実装 (内外二重化)
- `scripts/session-state.sh`: state 操作 CLI (本タスクと L2 の共有)
- USER_PREFERENCES.md "セッション時間予算": L1 宣言

## Failure modes

- **Cowork API 不在 (stand-alone Claude Code)**: list_sessions が
  使えない場合、本タスクは no-op で抜ける。L1 + L2 のみで運用
- **`~/.cowork/` 不在**: state file が無いので Step 1 で exit 0
- **時計同期**: 各 session の local 時計を信頼。NTP 整合は OS レイヤ
  に委譲

## 設定例 (Dispatch / Cowork 登録時)

```yaml
cronExpression: "*/15 * * * *"   # 15 分毎
notifyOnCompletion: false        # idle 時は沈黙
maxRetries: 2                     # state file lock 競合への耐性
```
