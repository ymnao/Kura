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
├── AppDelegate.swift             NSStatusItem (本体 + セパレータ) / NSPopover の組み立て、折りたたみ、scan キャッシュ、ホットキー登録
├── KuraViewController.swift      ポップオーバーの NSOutlineView UI（表示専用）
├── MenuBarLayoutScanner.swift    全アプリの NSStatusItem 座標から蔵対象を列挙（StatusBarApp / ScanLayoutResult）
├── MenuBarScanner.swift          AXMenuBarItem 配下のメニューを 3 階層走査、単項目チェーン collapse
├── MenuBarDispatcher.swift       AXPress で項目を発火
├── MenuBarItem.swift             ScanResult / MenuBarItem 値型（children, isMenuItem を持つ階層構造）
├── AXHelpers.swift               AX (Accessibility) API の共有ラッパ
├── HotKeyManager.swift           Carbon RegisterEventHotKey でグローバルホットキーを登録
├── AppOrderStore.swift           popover 内の並び順を UserDefaults に永続化（bundleIdentifier 配列）
└── AccessibilityPermission.swift AX 権限の確認・要求・設定起動
```

## 折りたたみ方針（v0.4 で実装済み）

メニューバーアイコンの折りたたみは **NSStatusItem.length 膨張方式**（Hidden Bar / Vanilla / Dozer と同じ）で実装している。画面録画権限不要、アクセシビリティ権限すら不要で、NSStatusItem の `length` を巨大化することで、左隣のアイコンを画面外（ノッチ裏含む）に押し出して物理的に隠す。

### UI 構成 — 蔵本体 + セパレータの 2 NSStatusItem 方式

当初は「蔵 1 個方式」を目指したが、`NSStatusBarButton` の content（image/title）が**ボタンフレームの中央**に hard-coded で配置される仕様のため、`length` 膨張時に蔵自身が画面外に消える問題が発生。`imagePosition`、`alignment`、`attributedTitle.paragraphStyle`、巨大 NSImage、いずれも content を右端固定できず断念。

代わりに Hidden Bar と同じ **2 NSStatusItem 方式** を採用:

- **蔵本体** (`statusItem`): 通常 `variableLength`、常に右端側に表示。「蔵」テキスト表示
- **セパレータ** (`separatorItem`): 通常 `length=8`（薄い縦線アイコン）。折りたたみ時 `length=max(500, min(screenWidth, 10000))` で膨張、左隣のアイコンを押し出す（画面幅相当で十分。`screenWidth*2` だと OS のメニューバー再レイアウトが重い）

```
展開:  [Alfred][｜][蔵]            ← セパレータ length=8
折畳:                  [蔵]        ← セパレータ length≒screenWidth、その左は画面外
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
- Kura は `kAXPositionAttribute` で各 NSStatusItem のグローバルスクリーン座標 (CGPoint) を読み、蔵自身の座標と比較
- **蔵が乗っているスクリーンの `frame.contains(point)`（X/Y 両方）** かつ **蔵より左 (`p.x < kuraX`)** かつ **(0,0) でない（hidden item 除外）** のものを蔵対象として列挙
- 上下隣接ディスプレイは X 範囲が重なるため X だけで判定すると誤検出する。CGPoint 全体で frame contains 判定して別ディスプレイの正常な要素を確実に除外する
- **座標系の変換**: `kAXPositionAttribute` は主画面左上原点 (Y 下向き)、`NSScreen.frame` は AppKit 左下原点 (Y 上向き) なので、AppDelegate 側で AppKit→AX 変換した `kuraScreenFrameInAX` を渡す（`y = mainScreenHeight - frame.origin.y - frame.height`）。これを怠ると上下配置のマルチディスプレイで Y 範囲が反転して誤判定する
- 同じアプリが NSStatusItem を複数持ち、一部だけ蔵の左にあるケースに備え、`StatusBarApp.menuBarIndices` に「対象 NSStatusItem の AXExtrasMenuBar 内インデックス」を記録する。`MenuBarScanner.scan` はこの index で children をフィルタするので、折りたたみ中（対象アイコンが画面外で x≦0）でも正しい NSStatusItem だけを走査できる（位置依存しない識別）
- `StatusBarApp.menuBarItemCount` で AXExtrasMenuBar 子要素の総数を併用し、scan 時に children 数が一致しなければ layout drift として `.failed` を返す（折りたたみ中にアプリが NSStatusItem を追加/削除した場合の誤識別を防ぐ）
- ポップオーバーで各アプリの AXExtrasMenuBar 配下メニューを **3 階層 (AXMenu/AXMenuItem を再帰)** で表示
- **AXMenuItem を直接 AXPress** することで、対象アプリのアイコンを画面に戻さずアクション発火できる（折りたたみ中もアイコン非表示のまま操作可能）
- ただし一部のアプリ（例: Claude）は AX にメニュー情報を一切公開しない（AXMenuBarItem のみで children が空）。あるいは AXMenuItem まで取れても sub-menu が AX lazy loading で取れない。これらの場合 cache が「単一 leaf 項目」になるため `needsExpandToFire = true` を立てる
- `needsExpandToFire` の項目は UI に **「（折りたたみ非対応）」と表示** し、折りたたみ中はクリックを無効化する。展開時は通常通り AXPress で動作（メニュー UI がアイコン位置 = 画面内に開く）。「隠す」目的を保つため自動展開はしない — ユーザーが必要に応じて手動で「展開する」を選ぶフロー
- `MenuBarItem.statusItemElement` には親 AXMenuBarItem を保存しておき、`MenuBarDispatcher` が AXPress 時にこれを優先使用する。これにより展開時のクリックでアプリの本物 NSMenu が確実にアイコン位置に開く（個別 AXMenuItem への AXPress が失敗するアプリでも動作する）
- root レベルが単項目チェーン（例: アプリ直下に AXMenuBarItem 1 個だけ）の場合は短絡して、実質的なメニュー項目を AppNode 直下に昇格表示する
- **ノッチ裏アイコンへの操作**: M MacBook 系でノッチに隠れて視認できないアイコンも、`kAXPositionAttribute` は座標を返す（`(0,0)` でない、screen.frame 内、蔵より左の条件を満たす）ため、位置ベース設計の副産物として自動的に蔵対象に含まれる。視認できなくても popover からメニュー操作可能 — 「ノッチ裏アイコン操作」専用機能を別途実装する必要はない

