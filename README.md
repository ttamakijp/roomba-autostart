# roomba-autostart

ルンバが充電ステーションから自動で発進できない問題を、発進時刻にドックの通電を約 10 秒だけ切ることで解決するシステム。Node-RED + Tapo P110 で実装。

## 構成

- Node-RED on Raspberry Pi OS（常時起動）
- TP-Link Tapo P110（無印、技適済）
- KLAP プロトコル経由でローカル制御

## セットアップ手順

### 1. Node-RED 導入

```bash
bash <(curl -sL https://raw.githubusercontent.com/node-red/linux-installers/master/deb/update-nodejs-and-nodered)
sudo systemctl enable nodered.service
sudo systemctl start nodered.service
```

### 2. Tapo ノード導入

Node-RED パレットで `node-red-contrib-tapo-new-api` をインストール。提供ノード型は `tapo_actions`（`deviceIp` / `command` / `version`（KLAP, 既定 3）を設定。email/password は credentials）。

### 3. フロー import

`flows/flow.basic.json` または `flows/flow.monitored.json` を Node-RED に import。`<TAPO_IP>` プレースホルダを実 IP に置換し、`version` を実機ファーム（KLAP v2/v3）に合わせる。

> import 後に Node-RED 上で編集したら、メニュー → Export で再 export し `flows/*.json` を上書きして正式形式を確定する（手書きテンプレと UI 生成形式の差分を吸収するため）。

### 4. 認証情報の設定

**flows/*.json には実値を入れない**。Node-RED の credentials 画面で：

- TP-Link メール
- TP-Link パスワード
- Tapo IP（DHCP 予約で固定）

を入力（Node-RED が暗号化保存）。

## 詳細設計

[docs/design.md](docs/design.md) を参照。設計判断、却下した代替案、技術的制約をすべて記録。
セキュリティ方針は [docs/security.md](docs/security.md) を参照。

## ライセンス

MIT
