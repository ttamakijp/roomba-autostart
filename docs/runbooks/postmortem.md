# Postmortem runbook（事後検証の手順書）

> 最終更新: 2026-05-25

incident 後の振り返り。**blameless** が大原則: 人ではなく仕組みを問う。

## 起票の SLA

| Severity | Draft 起票 | Final 起票 | review meeting |
|---|---|---|---|
| **P0** | 24 時間以内 | 1 週間以内 | meeting 必須 |
| **P1** | 48 時間以内 | 2 週間以内 | meeting 推奨 |
| **P2** | 1 週間以内 (recommended) | — | 任意 |

## 配置

`docs/incidents/<YYYY-MM-DD>-<short-name>.md` に作成。
本 repo のサンプル: [`docs/incidents/2026-05-23-backup-tag-leak.md`](../incidents/2026-05-23-backup-tag-leak.md)

## Template

```markdown
# <YYYY-MM-DD> — <short title>

## Summary
1-3 行で「何が起きたか / 影響 / 解決状況」。**最初に読んだ人が 30 秒で
全体像を掴めること** が SLO。

## Timeline (UTC + 現地時刻併記)
| Time | Event | Source |
|---|---|---|
| 10:32 UTC / 19:32 JST | 監視 alert 発火 (`error_rate > 5%`) | Datadog |
| 10:35 UTC | @alice が pickup、incident channel 作成 | Slack |
| 10:38 UTC | rollback v3.5.2 開始 | gh workflow run |
| 10:42 UTC | rollback 完了、error rate 復帰 | Datadog |
| 11:00 UTC | IC が公式 recovery 宣言 | Incident channel |

## Impact
- 利用者影響: <unique-user-count> ユーザが /api/v1/order で 500 を受信
- 経済影響: 推定 -<金額> JPY (失敗 transaction の uplift)
- 関連 SLA breach: 月次 99.9% 目標に対して -0.02% 消費

## 5 whys (root cause へ追跡)

1. **なぜ error rate が急増したか?**
   → /api/v1/order が SQL constraint violation を 500 として返した
2. **なぜ SQL constraint violation が起きたか?**
   → migration V42 で UNIQUE 制約を追加したが既存データに重複があった
3. **なぜ migration の事前検証で気付かなかったか?**
   → staging に production と同等のデータ量がなかった
4. **なぜ staging と production のデータ差を許容していたか?**
   → 個人情報を staging に置く方針がなく、shape-fidelity が低かった
5. **なぜ shape-fidelity の低さを認識しつつ放置していたか?**
   → "緊急 migration で対応" 想定だったが、その緊急 process が
   ADR-0015 incident-response.md の SLA を満たせない構造だった

## Root cause

(5 whys の最深点を 1-2 文で)
"staging 環境が production の shape (cardinality / 重複度) を再現せず、
migration の事前検証が機能しない構造的問題"

## What went well

- rollback が 7 分で完了 (rollback.md 案 B 採用)
- on-call paging が 3 分で primary を捕捉
- incident channel の topic 更新が 30 分以内に維持された

## What went wrong

- migration の事前検証が不十分だった (staging shape mismatch)
- error monitoring の alert threshold が遅延気味だった
  (発火から認知まで 3 分)
- customer communication が status page 更新まで 45 分かかった

## Action items

各項目は **誰が / いつまでに / どう検証するか** を明示。

| ID | Action | Owner | Due | Verify by |
|---|---|---|---|---|
| AI-1 | staging shape-fidelity を測定する script を作成、CI に組込 | @bob | 2026-06-15 | weekly report で fidelity > 95% |
| AI-2 | migration PR template に "staging で N=production の 10% で実行" checkbox 追加 | @alice | 2026-06-01 | template review |
| AI-3 | error rate alert を error_rate > 2% に厳格化 (threshold 一致確認) | @carol | 2026-06-08 | next-incident で 60s 以内認知 |

## Blameless 原則 (必読)

- 主語は **system / process** であって個人ではない。
  ❌ "Alice が migration を雑に書いた"
  ✅ "migration review step に staging-shape check が含まれていなかった"
- 個人の責任追及はこの doc の外で (1-on-1 等)、本 doc は再発防止の
  仕組みだけ書く
- ある人を call out する必要が出たら "@<handle> が <時刻> に <動作>"
  という事実だけ書く。感情を含めない

## Related

- Incident channel: <link>
- Hotfix PR: <link>
- Rollback tag: <tag>
- 影響を受けた ADR / runbook: <list>
```

## 振り返り meeting (P0/P1 必須)

postmortem final 起票から 1 週間以内。

- 参加: IC, Mitigator, Investigator, Communicator, team lead
- 時間: 60 分
- 進行:
  1. (10 分) Summary / Timeline 読み合わせ
  2. (15 分) 5 whys を全員でレビュー (最深点の妥当性)
  3. (20 分) Action items の owner / due を確定、優先順位 (P0/P1/P2)
  4. (10 分) 学び / 文化的気付き (process 改善案)
  5. (5 分) Action items を tracking 体制に登録 (Jira / Linear / GitHub
     Issues)

## maintenance

- Action items の追跡は postmortem の owner が四半期毎に進捗報告
- 期限超過 action は IC が再 escalate
- 半年毎に過去 postmortem を読み返し、繰り返しテーマがあれば structural
  improvement の ADR を起票

## Related

- [`incident-response.md`](incident-response.md) — incident 発生時
- [`oncall-handoff.md`](oncall-handoff.md) — rotation 引き継ぎ
- 本 repo のサンプル incident: [`docs/incidents/2026-05-23-backup-tag-leak.md`](../incidents/2026-05-23-backup-tag-leak.md)
