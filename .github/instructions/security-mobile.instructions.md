<!-- generated from source/rules/common/security-mobile.md — do not edit; run scripts/build-rules.sh -->
---
applyTo: "**/*"
---

# Mobile security

## 適用条件

以下を扱う実装では本ルールを必ず参照する:

- API キー・シークレット・認証情報
- 通信処理・ネットワーク実装
- データ保存・暗号化処理
- ユーザ認証・ログイン・セッション管理
- パーミッション要求
- ログ出力・デバッグ情報
- ProGuard ルール設定
- プライバシーポリシー / GDPR 対応
- インシデント・障害対応
- 依存ライブラリ（supply chain）

## API キー・シークレット管理

### Do

- API キー / OAuth client secret / エンドポイント URL は `local.properties` または環境変数経由でビルド時に注入する
- `local.properties` / `*.keystore` / `.env*` を `.gitignore` で確実に除外する
- release build では `BuildConfig` フィールドにのみ展開し、ソースに残さない
- 誤コミット発覚時は **即座にシークレットをローテーション** し、`git filter-repo` 等で履歴から削除する

### Don't

- API キー / シークレットをソースコードへハードコードしない
- 機密値をログ出力 / Crashlytics レポートに含めない
- `.env*` / `**/secrets/**` / `local.properties` / `*.keystore` を Claude / Copilot 等の AI に直接読ませない

## OWASP Mobile Top 10 対応

| 項目 | 対応 |
|------|------|
| M1 不適切な認証情報管理 | API キーの外部化、`BuildConfig` 経由のみ |
| M2 安全でないデータ保存 | `EncryptedSharedPreferences` / SQLCipher で機密データ保護 |
| M3 安全でない通信 | 全通信を HTTPS / TLS 1.2 以上に限定 |
| M5 不十分な暗号化 | AES-256-GCM 等の強固なアルゴリズムを使用 |
| M8 コード改ざん | ProGuard 難読化、整合性チェック |
| M9 リバースエンジニアリング | デバッグ情報の release 除外 |

## データ暗号化

### Do

- 認証情報 / トークン / 機密 PII は `EncryptedSharedPreferences`（Jetpack Security）で保存する
- SQLite で機密データを扱う場合は SQLCipher を採用する
- 機密ファイルは `EncryptedFile` を使用する
- 暗号化キーは Android Keystore System で保護する

### Don't

- 暗号化キーをアプリコード / 平文 SharedPreferences に保存しない
- AES-128-ECB 等の脆弱モードを使用しない

## 通信・プライバシー保護

- 全通信は HTTPS（TLS 1.2 以上）
- `android:usesCleartextTraffic="false"` をデフォルトとし、例外は Network Security Config で明示する
- 証明書ピニングが必要な API は `network_security_config.xml` で設定する
- サードパーティ SDK の送信データを把握し、不要な情報収集 SDK を導入しない
- バックグラウンド送信は最小限に留め、ユーザに開示する

## パーミッション設計

- `AndroidManifest.xml` に必要最小限のパーミッションのみ宣言する
- 危険なパーミッション（CAMERA / LOCATION / CONTACTS 等）は使用直前にリクエストし、理由を UI で説明する
- 拒否時の代替フローを必ず実装する
- `ACCESS_FINE_LOCATION` より `ACCESS_COARSE_LOCATION` で足りる場合は後者を使用する
- Android 12+ の概算位置情報オプションに対応する

## ProGuard / 難読化

- release build で ProGuard / R8 を **有効化** する（`minifyEnabled true`、`shrinkResources true`）
- サードパーティ SDK 提供の ProGuard ルールを必ず適用する
- リフレクション使用クラスは `-keep` で保護する
- 難読化マッピング `mapping.txt` をリリースごとに保存・管理する

## デバッグ情報の管理

- `Log.d()` / `Log.v()` 等のデバッグログを release build から除外する
- `BuildConfig.DEBUG` フラグ、または Timber 等のライブラリで release 時無効化を徹底する
- スタックトレース・内部エラーメッセージをユーザ向け UI に表示しない
- デバッグ用 UI（シークレットメニュー等）は release で非表示にする

## ログの取り扱い

