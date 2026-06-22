# Kura（蔵）

[![Build](https://github.com/ymnao/Kura/actions/workflows/build.yml/badge.svg)](https://github.com/ymnao/Kura/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014%2B-blue)](https://www.apple.com/macos/)

> macOS のメニューバーアイコンを「蔵」に収納し、当主（あなた）が自由に出し入れするツール。

少年漫画『カグラバチ』に登場する妖術「蔵」（亜空間収納術）がモチーフ。

## なぜ作ったか

ノッチ付き MacBook では、メニューバーアイコンが多いと**ノッチの裏にサイレントに隠される**問題があります。既存ツール（Bartender, Ice）は便利ですが、**画面録画権限を要求する**ため抵抗があるユーザーもいます。

Kura は**画面録画権限を一切使わず、アクセシビリティ権限だけ**で動作します。

## 特徴

- **画面録画権限不要** — アクセシビリティ権限のみ
- **軽量** — AppKit のみ、ポーリングなし、メモリ常駐 < 30MB が目標
- **シンプル** — 機能を絞って、迷わず使える
- **macOS ネイティブ** — Swift + AppKit

## 要件

- macOS 14 (Sonoma) 以降
- Xcode 16 以降（ビルド時）

## ビルド & 起動

```bash
git clone https://github.com/ymnao/Kura.git
cd Kura
./build.sh
open Kura.app
```

停止：

```bash
pkill Kura
```

開発時（直接実行）：

```bash
swift build       # debug
swift run         # 直接実行（.app バンドルを介さない）
```

## 使い方

1. 初回起動でアクセシビリティ権限を許可する
2. メニューバーに「蔵」と「セパレータ（薄い縦線アイコン）」の 2 つが表示される
3. **⌘+ドラッグでセパレータを蔵の左側に並べ替える**（初回のみ。次回以降は `autosaveName` で記憶される）
4. 隠したいメニューバーアイコンを **⌘+ドラッグ** でセパレータの左側に並べる
5. 蔵の操作:
   - **左クリック** — ポップオーバーが開き、蔵に納まっているアプリのメニュー項目が一覧表示される（クリックで発火）
   - **右クリック** — 「折りたたむ／展開する」「Kura を終了」メニュー
   - **⌃⌥⌘K**（Ctrl+Option+Cmd+K）— 折りたたみ／展開のトグル（グローバルホットキー）
6. 「折りたたむ」でセパレータが画面幅まで膨張し、その左側のアイコンを画面外（ノッチ裏含む）に押し出す

蔵対象は「蔵より左にあるアイコン」と**位置で定義**されるため、明示的な登録設定はありません。

## アーキテクチャ

詳細は [ARCHITECTURE.md](ARCHITECTURE.md) を参照。

## ロードマップ

- [x] v0.0.1: メニューバーに「蔵」アイコン + 空のポップオーバー
- [x] v0.1: 設定画面（蔵に登録するアプリを選択）
- [x] v0.2: AXUIElement で対象アプリのメニューバー項目を列挙
- [x] v0.3: ポップオーバーから項目クリックで AXPress 発火
- [x] v0.4: NSStatusItem.length 膨張による折りたたみ + 位置ベース対象判定
- [ ] v0.5: ホットキー対応（⌃⌥⌘K で折りたたみ／展開）、開閉アニメーション、ノッチ裏アイコンの自動検出表示

## コントリビュート

[CONTRIBUTING.md](CONTRIBUTING.md) を参照。

## ライセンス

[MIT](LICENSE)
