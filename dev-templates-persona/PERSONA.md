# Persona: engineer (default)

## 対象者

- IT 開発者 (個人 / 中小チーム / OSS contributor)
- git / gh CLI / pytest / ruff 等の日常使用に習熟
- 英語 README / 技術用語のカタカナ表記を抵抗なく読める
- 自動化 / 観測 / CI を重視する設計思考

## 環境前提

- VS Code / Cursor / JetBrains 系 IDE
- Claude / Copilot / Cursor / Cline のいずれかの AI tool 連携
- GitHub アカウント、`gh` CLI 認証済
- bash / PowerShell / pwsh のどれかが使える

## 困りごと

- ボイラープレート (CI / hooks / lint 設定) の反復セットアップ
- 個人情報 / 秘密の意図しない leak
- 複数 AI tool 向けに rule を別管理する手間
- 観測軸 (cost / delivery / DORA) を後付けで揃えるのが面倒
- session 終了時の片付けが属人化

## このパーソナへの設計指針 (ADR-0026 適用強度: 薄)

- 既存 IT 用語 (commit / branch / merge / deploy 等) はそのまま使う
- 文体ガイド薄適用は次の範囲のみ:
  - `README.md` 冒頭 30 秒部分の「30 秒で理解」表
  - `scripts/_friendly-error.{sh,ps1}` の 4 セクション出力文言
  - `docs/runbooks/` の見出し (例「Deploy (公開)」と和訳併記)
  - `CONTRIBUTING.md` の文体ガイド節
- 内部技術文書 (ADR / source comment / docstring) は現状維持
- friendly_error 出力は「何が起きたか / なぜ / どう直すか / 詳しく」の 4
  セクションを保つ (ADR-0015)

## このパーソナで使う標準ツール

- `scripts/apply-to-project.{sh,ps1}` — Phase 1-8 の全防御 / 観測を 1 コマンド配信
- `scripts/check-quality.sh` — ruff / ktlint / eslint+prettier 統合
- `scripts/cost-report.py` — 3 セクション (Cost / Delivery / Lead time) の weekly レポート
- `scripts/audit-adopter.py` — adopter 側の dev-templates 適用状態を hash 比較で audit
- `skills/session-time-budget/` + `scheduled-tasks/session-cleanup-watch/` — session hygiene

## 関連

- [style-guide.md](style-guide.md) — engineer 向け文体ガイド
- [glossary.md](glossary.md) — engineer 視点の用語辞書
- ADR-0025: Persona-driven multi-mode architecture
- ADR-0026: 日本語ファースト文体規約