これにより「擬似的に非表示」と「蔵に入っている」が**構造的に一致**する。RegistrationStore（明示的な登録設定）は v0.4 で廃止。

### スキャンタイミング

scan は **AppDelegate が単一データソースとして管理**（`lastScanResult`）:

- **起動時**: 0.5 / 2 / 5 / 10 秒後に warmup scan を kick（権限プロンプト中の遅延に対応、成功時は以降スキップ）
- **ポップオーバーを開く度**: 展開中なら裏で再 scan、結果は `lastScanResult` に反映
- **右クリックメニュー表示時**: scan を kick（メニュー操作の数百 ms の間に裏で完了させ、「折りたたむ」実行時に最新の cache がある状態を狙う）
- **scan 完了時**: ポップオーバーが閉じていても VC に反映し、`KuraViewController.setTargets` 内で全 AppNode のメニュー詳細 scan も事前 kick（折りたたみ中はアプリの AX children が取れない場合があるため、折りたたみ前の cache 化が重要）
- **`setTargets` の cache 戦略**: 展開中は呼ばれる度に cache をリセットして再 scan（最新化）。折りたたみ中は cache を保持し、再 scan しない（folded で AX children が取れないアプリの cache を破壊しないため）
- **折りたたみ時**: 進行中の scan task をすべて `await` で完了を待ってから `commitFold` で folded。
  - AppDelegate.scanTask（位置情報スキャン）
  - 各 AppNode の scanTask（メニュー詳細スキャン）
  - Claude のような「メニューが画面外だと AX children を返さない」アプリの cache を折りたたみ前に確定させる必要があるため両方を待つ
  - `isCommittingFold` フラグで折りたたみコミット待ち中は **新規 scan kick を抑止** し、待っている scan task が差し替わる競合を防ぐ。同じく toggleFold 自体も二重起動を防止
  - scan 完了後に「**最新の layout scan が `.items` かつ failedBundleIds が空**」「**全 AppNode の詳細 scan が `.items`**」の両方を確認。過去の成功フラグではなく直近の結果で判定するため、後から権限取り消しや一時失敗が起きた場合も folded をキャンセルし、alert でユーザーに通知。部分失敗 (failedBundleIds に bundle が積まれている) でも folded をブロック（初回 scan で失敗した bundle は cache 未確立のまま隠れて操作不能になるため）
