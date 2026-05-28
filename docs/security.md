# セキュリティ方針 — roomba-autostart

本プロジェクトは Node-RED フロー（JSON）と Raspberry Pi 上の運用が成果物。
扱う機密は **TP-Link アカウント認証情報** と **Tapo の固定 IP** のみ。
dev-templates の leak-prevention（`scripts/check-leakage.sh` の pre-commit / CI）を併用する。

## 1. 認証情報をコミットしない（最重要）

Node-RED の export JSON には、ノード設定次第で **TP-Link のメール / パスワードが平文で含まれる**。
公開リポジトリに上げる際は必ず以下を守る:

- `flows/*.json` には **プレースホルダのみ**（`<TPLINK_EMAIL>` / `<TPLINK_PASSWORD>` / `<TAPO_IP>`）を置く。実値を埋めない。
- 実値は **Node-RED の credentials 画面**（暗号化保存。`flows_cred.json` に AES 暗号化される）経由で注入する。
- `flows_cred.json` および実フローのバックアップは `.gitignore` で除外する（本 repo の `.gitignore` 設定済み）。

## 2. 誤コミット時の対応

- 認証情報が混入した状態でコミット/push した場合は **即座に TP-Link パスワードをローテーション** し、`git filter-repo` 等で履歴から除去する。
- 公開 repo では push 時点で第三者に取得され得るため、ローテーションを最優先とする。

## 3. ネットワーク前提

- 通電制御指令は **LAN 内で完結**（クラウド非依存）。ただし KLAP 認証には TP-Link アカウントが必要で、完全オフライン化はスコープ外。
- Pi ⇔ Tapo は同一セグメントで相互到達できること（AP/クライアントアイソレーション無効 / VLAN 分離時はルーティング許可）。

## 4. AI ツールに読ませない

- 実 `flows_cred.json` / `.env*` / credentials を Claude / Copilot 等の AI に直接読ませない（context / 学習経路への流出防止）。

詳細な設計判断は [design.md](design.md) §10 を参照。
