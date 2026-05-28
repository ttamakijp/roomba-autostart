# Incident response runbook（障害対応の手順書）

> 最終更新: 2026-05-25

incident 検知から escalation・初動・記録までの 10 分 / 1 時間 / 24 時間
タイムフレーム別 checklist。

## Severity 判定 (まず最初に)

| Sev | 影響 | 初動 SLA |
|---|---|---|
| **P0** | サービス全断 / データ毀損 / セキュリティ侵害 | 5 分以内 ping、15 分以内対応開始 |
| **P1** | 主要機能不能 / 一部ユーザに重大影響 | 15 分以内 ping、1 時間以内対応開始 |
| **P2** | 軽微な機能不全 / 復旧計画あり | 業務時間内 |
| **P3** | 改善提案 / 非緊急 | バックログ |

**迷ったら 1 段上**: P1/P2 で迷ったら P1 として扱う。後で de-escalate
する方が remediation 遅れより遥かに安い。

## 10 分以内 checklist (最重要)

```bash
# 1. incident channel を作成 / 既存 channel を使用
#    naming convention: #incident-YYYYMMDD-<short>
#    例: #incident-20260525-api-5xx

# 2. on-call 全員に paging (P0/P1)
#    <paging-tool> で alert を確認、自分が pickup したことを宣言

# 3. severity を宣言 (incident channel の topic に固定)
#    "Sev: P0 — API 全断 - on-call: @alice"

# 4. 直近 deploy を確認 (rollback 候補の特定)
gh run list --workflow=deploy.yml --limit 5
git log --oneline -10

# 5. 何を観測しているかを 1 行で書く (5 whys の基点)
#    "10:32 JST から /api/v1/order が 500 を返している"
```

## 1 時間以内 checklist

### 並行作業 (役割分担)

| 役割 | 担当 |
|---|---|
| **Incident commander (IC)** | 全体調整、escalation 判断、外部通知 |
| **Investigator** | 原因調査 (log / metrics / 直近変更) |
| **Mitigator** | 対処実行 (rollback / hotfix / traffic 操作) |
| **Communicator** | status page / 顧客通知 / 経営層通知 |

人数が足りない場合は IC が複数役を兼ねる。優先順位: IC → Mitigator →
Communicator → Investigator。

### 並行で実行

```bash
# 観測
# - error rate / latency / availability の Grafana / Datadog dashboard
# - application log の最近 30 分: sev=ERROR を中心に
# - infrastructure log (k8s events, autoscaler, network)

# 仮説検証
# - 直前の deploy が原因か? → rollback.md 案 B で即戻し
# - 依存先 service の障害か? → 該当 service の status page
# - traffic spike か? → autoscaler 状況、rate limit 上げ

# 対処オプション (severity に応じて選ぶ)
# - P0: 即 rollback (rollback.md 案 B)、必要なら feature flag off
# - P1: forward-fix の見通しが 15 分以内に立てば hotfix、否なら rollback
# - P2: 業務時間内に通常 PR + deploy
```

## 24 時間以内 checklist

- [ ] 復旧確認 (verification 手順) を実施し、IC が channel で公式宣言
- [ ] customer communication (status page 更新、必要なら個別連絡)
- [ ] postmortem.md draft を 24h 以内に着手 (blameless)
- [ ] on-call rotation の次担当に oncall-handoff.md で引き継ぎ
- [ ] 対処に使った hotfix / rollback の Refs を incident ticket に集約

## Escalation flow

```
発見者 (on-call / customer-report / monitoring)
        │
        ▼
P0/P1 判定 → on-call rotation を全員 page
        │
        ▼
IC が 30 分以内に状況把握できない
or 30 分後も復旧見込み立たず
        │
        ▼
team lead / engineering manager に escalate
        │
        ▼
2 時間後も継続 or データ毀損確定
        │
        ▼
CTO / 経営層に通知
        │
        ▼
4 時間後も継続 or 公開影響
        │
        ▼
広報 / PR 関与 (公式声明)
```

各段階の判断は IC の独断で OK (相談している暇はない)。後で
postmortem で振り返る。

## 報告 template (incident channel の topic 用)

```
[Sev P0] API 5xx 急増 - <YYYY-MM-DD HH:MM> から継続中
IC: @<handle>
Mitigator: @<handle>
Investigator: @<handle>
Communicator: @<handle>
Status: investigating | mitigating | recovered | postmortem-pending
直近 update: <時刻> - <現状 1 行>
related: <hotfix PR / rollback tag / incident ticket>
```

incident channel の topic を 30 分毎に最新化する責任は IC。

## Failure recovery (incident response 自体が失敗した場合)

- on-call が誰も応答しない → 全社 channel に escalate、関係者を
  手動で page
- communication tool が落ちている → 電話 / SMS / 物理集合に切替
- IC が稼働不能 → 副 IC が即引き継ぎ。事前に rotation で副 IC を
  決めておく

## Related

- [`deploy.md`](deploy.md) — hotfix deploy 手順
- [`rollback.md`](rollback.md) — rollback 判断と手順
- [`postmortem.md`](postmortem.md) — incident 後の振り返り
- [`oncall-handoff.md`](oncall-handoff.md) — on-call rotation
- ADR-0015: 本 runbook 体系の設計
