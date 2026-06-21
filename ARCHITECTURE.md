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
├── main.swift                    エントリポイント
├── AppDelegate.swift             NSStatusItem / NSPopover の組み立て
├── KuraViewController.swift      ポップオーバーの NSOutlineView UI
├── SettingsViewController.swift  設定ウィンドウ（登録アプリ管理）
├── MenuBarScanner.swift          AXUIElement で他アプリの項目を列挙
├── MenuBarDispatcher.swift       AXPress で項目を発火
├── MenuBarItem.swift             ScanResult / MenuBarItem 値型
├── AccessibilityPermission.swift AX 権限の確認・要求・設定起動
└── RegistrationStore.swift       登録アプリの永続化（UserDefaults）
```

## 折りたたみ方針（v0.4 以降）

メニューバーアイコンの折りたたみは **NSStatusItem.length 膨張方式**（Hidden Bar / Vanilla / Dozer と同じ）で実装する。画面録画権限不要、アクセシビリティ権限すら不要で、自分の NSStatusItem の `length` を巨大化することで、左隣のアイコンを画面外（ノッチ裏含む）に押し出して物理的に隠す。

```
[隠したいアイコン群]  [≡セパレータ(蔵)]  [メイン蔵]
                       ↑ length=4000 にすると左が画面外
```

### 対象アプリの選定 — 位置ベース

「蔵に入れる対象アプリ」のリストは持たず、**セパレータより左にある NSStatusItem = 蔵の対象** と定義する。

- ユーザーが ⌘+ドラッグで隠したいアイコンをセパレータ左に置く
- Kura は `kAXPositionAttribute` で各 NSStatusItem の座標を読み、セパレータの座標と比較
- セパレータより左にあるアプリを自動で蔵対象として列挙し、メニュー項目を AXPress で発火

これにより「擬似的に非表示」と「蔵に入っている」が**構造的に一致**する（位置が定義そのもの）。RegistrationStore（明示的な登録設定）は将来この設計に置き換える予定。

## 制約と妥協

- **他アプリのメニューバーアイコン画像は使えない** — Dock/Finder のアプリアイコンで代用
- **アイコンの自動再配置はできない** — `kAXPositionAttribute` は読めるが、他アプリの NSStatusItem には書けない（`isAttributeSettable` が false）。ユーザーが ⌘+ドラッグで手動配置
- **macOS システム純正アイコン（時計・コントロールセンター等）は隠せない** — Kura のセパレータより右端側に固定配置されているため
- **新規 NSStatusItem は既存項目の左に出現する**（macOS 11+ 仕様、autosaveName で位置記憶しているアプリは前回位置）— 位置ベース設計では「新規アプリが自動的に蔵入り」する挙動になる

## なぜ画面録画権限を避けるのか

- ユーザーの心理的抵抗が大きい
- macOS Sonoma 以降、画面録画中は紫バッジが出るため UX を損なう
- 「メニューバー管理」と「画面録画」の権限粒度が一致しない
- アクセシビリティ権限だけで本質的な機能（項目列挙 + クリック）は実装可能

## ロードマップ

- **v0.4**: セパレータ NSStatusItem 実装（length 膨張で折りたたみ） + 位置ベース対象スキャナ（全アプリの AXExtrasMenuBar を列挙してセパレータ座標と比較） + RegistrationStore 廃止
- **v0.5**: ホットキー対応（Carbon `RegisterEventHotKey`）、開閉アニメーション、ノッチ裏アイコンの自動検出表示

## 未来の検討事項

- macOS のメジャーバージョンごとの AXUIElement 仕様変化への追従
- メニューバー項目がカスタムビュー実装の場合のフォールバック
- 多数アプリ起動時のパフォーマンス（lazy enumeration / AXObserver）
- アプリアイコンが取れない場合のフォールバック（汎用アイコン）
- 位置ベース設計移行時、ユーザーの並べ替え意図を尊重する優先度（例: 「お気に入り」を別 NSStatusItem で表示）
