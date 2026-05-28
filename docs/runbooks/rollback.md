# Rollback runbook（差し戻しの手順書）

> 最終更新: 2026-05-25

deploy 直後に問題が起きた場合の "巻き戻し" 手順。**判断軸**:
forward-fix (前進修正) と backward-rollback (戻し) のどちらが速いか。
迷ったら **rollback**。

## 判断フロー

```
deploy 後に問題発生
        │
        ▼
影響範囲は?
        │
   ┌────┴────┐
   ▼         ▼
広い      局所的
(P0/P1)   (P2)
   │         │
   ▼         ▼
即 rollback  forward-fix 可能か?
              │
        ┌─────┴─────┐
        ▼           ▼
       Yes (15m以内)  No
        │           │
        ▼           ▼
     hotfix      rollback
```

時間 SLA: P0/P1 で **15 分以内に rollback or 修正完了の見通しが立たない
なら必ず rollback**。

## 案 A: git revert + 再 deploy (DB migration なし、コード変更のみ)

### Prerequisites

- 戻したい commit / merge commit の SHA を特定
- migration / schema 変更を含まないこと (含む場合は案 C へ)

### Steps

```bash
# 1. main を最新化
git checkout main
git pull --ff-only origin main

# 2. 問題の merge commit を revert (squash merge なら通常 commit)
git log --oneline -10   # ← 戻したい SHA を確認
git revert <bad-sha>

# 3. revert commit を push して通常 deploy
git push origin main
# CI green を待つ
gh run watch

# 4. revert tag を打つ (vX.Y.Z+1 ではなく vX.Y.Z-rollback-<n>)
git tag -a v<old>.<new>-rollback-1 -m "Rollback of <bad-sha> due to <reason>"
git push origin v<old>.<new>-rollback-1

# 5. deploy workflow を再実行
gh workflow run deploy.yml -f tag=v<old>.<new>-rollback-1
```

### Verification

deploy.md の Verification と同じ。加えて:

```bash
# 戻した変更が消えていること
git show HEAD --stat
```

## 案 B: tag rollback (もっと速い、image immutable な場合)

### Prerequisites

- 前 release tag に対応する artifact (Docker image / binary) がまだ
  存在 (registry retention period 内)

### Steps

```bash
# 1. 1 つ前の安定 tag を確認
git tag --sort=-version:refname | head -5

# 2. その tag を deploy workflow に渡して再 deploy
gh workflow run deploy.yml -f tag=v<previous-stable>

# 3. (任意) main を revert する commit はその後、案 A の手順で別途
git revert <bad-sha>
git push origin main
```

### Verification

```bash
curl -fsSL https://<production-url>/version | grep "v<previous-stable>"
```

戻したことで CHANGELOG.md の Released 状態が嘘になるので、
post-rollback で必ず追記:

```markdown
## [v<bad>.<n>] - <date> - **ROLLED BACK** on <date>
理由: <link to incident>
代替: v<previous-stable>
```

## 案 C: DB migration を含む場合

最も慎重。`git revert` はコードだけ戻し、schema は戻らない。

### 選択肢

1. **Forward-fix を強く推奨**: 不正な schema 変更を直す migration を
   追加で当てる。テーブル削除なら復元 migration、列追加なら NULL 許容
   への切替、等
2. **Backup からの restore**: P0 で他の手段がなく、データ毀損が広範な
   場合のみ。RTO / RPO を on-call leadに confirm
3. **Application 側で schema mismatch を吸収**: 旧 schema と新 schema
   両対応のコードに hotfix する

### Steps (forward-fix の場合)

```bash
git checkout main
git pull --ff-only origin main
git checkout -b fix/migration-<short>

# 補修 migration を書く
$EDITOR migrations/V<n+1>__<description>.sql

# テストを追加
$EDITOR tests/test_migration_<n+1>.py

git add migrations/ tests/
git commit -m "fix(db): repair migration V<n>

Incident: <link>
Refs: ..."
git push -u origin fix/migration-<short>
gh pr create --title "fix(db): repair migration V<n>" --body "..."
```

deploy.md の Hotfix セクションに従って merge + deploy。

### Verification

- 補修 migration が production で適用された
- 該当 endpoint / 機能が正常応答
- DB 整合性 (foreign key / unique 制約) に violation がないこと

## "Deployed but still broken" (rollback も hotfix も効かない場合)

incident-response.md の P0 escalation flow へ即時遷移。次の選択肢:

- 該当機能 / endpoint を traffic から外す (feature flag / load balancer
  weight 0 / DNS 切替)
- maintenance page に切替
- 上位 escalation (CTO / 経営層への 30 分以内通知)

## Post-rollback

- postmortem.md を必ず起票 (P0/P1 は 24h 以内)
- rollback した tag / commit / 理由を CHANGELOG.md に追記
- 再 deploy 時の予防策を ADR or runbook update に落とす
