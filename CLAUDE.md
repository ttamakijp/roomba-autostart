# CLAUDE.md - roomba-autostart

このプロジェクトはルンバ自動発進システム。Node-RED + Tapo P110（無印）+ Raspberry Pi OS で構成。
詳細設計は [docs/design.md](docs/design.md) を参照。

## 技術スタック

- Node-RED on Raspberry Pi OS（host: tailscale-gateway）
- node-red-contrib-tapo-new-api（KLAP プロトコル対応）
- TP-Link Tapo P110（無印、電力モニタリング付き、技適済）

## ビルド / 実行

本プロジェクトはコード build ではなく Node-RED フローを配布する。
flows/*.json を Node-RED に import して使用。

## セキュリティ

- TP-Link 認証情報を flows/*.json にコミットしない（プレースホルダのみ）
- 詳細は docs/security.md（dev-templates 標準）と本 repo の README を参照
- KLAP 認証情報は Node-RED credentials 経由（暗号化）で注入

## 主要 docs

- [docs/design.md](docs/design.md): 設計判断・制約・受け入れ条件（正本）
- [README.md](README.md): セットアップ手順
