# Architecture

## 設計原則

1. **画面録画権限を一切使わない** — Bartender / Ice との根本的な差別化
2. **軽量** — メモリ常駐 < 30MB、アイドル CPU = 0%
3. **シンプル** — 機能を絞り、迷わせない
4. **イベント駆動** — ポーリングしない

## 全体構成

```
┌─────────────────┐
│ NSStatusItem    │  メニューバー上の「蔵」アイコン
└────────┬────────┘
         │ click
         ↓
┌─────────────────┐
│ NSPopover       │  吹き出し UI
└────────┬────────┘
         │ render
         ↓
┌─────────────────┐
│ MenuBarScanner  │  AXUIElement で対象アプリのメニューバー項目を列挙
└────────┬────────┘
         │ click on item
         ↓
┌──────────────────┐
│ MenuBarDispatcher│  AXPress で対象項目を発火
└──────────────────┘
```

## API 選定

| 目的 | 使用 API | 必要権限 |
|---|---|---|
| 自分のアイコン配置 | `NSStatusItem` | 不要 |
| ポップオーバー描画 | `NSPopover`, `NSPanel` | 不要 |
| 起動中アプリ列挙 | `NSWorkspace.runningApplications` | 不要 |
| 他アプリのメニューバー項目取得 | `AXUIElementCopyAttributeValue` (`kAXChildrenAttribute`) | アクセシビリティ |
| 項目の位置取得 | `AXUIElementCopyAttributeValue` (`kAXPositionAttribute`) | アクセシビリティ |
| 項目のクリック | `AXUIElementPerformAction` (`kAXPressAction`) | アクセシビリティ |
| ホットキー登録 | `RegisterEventHotKey` (Carbon) | 不要 |
| アプリアイコン取得 | `NSWorkspace.icon(forFile:)` | 不要 |

## ファイル構成

```
Sources/Kura/
├── KuraApp.swift                 エントリポイント（@main struct, @MainActor 隔離）
├── AppDelegate.swift             NSStatusItem (本体 + セパレータ) / NSPopover の組み立て、折りたたみ
├── KuraViewController.swift      ポップオーバーの NSOutlineView UI
├── MenuBarLayoutScanner.swift    全アプリの NSStatusItem 座標から蔵対象を列挙
├── MenuBarScanner.swift          AXUIElement で対象アプリの項目を列挙
├── MenuBarDispatcher.swift       AXPress で項目を発火
├── MenuBarItem.swift             ScanResult / MenuBarItem 値型
└── AccessibilityPermission.swift AX 権限の確認・要求・設定起動
```

## 折りたたみ方針（v0.4 で実装済み）

メニューバーアイコンの折りたたみは **NSStatusItem.length 膨張方式**（Hidden Bar / Vanilla / Dozer と同じ）で実装している。画面録画権限不要、アクセシビリティ権限すら不要で、NSStatusItem の `length` を巨大化することで、左隣のアイコンを画面外（ノッチ裏含む）に押し出して物理的に隠す。

### UI 構成 — 蔵本体 + セパレータの 2 NSStatusItem 方式

当初は「蔵 1 個方式」を目指したが、`NSStatusBarButton` の content（image/title）が**ボタンフレームの中央**に hard-coded で配置される仕様のため、`length` 膨張時に蔵自身が画面外に消える問題が発生。`imagePosition`、`alignment`、`attributedTitle.paragraphStyle`、巨大 NSImage、いずれも content を右端固定できず断念。

代わりに Hidden Bar と同じ **2 NSStatusItem 方式** を採用:

- **蔵本体** (`statusItem`): 通常 `variableLength`、常に右端側に表示。「蔵」テキスト表示
- **セパレータ** (`separatorItem`): 通常 `length=8`（薄い縦線アイコン）。折りたたみ時 `length=max(500, min(screenWidth*2, 10000))` で膨張、左隣のアイコンを押し出す

```
展開:  [Alfred][｜][蔵]            ← セパレータ length=8
折畳:                  [蔵]        ← セパレータ length=4000+、その左は画面外
```