- **世代管理**: `scanGeneration` で古い scan の完了が新しい結果を上書きしないよう守る
- **権限/キャンセル/部分成功の区別**: `ScanLayoutResult` は `.unauthorized` / `.cancelled` / `.items(apps, failedBundleIds)` を返す。`failedBundleIds` には AX 一時失敗 (`cannotComplete` 等) を起こした bundle が積まれ、AppDelegate 側で「失敗 bundle は前回キャッシュから保持、それ以外は新結果で置換」とマージする（同 bundleId が apps 側にも入っているケースでは重複を避けるため成功側を優先）。一時失敗が残る間は `didCompleteAuthorizedScan` を立てず warmup を継続する。これにより無関係なアプリの 1 件の不調で全体停止しないし、ユーザーが対象を蔵の右に移動した正常な反映も妨げない
- **scan 成功フラグ**: `didCompleteAuthorizedScan` を別に持ち、warmup の重複 kick をスキップ（「lastScanResult が空」では正常な空と未認可を区別できないため）
- **キャンセル協調**: `scanLeftOfKura` は loop 内で `Task.isCancelled` を確認し、cancel signal を受けたら早期 `.cancelled` を返す

AX 呼び出しは `messagingTimeout = 1.0` 秒で同期だが、`Task.detached` で実行するためメインスレッドはブロックされない。

## グローバルホットキー（v0.5 で実装）

折りたたみ／展開のトグルを **⌃⌥⌘K** （Ctrl+Option+Cmd+K）で発火できる。

### 実装手段の選定

| 手段 | 必要権限 | 採用 |
|---|---|---|
| Carbon `RegisterEventHotKey` | 不要 | ◯ |
| `NSEvent.addGlobalMonitorForEvents` | アクセシビリティ | × |
| `CGEventTap` | アクセシビリティ + 入力監視 | × |

Carbon `RegisterEventHotKey` は deprecated ではなく、macOS 14 でも安定動作する。権限プロンプトが増えないのが大きな利点。

### `HotKeyManager` の役割

- `init(keyCode:modifiers:handler:)` でホットキーを登録。アプリ寿命と同じライフタイムなので `UnregisterEventHotKey` は呼ばず、プロセス終了時に OS が自動解除する設計（Swift 6 では `@MainActor` class の nonisolated deinit から non-Sendable な `EventHotKeyRef` を触れないため、deinit 自体を持たない）
- 単一ホットキー前提（Kura は ⌃⌥⌘K のみ使用）。複数ホットキーが必要になった時点で registry / ID 払い出しを足すのは trivial なので、現状は最小構成にしている
- Carbon C callback は MainActor 隔離外で発火するため、`nonisolated static func dispatchHotKeyEvent(_:)` で受け、`DispatchQueue.main.async` + `MainActor.assumeIsolated` で MainActor に戻してから登録済みクロージャを呼ぶ
- 保存する handler 型は `@MainActor () -> Void` を明示し、MainActor 隔離下でしか呼べないことを型レベルで強制
- `EventHotKeyID` の `signature='KURA'` + `id=1` で「Kura が登録したホットキー」だけを照合する。Carbon `RegisterEventHotKey` は非排他登録（同じキーを複数アプリが登録でき、各アプリに通知される）なので、誤発火防止のための識別子チェックは callback 側に必要

### ホットキーから `toggleFold(_:)` を呼ぶ設計

ホットキーハンドラは AppDelegate の既存 `toggleFold(_:)` をそのまま呼ぶ。scan 待ち・セパレータ位置チェック・alert 表示などの折りたたみコミット手順は右クリックメニュー経由と完全に同じ。

