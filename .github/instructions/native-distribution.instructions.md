<!-- generated from source/rules/common/native-distribution.md — do not edit; run scripts/build-rules.sh -->
---
applyTo: "**/*"
---

# Native technology by distribution target

## 要件

- 新規 project の **言語選定は配布形態から逆引きする** (ADR-0019)
- bootstrap 時点で「想定配布先」と「配布検証 step」が `BOOTSTRAP_NOTES.md`
  または `README.md` に書かれている
- アンチパターン (Python + Windows EXE 等) を bootstrap 時点で検出する

## 4 階層の優先順 (上位から試す)

| 階層 | 技術例 | 適合用途 | 配布痛点 |
|---|---|---|---|
| 1. portable native compile | Rust / Go / .NET 8+ AOT | CLI / utility / server | 最小 (単一 EXE / runtime 不要) |
| 2. native shell + web UI | Tauri (Rust + TS) / Wails (Go + TS) | クロス OS GUI | 小 (~5-10MB binary) |
| 3. per-OS native | Swift / Kotlin / C# WinUI | 各 OS UX が要件 | 中 (OS 別 build) |
| 4. portable runtime | Python / Node.js | 社内 / server / 開発者 CLI | 大 (runtime 同梱 / インストーラ要) |

## 判断手順

1. 配布形態を決める (EXE / Web URL / App Store / 社内)
2. ターゲット OS を確定
3. 階層 1 から順に適合を試す
4. 制約 (チーム skill / 期間 / UX 要件) で必要なら 1 段下げる

## Do

- 配布形態を先に決めてから言語を選ぶ
- bootstrap 時点で `BOOTSTRAP_NOTES.md` に「想定配布先」と「配布検証 step」
  を書く
- Rust / Go / .NET AOT で済むなら他を選ばない (階層 1 最優先)
- GUI が必要なら Tauri / Wails を先に検討 (階層 2)
- 階層 4 (Python / Node.js) は配布痛点を許容できる用途に限定

## Don't

- 「言語が好きだから」で配布形態を後付けで決めない
- Python を **Windows EXE 配布** の主言語に選ばない (PyInstaller / Nuitka
  苦行)
- Electron で小規模 utility を作らない (Tauri / Wails で代替)
- per-OS native を **専門人員確保なしに** 全 OS 並行開発しない

## アンチパターン詳細

### Anti A: Python + Windows EXE

| 症状 | 推奨解 |
|---|---|
| PyInstaller の hidden import 解決が CI と乖離 | 言語変更 (Rust + Tauri / Go + Wails / .NET AOT) |
| Defender false positive | 配布形態変更 (Web UI 化) |
| 50-100MB のサイズ膨張 | 言語変更 |
| ライセンス追跡が複雑 | 言語変更 (Rust の crate license は単純) |
| ユーザに Python install 要求 | 配布形態変更 / WSL / Microsoft Store |

### Anti B: Electron で小規模 utility

| 症状 | 推奨解 |
|---|---|
| 数 MB の機能に 150MB Chromium 同梱 | Tauri / Wails / .NET MAUI / WinUI |

### Anti C: per-OS native の全 OS 並行開発

| 症状 | 推奨解 |
|---|---|
| 3 OS x 専門人員 → 人員不足で頓挫 | 階層 1 (portable native) に降格、UX 妥協 |

## bootstrap 時の必須記載項目

`claude-bootstrap/templates/<lang>/BOOTSTRAP_NOTES.md` または下流 project の
`BOOTSTRAP_NOTES.md` には以下を含める:

- **想定配布先**: EXE / Web URL / App Store / 社内 のいずれか
- **配布検証 step**: 配布後にユーザ環境で動作確認する具体的コマンド
  (例: `./app.exe --version` が CI / 配布先 PC の両方で成功する)
- **採用階層と根拠**: 階層 1-4 のどれを選んだか、降格理由 (あれば)

## 根拠

- 「Python で書いて Windows EXE 配布」を bootstrap で禁止すれば、後段で
  発生する苦行ループ (PyInstaller / Defender / サイズ / ライセンス) が
  まとめて回避される
- portable native compile (Rust / Go) は **配布痛点の累積コスト** が
  最小。学習コストは初回のみ、運用フェーズで回収される
- Tauri / Wails は Electron の代替として確立されつつあり、binary サイズ
  ~10MB と Electron ~150MB の差は配布体験を大きく改善する

## 例外

- 既存 project が階層 4 (Python / Node.js) で稼働中 → 本 ADR は新規
  bootstrap のみに適用。既存 project の言語変更は別判断
- 機械学習 / 科学計算で Python が支配的な領域 → 内部処理は Python、
  配布は API / Web UI で wrap
- 検証用 PoC で配布が無関係 → 階層は任意

## 関連

- [[ADR-0019]] — 本 rule の元 ADR
- [[ADR-0010]] — quality gates (言語選定 **後** の lint / test)
- [[ADR-0013]] — 開発環境再現性
- [[ADR-0020]] — 本 ADR の 6 ヶ月 review cadence
