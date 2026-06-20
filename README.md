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

（実装が進んだら追記）

## アーキテクチャ

詳細は [ARCHITECTURE.md](ARCHITECTURE.md) を参照。

## ロードマップ

- [x] v0.0.1: メニューバーに「蔵」アイコン + 空のポップオーバー
- [ ] v0.1: 設定画面（蔵に登録するアプリを選択）
- [ ] v0.2: AXUIElement で対象アプリのメニューバー項目を列挙
- [ ] v0.3: ポップオーバーから項目クリックで AXPress 発火
- [ ] v0.4: ノッチで隠れた項目の自動検出
- [ ] v0.5: ホットキー対応、開閉アニメーション

## コントリビュート

[CONTRIBUTING.md](CONTRIBUTING.md) を参照。

## ライセンス

[MIT](LICENSE)
