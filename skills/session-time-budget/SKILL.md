---
name: session-time-budget
description: |
  Manage session end-time as a hard budget and run the ADR-0014 end-of-day cleanup checklist. Invoke this skill at the start of any multi-step task: it asks the user for the planned end-time (HH:MM / Nm / unknown), records it in `~/.cowork/session-time-budget-state.json`, sends 30 / 15 / 5-minute proactive alerts as the deadline approaches, and finally executes the 6-step cleanup (MEMORY save, WIP commit, branch push, handoff note in `docs/sessions/YYYY-MM-DD.md`, child-session check, parent report). Companion to `scheduled-tasks/session-cleanup-watch/SKILL.md` (external 15-min polling that catches the case where this skill itself stops running). Triggers naturally on phrases like "今日の終了は", "end of day cleanup", "session を畳む", "/skill session-time-budget", or any multi-step task kickoff that this user's USER_PREFERENCES asks for. See ADR-0014.
audience: [claude]
license: Internal use
---

# session-time-budget

## Overview

Phase 4 (Operations) の session 側 hygiene skill。multi-step task が
時刻を意識せず暴走するのを防ぎ、終了時の context loss を消す。

**Keywords**: session, end-of-day, cleanup, time budget, hygiene,
handoff, operations, ADR-0014

## Trigger

Invoke when ANY of:

- USER_PREFERENCES に従い multi-step task を開始するとき (暗黙起動)
- User が `/skill session-time-budget` と明示
- User が "今日は X 時まで" / "あと N 分で終わる" 等の発話をしたとき
- 別 skill (apply-dev-templates 等) が長時間 task を始めるとき

## 5 Phase 進行

### Phase 1: ヒアリング

```
AskUserQuestion:
  question: "今日のセッション終了予定時刻は？"
  options:
    - label: "18:00 (HH:MM 形式)"
      description: "絶対時刻を分単位で指定"
    - label: "60m (N 分後)"
      description: "現在からの相対分数を指定"
    - label: "unknown"
      description: "決まっていない (cleanup タイマーを起動しない)"
  multiSelect: false
```

Parse rules:

- `HH:MM` (例 `18:00`) → 今日の該当時刻。既に過ぎていれば翌日と解釈
- `Nm` (例 `60m` / `90m`) → 現在 + N 分
- `unknown` → skill を suspend (state には `end_time: null` を記録)
- それ以外 → 再質問

### Phase 2: 予算登録

```bash
bash scripts/session-state.sh set "$SESSION_ID" "<ISO8601 end_time>"
```

`SESSION_ID` は Cowork が払い出す local id。state は
`~/.cowork/session-time-budget-state.json` に書込。

### Phase 3: Milestone Alert (30 / 15 / 5 分前)

Skill 自身は session 内で稼働中なので、定期的に現在時刻を確認:

- 主モデルが次の tool 呼び出しに入る前にチェック
- 残時間 30 分 / 15 分 / 5 分 を初めて切ったタイミングで
  `SendUserMessage(status=proactive)`:

```
⏰ 終了 15 分前です。
- 進行中タスク: <list>
- cleanup 残: <list>
あと 15 分で cleanup checklist に移行します。
```

各 alert 送信後は state に記録 (`alerts_sent: ["30m", "15m"]`) して
重複送信を防ぐ。

`session-cleanup-watch` (L3) が外部から alert を送ってきた場合は、
内部 alert と重複しないよう state を読んで判定。

### Phase 4: Cleanup Checklist 実行 (時刻 5 分前 or 超過)

6 項目を **順番に** 実行。skip された項目は handoff note に
`skipped: <reason>` を記録。

1. **MEMORY 保存**
   ```bash
   # 残タスクを MEMORY.md の "Open tasks" セクションに追記
   # (TaskList でまだ pending / in_progress なものを対象)
   ```

2. **WIP commit**
   ```bash
   git add -A
   git commit -m "wip(session): end-of-day snapshot <YYYY-MM-DD HH:MM>

   進行中: <短い要約>
   未完了 todo:
   - ...
   Refs: ADR-0014"
   ```
   push は user 判断 (Phase 5 で確認)。

