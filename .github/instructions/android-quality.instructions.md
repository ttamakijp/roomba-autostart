<!-- generated from source/rules/common/android-quality.md — do not edit; run scripts/build-rules.sh -->
---
applyTo: "**/*.{kt,kts}"
---

# Android quality

## 要件

- アーキテクチャ: Clean Architecture + MVVM
- 言語: Kotlin、UI は Jetpack Compose + Material Design 3
- リント: ktlint（Kotlin）
- セキュリティ: OWASP Mobile Top 10 準拠（詳細は `security-mobile` ルール参照）
- テスト: 新機能・バグ修正には必ずユニットテストを同時作成する

## Do

- ファイル冒頭にそのファイルの責務を 1 行コメントで明示する
- Composable は「1 ファイル = 1 トップレベル Composable + 直近 private 補助」までに制限する
- ViewModel が use case 5 個超に達したら委譲パターン（`<Domain>UiStateProducer` / `<Domain>Effects` / `<Domain>Actions`）へ分割する
- Repository はドメインごとに分割する（例: `VideoMetadataRepository` / `VideoCacheRepository` / `VideoStreamRepository`）
- Repository はインターフェース層と実装層を別ファイルに分ける
- Compose Theme は `tokens.kt` / `colors.kt` / `typography.kt` / `shapes.kt` / `dimensions.kt` に細分する
- Activity / Fragment は状態管理を `<Screen>StateHolder`、ライフサイクル処理を別 observer、ナビゲーションを `<Screen>Navigator` へ委譲する
- ワイヤレスデバッグはペアリング → TLS → Tailscale → USB の順で接続を試す
- 複数端末接続時は `adb devices` で全端末にインストールを展開する
- 端末役割（Primary / Secondary / Staging）と Tailscale IP・シリアルは `memory/reference_devices.md` に記録する

## Don't

- 単一 Composable ファイルへ独立責務の Composable を同居させない（別ファイルへ）
- ViewModel に orchestration 以外（UI 状態構築・副作用処理・アクションハンドラ）を直接実装しない
- 1 つの `Theme.kt` に theme 全要素を詰め込まない
- ProGuard / R8 を release build で無効化しない
- レガシー 500 行超ファイルへ追記する前に分割タスクを起こさず触らない

## 言語別の最低基準

| 言語 | 標準 |
|------|------|
| Kotlin | ktlint、Clean Architecture + MVVM、Compose + MD3 |
| Python | PEP 8 / Black |
| JavaScript / TypeScript | ESLint + Prettier |
| API | RESTful 設計、入力バリデーションは境界のみ |

## ファイル分割（Android 特化）

### Composable

- 1 ファイル = 1 トップレベル Composable + 直近 private 補助 Composable のみ
- 独立責務 Composable は別ファイル（例: `PlaybackScreen.kt` ≠ `VideoControlsOverlay.kt`）

### ViewModel

- use case 5 個超 → 委譲パターン
- 委譲先: `<Domain>UiStateProducer` / `<Domain>Effects` / `<Domain>Actions`
- ViewModel 本体は orchestration のみに留める

### Repository

- ドメインごとに分割
- インターフェース層と実装層を別ファイルに

### Activity / Fragment

- 状態管理 → 別 helper class（`<Screen>StateHolder`）
- ライフサイクル処理 → 別 lifecycle observer
- ナビゲーション → 別 `<Screen>Navigator`

### Compose Theme

- `tokens.kt` / `colors.kt` / `typography.kt` / `shapes.kt` / `dimensions.kt` に分離する

### 既存巨大ファイルの対処

- 新機能追加で 500 行超えそうなら追加前に分割する
- レガシーで 500 行超のものは見つけ次第「分割タスク」を別 PR で起こす

## ADB トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| `offline` | USB デバッグ認証期限切れ | デバイスで「RSA キーを常に許可」を再承認 |
| `unauthorized` | PC の RSA キー未信頼 | デバイス画面の認証ダイアログを確認 |
| `cannot connect to daemon` | adb サーバ停止 | `adb kill-server && adb start-server` |

## logcat プリセット

```bash
# クラッシュ
adb logcat -d | grep -iE "FATAL|AndroidRuntime|ANR"

# 特定パッケージ
adb logcat -d | grep -E "<package_name>"

# Compose リコンポーズ
adb logcat -d | grep -E "Recompose|Composer"

# Hilt DI エラー
adb logcat -d | grep -iE "Hilt|Dagger|injection"

# Network エラー
adb logcat -d | grep -iE "OkHttp|HTTP [4-5][0-9]{2}|UnknownHost|Timeout"

# クラッシュ直前の文脈
adb logcat -d | grep -B 50 "FATAL EXCEPTION" | tail -100
```

## 根拠

- MVVM + Clean Architecture により責務分離が機械的に検証可能になり、AI による grep ベースの編集効率が上がる
- Composable / ViewModel / Repository の分割は context window 効率と単体テスト容易性を両立する
- OWASP Mobile Top 10 準拠は本ルールでは方針提示のみ、詳細実装は `security-mobile` ルール側に集約する

## 例外

- 自動生成コード（`*.g.kt` / `*_pb2.py` 等）は分割ルール適用外
- フィクスチャ・sample data（`tests/fixtures/**`）は適用外
- migration ファイル（`*/migrations/**`）は適用外
