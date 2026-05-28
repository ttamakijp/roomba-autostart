# engineer persona — 用語辞書

engineer 視点で「**そのまま使う**カタカナ英語」と「**和訳併記すべき**境界用語」
を整理する。persona 中立の対応表は [`docs/glossary.md`](../../docs/glossary.md)
を参照。

## そのまま使うカタカナ英語 (engineer 日常)

| 用語 | 補足 |
|---|---|
| commit / branch / merge | git 操作の基本動詞、和訳は冗長 |
| pull request / PR | GitHub UI と直結 |
| repository / repo | フォルダではなく履歴付き保管庫の意 |
| install / setup | パッケージ / 環境構築の基本動詞 |
| deploy / rollback | リリース工程の動詞 |
| build / compile | コード → バイナリの工程 |
| lint / format | コード品質チェック |
| coverage | テスト網羅率 |
| CI / CD | 継続的統合 / 配信 |
| issue / label | GitHub trackable item |

## 薄適用範囲で和訳併記する用語

(ADR-0026 §4.3 適用範囲のみ)

| 用語 | 和訳併記例 | 出現箇所 |
|---|---|---|
| Deploy | Deploy (公開) | `docs/runbooks/deploy.md` 見出し |
| Rollback | Rollback (差し戻し) | `docs/runbooks/rollback.md` 見出し |
| Incident | Incident (障害) | `docs/runbooks/incident-response.md` 見出し |
| Oncall | Oncall (当直) | `docs/runbooks/oncall-handoff.md` 見出し |
| Postmortem | Postmortem (事後検証) | `docs/runbooks/postmortem.md` 見出し |
| Safety | Safety (安全) | README 30 秒理解表 |
| Quality | Quality (品質) | README 30 秒理解表 |
| Maintenance | Maintenance (保守) | README 30 秒理解表 |
| Operations | Operations (運用) | README 30 秒理解表 |

## 和訳が不要な用語 (薄適用範囲外)

| 用語 | 理由 |
|---|---|
| ADR | Architecture Decision Record の確立用語 |
| API | 翻訳すると意図がぼやける |
| LLM / AI | 業界標準略語 |
| frontmatter | markdown YAML header の確立用語 |
| skill / scheduled-task | dev-templates 内部概念、定義済 |
| hook | git hook / pre-commit hook の確立用語 |
| host | host-aware guard (ADR-0012) の確立用語 |
| persona | 本制度 (ADR-0025) の確立用語 |

## 関連

- [`docs/glossary.md`](../../docs/glossary.md) — persona 中立の共通辞書
  (IT ↔ 製造業 ↔ 英語)
- [`personas/manufacturing/glossary.md`](../manufacturing/glossary.md) —
  製造業視点で全面和訳した対比辞書