3. **ブランチ push / PR 化**
   - merge 可能な状態 (CI green / レビュー済) なら:
     ```bash
     gh pr merge <#> --squash --delete-branch \
       --subject "<conventional commit title>" --body "..."
     ```
     `(#N)` 抑止を維持。
   - merge 不可なら draft PR を作成:
     ```bash
     gh pr create --draft --title "..." --body "..."
     ```

4. **handoff note 生成**
   - `docs/sessions/<YYYY-MM-DD>.md` を `docs/sessions/.template.md`
     から生成
   - 必須 5 セクション: 成果サマリ / 未解決 / 次回着手案 / 関連 PR /
     環境状態
   - 主モデルが session の transcript を要約して埋める

5. **稼働中の子 session 確認**
   ```
   # Cowork の list_sessions / read_transcript で稼働中タスクを列挙
   # 各 child の現在 status と未完了 summary を MEMORY.md に記録
   # 完了済 child は handoff note の "成果サマリ" に取り込む
   ```

6. **親エージェントへの最終報告**
   - 成果サマリ (完了 PR / 達成項目)
   - 未解決事項
   - 次回着手案 (具体的なファイル名 + 1 行 next-action)

### Phase 5: 終了確認

```bash
bash scripts/session-state.sh complete "$SESSION_ID"
```

`cleanup_completed: true` を state に書込。skill 自身も終了。

## エラー処理

| 状況 | 挙動 |
|---|---|
| Phase 1 で `unknown` 回答 | state に `end_time: null` を記録、Phase 2-5 skip、user 駆動 only |
| 時刻 parse 失敗 | Phase 1 を再実行 (再質問) |
| 現在 > end_time (既に過ぎている) | Phase 4 へ即時遷移 |
| 30 分以下の短時間 task | 30m / 15m alert は skip、5m のみ送る (alert 過多回避) |
| state file が壊れている | バックアップ (`*.bak`) を作成して再初期化、user に警告 |
| `~/.cowork/` が存在しない | mkdir -p で作成 (Cowork なし環境でも動作) |

## state schema

`~/.cowork/session-time-budget-state.json`:

```json
{
  "sessions": {
    "<session_id>": {
      "end_time": "2026-05-25T18:00:00+09:00",
      "alerts_sent": ["30m", "15m"],
      "started_at": "2026-05-25T09:00:00+09:00",
      "cleanup_completed": false
    }
  }
}
```

並列 session に対応: 同じ JSON 内に複数 `<session_id>` キーを保持。
書込みは `scripts/session-state.sh` が atomic write (tempfile + mv) で
行うので並列 session の同時書込でも壊れない。

## 関連

- ADR-0014: session time budget の設計判断
- ADR-0009 Phase 4 (Operations 軸)
- `scheduled-tasks/session-cleanup-watch/SKILL.md` (L3 外部監視)
- `scripts/session-state.sh` (state 操作 CLI)
- `docs/sessions/.template.md` (handoff note 雛形)
- USER_PREFERENCES.md "セッション時間予算" (L1 宣言)

## Examples

### Example 1: 18:00 終了で 09:00 開始

```
[09:00] User: dev-templates の Phase 4 を実装してほしい
[09:00] Claude (skill invoke):
  AskUserQuestion: "今日のセッション終了予定時刻は？"
  → User: "18:00"
  state に 2026-05-25T18:00 を登録
[09:01-17:29] task 進行
[17:30] proactive alert: "⏰ 終了 30 分前"
[17:45] proactive alert: "⏰ 終了 15 分前"
[17:55] proactive alert + Phase 4 起動
[18:00] cleanup 6 項目完了、handoff note 出力、最終報告
```

### Example 2: unknown 回答

```
[09:00] User: 何か作業手伝って
[09:00] Claude: AskUserQuestion → "unknown"
  state に end_time: null を記録、skill suspend
  (user が "終わる" と言うまで cleanup タイマー無し)
```

### Example 3: 30 分以下の短時間 task

```
[17:30] User: 急ぎで bug fix 一つ、18:00 までに
[17:30] Claude: 30 分以下 → 30m / 15m alert skip
[17:55] proactive alert: "⏰ 終了 5 分前"
[18:00] Phase 4 cleanup
```
