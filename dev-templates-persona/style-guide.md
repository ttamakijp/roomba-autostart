# engineer persona — 文体ガイド

ADR-0026 日本語ファースト文体規約の **薄適用** persona。

## 原則

- IT 業界の慣用カタカナ英語 (commit / branch / merge / deploy / install
  / setup / repository / pull request) は**そのまま使ってよい**
- 既存 ADR / source code の docstring / 内部技術文書は**現状維持**
- ただし次の境界では薄く和訳併記する (ADR-0026 §4.3)

## 薄適用する範囲

### A. README.md 冒頭 30 秒部分

「30 秒で理解」表の「領域」列だけは和訳を併記する。

```markdown
| 領域 | 内容 | 関連 ADR |
|---|---|---|
| 🛡 **Safety (安全)** | 5 層 leak prevention ... |
| 🎯 **Quality (品質)** | lint / format / coverage ... |
```

### B. friendly_error 出力 (`scripts/_friendly-error.{sh,ps1}`)

4 セクション (何が起きたか / なぜ / どう直すか / 詳しく) はそのまま。
冒頭の `❌ エラー [CODE]` を `❌ エラー [CODE] / Error` のように併記**しない**
(ADR-0015 で「日本語のみで完結」と決定済)。

### C. docs/runbooks/ 見出し

主要 runbook 見出しに英語術語を残しつつ和訳を**括弧併記**:

```markdown
# Deploy（公開）
# Rollback（差し戻し）
# Incident response（障害対応）
# Oncall handoff（当直引き継ぎ）
# Postmortem（事後検証）
```

### D. CONTRIBUTING.md の文体ガイド節

「Style guide / 文体ガイド」セクションを新設して、本ガイドへの link を貼る。

## 薄適用しない範囲

| 範囲 | 理由 |
|---|---|
| ADR 本文 | 既存資産が大量、和訳併記は混乱を招く |
| source code コメント / docstring | engineer 同士の口語、効率を優先 |
| runbook 本文 (CLI コマンド / output 例) | 機械的可読性を維持 |
| 履歴 (CHANGELOG / commit message) | 既存スタイルを維持 |
| skill / scheduled-task の SKILL.md 本文 | AI tool が解釈する内部文書 |

## やってよい / やってはいけない

```markdown
# OK — engineer 日常
git commit -m "feat: API endpoint を追加"
PR を出してレビューしてもらう

# OK — README 冒頭の 30 秒理解 (薄適用範囲)
| 🛡 **Safety (安全)** | 5 層 leak prevention ... |

# OK — friendly_error
❌ エラー [APPLY_001]
何が起きたか:
  TARGET 引数が指定されていない

# NG (薄適用範囲外なので強制しない、ただし冗長化注意)
- 「コミット」を「保存」に書き換える
- 「リポジトリ」を「保管庫」に書き換える
```

## 関連

- [glossary.md](glossary.md) — engineer 視点の用語辞書
- `docs/glossary.md` — persona 中立の共通用語辞書
- ADR-0026 §4.3: engineer 薄適用の境界
- `personas/manufacturing/style-guide.md` — 全面適用の対比例