両 NSStatusItem は `autosaveName`（`kura.main` / `kura.separator`）で位置を永続化。初回起動時はユーザーが ⌘+ドラッグで「セパレータを蔵の左」に並べ替える必要がある。

`isVisible = true` を起動時に呼び、ユーザーが ⌘+ドラッグでメニューバーから外した場合の自動復元も入れる。

### ON/OFF 切替 UI — 右クリックメニュー

切替操作は**蔵の右クリックメニュー**で行う。

- 左クリック → ポップオーバー（蔵対象アプリのメニュー項目表示）
- 右クリック → メニュー（「折りたたむ／展開する」「Kura を終了」）

セパレータが蔵の右にある配置では「折りたたむ」をグレーアウト（`isEnabled = false`）し、ツールチップで「セパレータを蔵の左に ⌘+ドラッグしてから使ってください」と案内する。

折りたたみ状態は `separatorItem.length` で表現するため UserDefaults 永続化は不要。

### 対象アプリの選定 — 位置ベース

「蔵に入れる対象アプリ」のリストは持たず、**蔵より左にある NSStatusItem を持つアプリ = 蔵の対象** と定義する。

- ユーザーが ⌘+ドラッグで隠したいアイコンを蔵の左に置く
- Kura は `kAXPositionAttribute` で各 NSStatusItem の座標を読み、蔵自身の座標（`statusItem.button?.window?.frame.minX`）と比較
- `x < kuraX && x > 0` のものを蔵対象として列挙
- `x <= 0` は Control Center のドロップダウン hidden item や画面外の NSStatusItem を除外するためのフィルタ
- ポップオーバーで各アプリの AXExtrasMenuBar 配下メニューを表示・AXPress で発火

これにより「擬似的に非表示」と「蔵に入っている」が**構造的に一致**する。RegistrationStore（明示的な登録設定）は v0.4 で廃止。

### スキャンタイミング

ポップオーバーを開く度に `MenuBarLayoutScanner.scanLeftOfKura(kuraX:)` を `Task.detached` で実行する。AX 呼び出しは `messagingTimeout = 1.0` 秒で同期だが、`runningApplications` 全数走査になるためメインスレッドはブロックしない設計。

## 制約と妥協

- **他アプリのメニューバーアイコン画像は使えない** — Dock/Finder のアプリアイコンで代用
- **アイコンの自動再配置はできない** — `kAXPositionAttribute` は読めるが、他アプリの NSStatusItem には書けない（`isAttributeSettable` が false）。ユーザーが ⌘+ドラッグで手動配置
- **macOS システム純正アイコン（時計・コントロールセンター等）は隠せない** — 蔵より右端側に固定配置されているため
- **新規 NSStatusItem は既存項目の左に出現する**（macOS 11+ 仕様、autosaveName で位置記憶しているアプリは前回位置）— 位置ベース設計では「新規アプリが自動的に蔵入り」する挙動になる

## なぜ画面録画権限を避けるのか

- ユーザーの心理的抵抗が大きい
- macOS Sonoma 以降、画面録画中は紫バッジが出るため UX を損なう
- 「メニューバー管理」と「画面録画」の権限粒度が一致しない
- アクセシビリティ権限だけで本質的な機能（項目列挙 + クリック）は実装可能

## ロードマップ

- **v0.4** (完了): 蔵 1 個方式で length 膨張による折りたたみ実装 + 右クリックメニューに「折りたたむ／展開する」追加 + 位置ベース対象スキャナ（全アプリの AXExtrasMenuBar を列挙して蔵座標と比較）+ RegistrationStore 廃止
- **v0.5**: ホットキー対応（Carbon `RegisterEventHotKey`）、開閉アニメーション、ノッチ裏アイコンの自動検出表示

## 未来の検討事項

- macOS のメジャーバージョンごとの AXUIElement 仕様変化への追従
- メニューバー項目がカスタムビュー実装の場合のフォールバック
- 多数アプリ起動時のパフォーマンス（lazy enumeration / AXObserver）
- アプリアイコンが取れない場合のフォールバック（汎用アイコン）
- 位置ベース設計移行時、ユーザーの並べ替え意図を尊重する優先度（例: 「お気に入り」を別 NSStatusItem で表示）
