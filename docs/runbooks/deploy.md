# Deploy runbook（公開の手順書）

> 最終更新: 2026-05-25

通常 deploy と緊急 hotfix の手順。**前提**: `main` ブランチが常に
deployable な状態。CI が green。Phase 1+2 防御 + 品質ゲートが通っている。

## 通常 deploy (タグベース)

### Prerequisites

- すべての対象 PR が `main` にマージ済 (CI green)
- 最新 tag を確認: `git tag --sort=-version:refname | head -5`
- Phase 2 quality gates が main 上で最新 commit に対して pass

### Steps

```bash
# 1. main を最新化
git checkout main
git pull --ff-only origin main

# 2. CHANGELOG.md を更新 (Unreleased → vX.Y.Z 見出しに変更)
$EDITOR CHANGELOG.md
git add CHANGELOG.md
git commit -m "chore(release): vX.Y.Z

Refs: vX.Y.Z"

# 3. 注釈付き tag を作成
git tag -a vX.Y.Z -m "Release vX.Y.Z

Highlights:
- ...
"

# 4. push tag (これが trigger になる worflow があれば自動 deploy)
git push origin main
git push origin vX.Y.Z

# 5. deploy workflow を起動 (CI 経由の場合)
gh workflow run deploy.yml -f tag=vX.Y.Z

# 6. deploy 進行を観察
gh run watch
```

### Verification

```bash
# health check (project-specific)
curl -fsSL https://<production-url>/healthz

# version 確認
curl -fsSL https://<production-url>/version | grep "vX.Y.Z"

# error rate 急増がないこと (Grafana / Datadog 等)
# 失敗時: rollback.md を参照
```

## 緊急 hotfix (P0 / P1 incident 中)

### Prerequisites

- incident-response.md の初動が完了 (severity 判定済、on-call 全員に
  ping 済)
- 修正内容が **最小** (1 ファイル / 数十行) であること。それ以上は
  rollback.md を先に検討

### Steps

```bash
# 1. main から hotfix ブランチを切る
git checkout main
git pull --ff-only origin main
git checkout -b hotfix/<short-description>

# 2. 修正をコミット (テストも同 PR 内で追加)
$EDITOR <files>
git add <files>
git commit -m "fix(<scope>): <description>

Incident: <link to incident ticket>
Refs: <related ADR or PR if any>"

# 3. push して PR 作成 (CI を可能な限り全部待つ)
git push -u origin hotfix/<short-description>
gh pr create --title "fix(<scope>): <description>" \
  --body "Hotfix for <incident-id>. See incident-response.md."

# 4. CI green 確認後、--auto 待ちで merge
gh pr merge --squash --delete-branch --auto \
  --subject "fix(<scope>): <description>"

# 5. tag + deploy (通常 deploy と同様だが PATCH bump)
# 例: 直前 tag が v3.5.2 だった場合 → v3.5.3
git checkout main && git pull
git tag -a v3.5.3 -m "Hotfix release v3.5.3 — <description>"
git push origin v3.5.3
gh workflow run deploy.yml -f tag=v3.5.3

# 6. 検証 (上記 Verification と同じ手順)
```

### Failure recovery

- CI が緊急に通らない場合: **branch protection を一時 admin override
  しない**。代わりに rollback.md の手順で前 tag に戻す
- deploy 完了したが症状継続: rollback.md の "Deployed but still
  broken" セクションへ
- hotfix が更に副作用を起こした場合: incident severity を 1 段上げて
  on-call 全員に再通知

## Post-deploy

- CHANGELOG.md の released エントリに deploy 完了時刻を 1 行追記
  (`Deployed: 2026-05-25T18:00 JST`)
- on-call shift 中なら oncall-handoff.md の "今 shift の作業" に記録
- 何か学びがあれば postmortem.md (P0/P1 は必須、P2 は推奨)
