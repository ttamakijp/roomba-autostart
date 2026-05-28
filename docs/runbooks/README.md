# Operational runbooks (ADR-0015)

Copy-paste-ready playbooks for the operations not covered by code or
CI. Each file is laid out as: **prereq → step-by-step commands →
verification → failure recovery**. Project-specific values are written
as `<placeholder>` so you can `sed -i 's/<placeholder>/...//g'` after
copying, or just read & retype.

## Which runbook do I use?

| Situation | Open |
|---|---|
| Cutting a normal release / production deploy | [`deploy.md`](deploy.md) |
| Emergency hotfix to production | [`deploy.md`](deploy.md) (Hotfix section) |
| Undoing a bad deploy | [`rollback.md`](rollback.md) |
| Something is on fire (P0/P1/P2) | [`incident-response.md`](incident-response.md) |
| Starting / ending an on-call shift | [`oncall-handoff.md`](oncall-handoff.md) |
| Writing up what just happened | [`postmortem.md`](postmortem.md) |
| ADO adopter (NDA で audit 自動化不可) で PII を除去したい | [`ado-adopter-pii-scrub.md`](ado-adopter-pii-scrub.md) |
| Windows native アプリが起動直後 / 特定操作で落ちる | [`windows-crash-diagnosis.md`](windows-crash-diagnosis.md) |
| C# / `dotnet build` でソース変更が反映されない / 古いバイナリが出る | [`dotnet-build-cache-troubleshooting.md`](dotnet-build-cache-troubleshooting.md) |

## How to customize for your project

1. Copy the entire `docs/runbooks/` directory into your repo (or apply
   via `bash ~/.dev-templates/scripts/apply-to-project.sh
   --profile operations-only /path/to/your-project`).
2. Replace `<placeholder>` tokens with project-specific values.
   Common ones:
   - `<repo>` — `owner/repo` (e.g. `ttamakijp/dev-templates`)
   - `<production-url>` — your service's URL or hostname
   - `<deploy-cmd>` — your deploy command (`kubectl apply`, `gh
     workflow run deploy.yml`, …)
   - `<oncall-channel>` — Slack / Teams channel name
   - `<paging-tool>` — PagerDuty / OpsGenie / Opsgenie / SimplePush
3. Update the 「最終更新」 line at the top of each file. Treat older
   than 6 months as suspect and re-validate the commands.

## Severity reference (consistent across runbooks)

| Sev | 影響 | 初動時間 SLA |
|---|---|---|
| **P0** | サービス全断 / データ毀損 / セキュリティ侵害 | 5 分以内に on-call 連絡、15 分以内に対応開始 |
| **P1** | 主要機能不能 / 一部ユーザに重大影響 | 15 分以内に on-call 連絡、1 時間以内に対応開始 |
| **P2** | 軽微な機能不全 / 復旧計画あり | 業務時間内に対応 |
| **P3** | 改善提案 / 非緊急 | バックログ管理 |

## maintenance policy

- 6 ヶ月毎に各 runbook の command を実機で検証 (CI で自動 verification
  は Phase 4 続々編で検討)
- runbook を変更する PR は `docs/runbooks/` を touch するだけで
  `quality-gates.yml` の通常 review が走る (lint / link check 等)
- 真に obsolete な手順は削除せず `[archived]` セクションに残す
  (後追い trace 用途)

## Related

- ADR-0015: runbook 体系 + interactive onboarding + friendly errors
- ADR-0009 Phase 4: operations 軸全体のロードマップ
- [`docs/error-codes.md`](../error-codes.md): friendly_error コードの集約
