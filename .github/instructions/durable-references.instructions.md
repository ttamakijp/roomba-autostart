<!-- generated from source/rules/common/durable-references.md — do not edit; run scripts/build-rules.sh -->
---
applyTo: "**/*"
---

# Durable cross-references

## 要件

- ドキュメント・コミットメッセージ内の参照は **耐久性のある identifier** を一次に使う
- `#NN` (PR / Issue 番号) は **補助的補強情報** に留め、参照の意味を担わせない
- CHANGELOG では `References` セクションで PR リンクを分離し、本文は SHA/ADR/tag で構成する

## 耐久 identifier の優先順

| 識別子 | 安定性 | 用途 |
|---|---|---|
| **commit SHA** (full / short) | 永久 (history 改変なしの限り) | 「あの変更」を一意に指す最終手段 |
| **ADR-NNNN** | リポ内で永続 | 設計判断の参照、長期的な背景説明 |
| **tag (`vX.Y.Z`)** | リポ削除以外で永続 | release 境界、互換性表明 |
| **自然文 PR タイトル** | 人間可読 | コンテキスト伝達 |
| `#NN` (PR / Issue) | **再採番で壊れる** | 補助 (主参照と併記する形で) |

## Do

- 後方参照には short SHA (7-12 文字) を使う: `Refs: 1b0db67`
- 設計判断の引用は `ADR-NNNN`: `Refs: ADR-0005`
- リリース境界の参照は tag: `Refs: v3.5.0`
- 人間向けの文脈には PR タイトルを引用: `「<title>」 (commit <sha>)`
- `Closes #N` / `Fixes #N` は GitHub auto-close を発動させたい時のみ使う (補助、本体ではない)
- CHANGELOG のエントリ末尾に `References` セクションを設け、SHA を一次・PR リンクを補助として併記

## Don't

- `(#NN)` を CHANGELOG / ADR / README の本文中で「変更内容を識別する目印」として使わない
- `#23 を参照` のように `#NN` だけで読者に文脈を解釈させない (SHA / タイトル併記なし)
- `git log --oneline` 出力をそのまま CHANGELOG に貼らない (squash merge は subject に `(#NN)` を自動付与する)
- 真に `(#NN)` 不含の subject を作りたい時に GitHub UI / 既定の `gh pr merge --squash` だけで済ませない。`gh pr merge --squash --subject "<PR title>" --body "<PR body>"` で明示上書きする必要がある (リポ設定 `squash_merge_commit_title=PR_TITLE` は title の **source** を確定するのみで、`(#N)` 自動付与は GitHub 仕様で抑止不能)

## CHANGELOG の推奨フォーマット

```markdown
## [Unreleased] - <カテゴリ>

### Added

- **`path/to/feature.ext`** - 1 行説明。詳細は ADR-NNNN を参照。

### References

- commit `1b0db67` — "feat: foo bar baz" — 補助: PR <URL>
- commit `7739a77` — "chore: bump deps" — 補助: PR <URL>
```

- 主要参照は SHA。GitHub UI で URL に変換するのは閲覧時に行えばよい
- `[#NN](url)` 形式の自動リンクは付けない (`#NN` 単独で意味を持たせない)

## コミットメッセージ footer 推奨

```
feat(scope): subject

body — why を中心に

Refs: <short-sha or ADR-NNNN or vX.Y.Z>
Co-Authored-By: <Name> <email>
```

- `Refs:` には commit SHA / ADR / tag を入れる
- `#NN` を入れる場合は補助として SHA と併記: `Refs: 1b0db67 (PR #45)`

## 根拠

- 2026-05-15 の backup-tag identity 漏洩事故 ([[ADR-0004]]) への対応で repo を delete+recreate した結果、PR #1-#45 が永久消失。`#NN` を使った全参照が壊れた (ADR-0001 / 古い CHANGELOG / claude-bootstrap CHANGELOG)
- `#NN` は GitHub の counter (削除時に reset、org 移行時に振り直し) であり、commit object のような git-native の一意 ID ではない
- SHA は git の content-addressable storage に基づくため、リポ削除・再作成・org 移行のいずれでも (commit object が history に存在する限り) 不変
- ADR / tag はリポ内 path に基づき、`#NN` より安定 (リポ削除以外では壊れない)

## 例外

- GitHub UI 上の auto-close keyword (`Closes #N` / `Fixes #N` / `Resolves #N`) は GitHub-native 機能のため `#NN` 記法を使う。ただしリポ再作成で auto-close 効果は失われる
- PR 説明文 (GitHub UI 上) で他 PR/Issue を参照する場合は GitHub の auto-link を活用してよい (UI 上のみで rendering されるため commit history を汚染しない)
- README の "Recent activity" バッジ等、UI 表示専用箇所は対象外

## 関連

- [[commit-convention]] — Conventional Commits + squash + delete-branch
- [[ADR-0005]] — `docs/adr/0005-durable-cross-references.md`
- [[ADR-0004]] — backup ref scope (この問題を顕在化させた incident)