- PII（メール / 電話番号 / 氏名 / 位置情報）をログに出力しない
- ユーザ ID はハッシュ化してログに使う
- Firebase Crashlytics に機密カスタムキーを設定しない
- ログ保存期間を定め、不要ログを定期削除する
- external storage 保存時は Android 10+ のスコープドストレージに対応する

## リポジトリ全体での PII 検出 (ADR-0006)

ログ出力規約はランタイム挙動の話だが、**リポジトリ commit / push 段階での PII 混入**
も同じカテゴリで防御する。dev-templates では `scripts/check-leakage.sh` の
pre-commit / CI フックが以下を検出する (ADR-0006):

- 個人メール (noreply 以外は fail)
- 電話番号 (日本携帯 070/080/090 / +81 / +1 北米)
- 住所 (〒NNN-NNNN / US street address)
- 氏名 deny-list (`scripts/.leak-name-denylist` 設定時、リポ毎に opt-in)
- 社内ドメイン (`*.co.jp` / `*.atlassian.net` 等は warn)
- クレデンシャルファイル (`.env` / `*.pem` / `*.key` / `local.properties` 等が
  tracked 化されたら fail)

詳細: [`docs/adr/0006-pii-detection-policy.md`](../../../docs/adr/0006-pii-detection-policy.md)。
Android アプリ実装では「ログに出すな」「リポにコミットするな」の両層で防御することを
覚える。

## ユーザ認証・セッション管理

- OAuth 2.0 / OpenID Connect は **PKCE フロー**（Authorization Code + PKCE）を使う
- アクセストークンは `EncryptedSharedPreferences`、リフレッシュトークンは Android Keystore で保護する
- セッションタイムアウトを実装し、長期非アクティブセッションを無効化する
- 生体認証は `BiometricPrompt` + Keystore 連携で行う
- ディープリンク経由の OAuth コールバック URL を厳密に検証し、リダイレクトインジェクションを防ぐ
- ログアウト時はトークンをサーバ側でも無効化し、ローカル認証情報を確実に消去する

## プライバシー・GDPR

- 個人情報収集前にユーザの明示的同意を取得する
- 収集データの種類・目的・保存期間をプライバシーポリシーに明記する
- データ削除要求（忘れられる権利）に対応するアーキテクチャを設計する
- Google Play Data Safety フォームと実際の収集内容を一致させる
- 未成年者向けアプリは COPPA + GDPR 児童条項を遵守する

## supply chain hygiene

### Do

- 依存ライブラリは公式リポジトリ / 公式 SDK のみを使う
- 依存追加前にライセンス（OSS license）・メンテナンス状況・最終リリース日を確認する
- `Gradle Version Catalog`（`libs.versions.toml`）等で依存バージョンを集中管理する
- 依存のセキュリティアドバイザリ（GitHub Dependabot / Snyk / OSV）を有効化する
- 重大脆弱性検知時は **24 時間以内** に patch / 代替へ切り替える

### Don't

- 出所不明な GitHub gist / personal fork を依存に追加しない
- バージョン pinning なしの `+` / `latest.release` 指定を使わない
- 公式リポジトリ以外（jitpack の personal repo 等）を anchor として使い続けない

## インシデント・障害対応

- クラッシュ・セキュリティ異常を Firebase Crashlytics 等で即座に検知できる体制を整える
- 脆弱性発見時は **即座に修正リリース** を準備し、影響範囲をユーザへ通知する
- 認証情報漏洩疑いがある場合は即時ローテーション + 影響ユーザへパスワードリセットを促す
- 障害対応後は再発防止策をドキュメントに記録する

## 根拠

- OWASP Mobile Top 10 は業界標準で、リスク優先順位の根拠になる
- 暗号化キーをコードに含めると静的解析で容易に抽出可能なため Keystore 必須
- supply chain 攻撃は 2020 年以降急増しており、依存の出所確認は基本動作
- AI（Claude / Copilot 等）に `.env*` / `*.keystore` を読ませると、トークンが context / 学習データへ流出する経路になる

## 例外

- debug build のみで動作する HTTP サーバ等は `BuildConfig.DEBUG` ガード下で平文 SharedPreferences 可（信頼ローカル LAN 限定）
- 暗号化対象外: 公開コンテンツのみを扱う read-only キャッシュ