セパレータが蔵の左にない場合は `toggleFold` が早期 `return` でサイレント無視する（右クリックメニューでは disabled + tooltip だが、ホットキーでは現状フィードバックなし）。実用上は初回セットアップ時のみのケースなので許容。

## 並び替え永続化（v0.6 で実装）

popover 内に表示される蔵対象アプリの **並び順を D&D で並び替え、UserDefaults に永続化** する。menubar 上の物理位置はそのまま（他アプリの NSStatusItem は移動できないため）、popover 上の表示順だけをユーザー指定順に固定する。

### 永続化形式

`UserDefaults` キー `"kura.appOrder"` に **`[bundleIdentifier]`** (String 配列) を保存。`AppOrderStore.load()` / `.save(_:)` の薄いラッパだけ持ち、シングルトン化やキャッシュは無し。

保存時は **既存の保存順と merge** する: `AppDelegate.onReorder` ハンドラが「現在 popover に見えている bundleId（= 並び替えた新順序）」+「既存保存順のうち今見えていない bundleId（= 終了中 / 一時的に蔵対象外）」を連結して `save`。不在アプリの絶対位置は保持されない（並び替えの度に末尾へ押し下げられる）が、bundleId は記憶されるため、再蔵入り時に「未知」扱いではなくユーザー指定順の末尾に並ぶ。例: 保存順 `[A, B, C]` で表示中 `[A, C]` を `[C, A]` に並び替えると、保存順は `[C, A, B]` になる（B は末尾に押し下げ）。

`AppOrderStore.applied(to:)` の `indexMap` 構築は手動編集や将来の保存経路追加で重複 bundleId が入っても trap せず先勝ちで採用する。

### D&D の実装

`KuraViewController` の `NSOutlineView` に `NSOutlineViewDataSource` のドラッグ系メソッドを実装:

- `pasteboardWriterForItem`: **AppNode 行のみ** ドラッグ可。`NSPasteboardItem` に bundleId を string で乗せる（ローカルペーストボード型 `"kura.appRow"`）
- `validateDrop`: root レベル（`item == nil`）の「行間」（`index >= 0`）を許可、`.move` を返す。AppNode 行への「上」へのドロップ（`index == NSOutlineViewDropOnItemIndex`）は `setDropItem(nil, dropChildIndex: row)` で **その行の前の root gap に再解釈** する（AppNode は `isItemExpandable=true` のため AppKit が「子として追加」と解釈してくるが、子はメニュー項目で並び替え対象ではないため書き換える）。AppNode 以外の子（メニュー項目位置）は弾く
- `acceptDrop`: pasteboard から bundleId を取り出し、`appNodes` 配列内で参照を引き直して再構築 → `reloadData` → `onReorder` コールバック発火
- `outlineView.draggingDestinationFeedbackStyle = .regular`（デフォルト）。`.gap` は AppNode が `isItemExpandable=true` の場合に行間 index 計算が不安定（常に 0 になる）症状があったため使わない。`.regular` だと AppNode 上に行ハイライトが出るが、上記の `setDropItem` 再解釈で並び替えとして機能する
- `NSOutlineView` のドラッグソース側の operation mask はデフォルトで `.move` を含まないため、`ReorderableOutlineView` という小さなサブクラスで `draggingSession(_:sourceOperationMaskFor:)` を `.move` にオーバーライド（これがないと `validateDrop` で `.move` を返してもドロップが成立しない）

### 復元と適用

`AppOrderStore.applied(to:)` が scan 結果のソート時に保存順を適用:

- 保存順に登場する bundleId は順序通り前方
- 未登録の bundleId は末尾に `leftmostX` 順（新規アプリは物理位置で末尾追加）
- 保存順が空（初回起動や永続化前）の場合は従来通り `leftmostX` 順

`applyScanResult` 内の `(apps + preservedFromCache).sorted { $0.leftmostX < $1.leftmostX }` を `AppOrderStore.applied(to:)` に置換。保存形式と「未知 bundleId は末尾」の適用ロジックを 1 ファイル（`AppOrderStore`）に集約することで、形式変更時の同期コストを排除する。

### 並走 scan との競合回避

