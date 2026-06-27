## Changelog

すべての変更点をこのファイルに記録します。
書式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に準拠し、
バージョン番号は [Semantic Versioning](https://semver.org/lang/ja/) を採用しています。

## [1.0.0] - 2026-06-28

初の安定版リリース。

### 機能

- **メニューバーアイコンを「蔵」に収納** — `archivebox` SF Symbol を「蔵」アイコンとして表示。蔵の左に並べたアプリのメニューバーアイコンを折りたたんでノッチ裏や画面外に押し出し、右側のアイコンはそのまま残す
- **ポップオーバーで呼び出し** — 蔵を左クリックすると、蔵に納まっているアプリのメニューバー項目を一覧表示。クリックで AXPress 発火
- **ホットキー** — `⌃⌥⌘K`（Ctrl+Option+Cmd+K）で折りたたみ／展開をトグル。環境設定の「ホットキー」タブで任意のキーに変更可能
- **位置ベースの対象判定** — 蔵より左にあるアイコンを「蔵対象」と扱うため、登録不要。並べ替えは macOS 標準の `⌘+ドラッグ`
- **並び順の永続化** — `autosaveName` でセパレータ位置を、UserDefaults でアプリ並び順を保存
- **対象アプリ除外リスト** — 環境設定の「対象アプリ」タブで、蔵で管理したくないアプリをチェックボックスで除外
- **起動時 fold 状態** — 起動時に自動で折りたたんだ状態にする設定
- **Mac 起動時自動起動** — `SMAppService` 経由でログイン時に Kura を起動
- **蔵アイコン symbol 選択** — `archivebox` / `tray` / `shippingbox` / `square.stack` / `bubbles.and.sparkles` から選択。`bubbles` は『カグラバチ』の神薙の泡モチーフ

### 必要権限

- **アクセシビリティ権限のみ** — 画面録画権限は一切要求しません

### 動作環境

- macOS 14 (Sonoma) 以降

[1.0.0]: https://github.com/ymnao/Kura/releases/tag/v1.0.0
