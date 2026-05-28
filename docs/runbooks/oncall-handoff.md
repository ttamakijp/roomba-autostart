# On-call handoff runbook（当直の引き継ぎ手順書）

> 最終更新: 2026-05-25

on-call rotation の "bridge" 手順。前任から後任に **5 分で全部を渡せる**
形式を提供する。

## Handoff の SLA

| 項目 | 期限 |
|---|---|
| Bridge meeting 開始 | rotation 切替の 15 分前 |
| Handoff note 提出 | rotation 切替の 30 分前 |
| 後任が受け取り確認を返す | rotation 切替時点 |
| 緊急で連絡が取れない場合 | 副 on-call へ自動 escalate (rotation 設定済) |

## Handoff note template

shift 終了時に以下を `<oncall-channel>` に投稿:

```markdown
## On-call handoff <YYYY-MM-DD> - 引き継ぎ from @<前任> to @<後任>

### この shift の作業
- ✅ 復旧済: <incident-id> P1 API 5xx - 復旧時刻 <HH:MM>
- 🟡 進行中: <incident-id> P2 latency 上昇 - mitigation 進行中、postmortem 未起票
- 📦 deploy 実施: vX.Y.Z (HH:MM) / hotfix vX.Y.Z-rollback-1 (HH:MM)

### 注意点 (後任が知るべきこと)
- <production-url> のレスポンスが朝方 +20% 遅い。CPU は余裕、原因調査中
- 依存 service <foo> が <YYYY-MM-DD HH:MM> から flaky、tolerance を一時的に
  100ms → 300ms へ広げてある (revert PR: #N)
- 設定変更: <feature-flag> を OFF にしてある。MERGE/ROLLBACK 判断は
  postmortem 後

### 未解決
- <incident-id> P2: 暫定対処のみ。root cause investigation pending
- <PR #N>: hotfix 承認待ち。CI green。`gh pr merge --auto` 設定済、
  branch protection 充足次第 auto-merge

### 引き継ぎ checklist (後任が確認)
- [ ] 上記未解決項目を理解した
- [ ] paging tool で自分が primary になっていることを確認
- [ ] dashboard / log access が機能している
- [ ] 緊急連絡先 (lead / CTO) の番号を知っている

### Special calendar items
- <YYYY-MM-DD HH:MM>: release tag v<next> 予定、freeze 状態
- <YYYY-MM-DD HH:MM>: customer X の重要 demo、影響面ブロック必須
```

`<oncall-channel>` で receive 確認を取る。返事がない場合は副 on-call
に escalate。

## Bridge meeting (15 分以内)

時間が許せば 15 分の同期 meeting。会えない場合 (時差 / 緊急) は handoff
note + 非同期で代替。

```
1. 前任が "この shift の作業" を読み上げ (3 分)
2. 前任が "注意点 + 未解決" を読み上げ (5 分)
3. 後任が質問 (5 分)
4. 後任の "受け取り確認" 発話 (1 分)
5. 残時間で paging tool / dashboard アクセス確認 (1 分)
```

## 重要な未解決 incident がある場合

P0/P1 が **mitigated だが not closed** の状態で shift が終わるなら:

- handoff note に "Active incident: <link>" を最上段に書く
- bridge meeting で必ず触れる (5 分以内では足りないので延長する)
- IC role が継続するなら同じ人が次 shift も担当 (rotation skip 可)、
  難しいなら後任に IC 引き継ぎを明示宣言

## 引き継ぎが失敗した場合

| 状況 | 対処 |
|---|---|
| 後任が応答しない | 副 on-call を ping、それでも応答なければ team lead に escalate |
| Note に矛盾発見 | bridge meeting で即解決、開始しない場合は前任に再連絡 |
| 「これ聞いてない」が後で発覚 | postmortem で "handoff gap" として記録、template を更新 |

## "個人時間" の保護

on-call rotation は仕事であり残業ではない。shift 中の incident 対応で
**法定残業を超えた場合**: 翌日代休 / 代替勤務時間 / 経営層への報告 を
team policy に従って行使する。on-call leadに confirm。

## maintenance

- handoff template の項目は team 文化を反映する。半年毎に retrospective
  で見直す
- "注意点" セクションが空のことが何 shift か続いたら、その項目を
  優先度下げる / 削除する判断
- 新規 on-call rotation 参加者の onboarding は別 doc (本 runbook の
  scope 外)

## Related

- [`incident-response.md`](incident-response.md) — incident 発生時の動き
- [`deploy.md`](deploy.md) — deploy / hotfix
- [`postmortem.md`](postmortem.md) — 振り返り