D&D 完了 → 並走 scan 完了の順で起きる場合の対策:

1. ユーザーが D&D → `acceptDrop` で `appNodes` 配列再構築 → `onReorder?(新bundleIds)` を **同期で呼び出し**
2. `AppDelegate.onReorder` ハンドラが MainActor 上で「既存保存順との merge → `AppOrderStore.save` → `self.lastScanResult = AppOrderStore.applied(to: self.lastScanResult)`」を一気に実行
3. 並走 scan が完了 → `applyScanResult` で `AppOrderStore.applied(to:)` が内部で `load()` を読む → 新順序を適用 → `setTargets` で VC が新順序で reload

MainActor 上で原子的に save と cache 更新が走るため、次回 `setTargets` が古い順序を見せることはない。

## 制約と妥協

- **他アプリのメニューバーアイコン画像は使えない** — Dock/Finder のアプリアイコンで代用
- **アイコンの自動再配置はできない** — `kAXPositionAttribute` は読めるが、他アプリの NSStatusItem には書けない（`isAttributeSettable` が false）。ユーザーが ⌘+ドラッグで手動配置
- **macOS システム純正アイコン（時計・コントロールセンター等）は隠せない** — 蔵より右端側に固定配置されているため
- **新規 NSStatusItem は既存項目の左に出現する**（macOS 11+ 仕様、autosaveName で位置記憶しているアプリは前回位置）— 位置ベース設計では「新規アプリが自動的に蔵入り」する挙動になる
- **NSStatusItem の同 count 入れ替えは検出できない** — AX レイヤーには NSStatusItem の安定した identity がない。`AXTitle`/`AXDescription` は表示として正常に変化する（時刻、進捗、未読数等）ため fingerprint に使えず、`AXIdentifier` を設定しているアプリは少ない。fail-safe として「複数 NSStatusItem を持ち一部だけ対象」のアプリでは `isExecutable = false` で AXPress を抑止する（メニュー項目は disabled 表示）。「NSStatusItem 1 個のみ」または「全 NSStatusItem が対象」のアプリは並び替えがあっても安全なので通常通り操作可能
- **同 bundleId の複数プロセスは非対応** — `byBundle` / `nodeCache` が bundleId キーのため、2 プロセス目以降は静かに上書きされる。実用上ほぼ無いケースとして許容

## なぜ画面録画権限を避けるのか

- ユーザーの心理的抵抗が大きい
- macOS Sonoma 以降、画面録画中は紫バッジが出るため UX を損なう
- 「メニューバー管理」と「画面録画」の権限粒度が一致しない
- アクセシビリティ権限だけで本質的な機能（項目列挙 + クリック）は実装可能

## ロードマップ

- **v0.4** (完了): セパレータ方式の折りたたみ実装（2 NSStatusItem）+ 右クリックメニューに「折りたたむ／展開する」追加 + 位置ベース対象スキャナ + 3 階層メニュー走査と単項目チェーン collapse + RegistrationStore 廃止
- **v0.5** (完了): グローバルホットキー（⌃⌥⌘K、Carbon `RegisterEventHotKey`）
  - 開閉アニメーション: `length` 補間方式を試したが、毎フレームのメニューバー再レイアウトコストで体感が重く廃止（[#6](https://github.com/ymnao/Kura/pull/6) close 済み）
  - ノッチ裏アイコン操作: v0.4 の位置ベース設計の副産物として実現済み（上記「対象アプリの選定」参照）
- **v0.6** (進行中): 蔵対象アプリの並び替え永続化（popover で D&D、`UserDefaults "kura.appOrder"` に bundleId 配列を保存）+ シンプルな UI/UX 改善（順次）

## 未来の検討事項

- macOS のメジャーバージョンごとの AXUIElement 仕様変化への追従
- メニューバー項目がカスタムビュー実装の場合のフォールバック
- 多数アプリ起動時のパフォーマンス（lazy enumeration / AXObserver）
- アプリアイコンが取れない場合のフォールバック（汎用アイコン）
- 位置ベース設計移行時、ユーザーの並べ替え意図を尊重する優先度（例: 「お気に入り」を別 NSStatusItem で表示）
