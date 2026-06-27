import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, FoldController, NSPopoverDelegate {
    /// 蔵本体（左クリックでポップオーバー、右クリックでメニュー）
    private var statusItem: NSStatusItem!
    /// セパレータ（折りたたみ時に length 膨張、蔵の左に置かれる前提）
    private var separatorItem: NSStatusItem!
    private var popover: NSPopover!
    /// グローバルホットキー（デフォルト ⌃⌥⌘K で折りたたみ／展開トグル、環境設定で変更可）。
    /// アプリ寿命と同じライフタイムで保持し、プロセス終了時に OS が Carbon ホットキーを自動解除する。
    /// 環境設定からのカスタマイズは `handlePreferencesDidChange` で `update(keyCode:modifiers:)` を呼ぶ
    /// (差分判定は HotKeyManager 内部で行うため、無関係な設定変更通知でも安全に呼べる)。
    private var hotKeyManager: HotKeyManager?

    /// 蔵対象アプリの単一データソース。AppDelegate がスキャンの責任を持ち、
    /// 折りたたみ中も展開中も同じキャッシュを表示することで一貫性を保つ。
    /// **除外設定 (`AppExclusionStore`) を適用する前**の生スキャン結果を保持する。
    /// 除外解除 UX (環境設定の「対象アプリ」タブ) のため除外アプリも残し、
    /// VC への `setTargets` 直前に `visibleApps` 経由で除外を適用する。
    private var lastScanResult: [StatusBarApp] = []

    /// `lastScanResult` から除外設定を適用した popover 表示対象。
    /// AppOrderStore.applied → AppExclusionStore.filtered の順で適用される
    /// (lastScanResult が AppOrderStore.applied 済みなので、ここでは filter だけ)。
    private var visibleApps: [StatusBarApp] {
        AppExclusionStore.filtered(lastScanResult)
    }
    private var scanTask: Task<Void, Never>?
    /// 古い scan 完了が新しい結果を上書きしないよう世代管理する。
    /// startScan で +1、applyScanResult で世代一致のみ反映。
    private var scanGeneration: Int = 0
    /// 認可済み scan が一度でも成功したか。warmup の重複 kick をスキップするフラグ。
    /// 「lastScanResult が空でない」では正常な空 (.items([])) と未認可を区別できないため別フラグにする。
    private var didCompleteAuthorizedScan: Bool = false
    /// 直近の layout scan の生 result。`.items` 以外（未認可/キャンセル）なら最新の cache が
    /// 信用できない状態なので、折りたたみコミット時の判定に使う。
    private var lastLayoutScanResult: ScanLayoutResult?
    /// 折りたたみコミット待ち中フラグ。true の間は新規 scan kick を抑止し、
    /// 「待っている scan task が完了直後に別の scan に差し替わって commitFold が cache 未確定で走る」競合を防ぐ。
    private var isCommittingFold: Bool = false

    /// 起動時 fold (`PreferencesStore.foldOnLaunch`) 待ちフラグ。
    /// applicationDidFinishLaunching で snapshot し、初回 warmup scan 成功時に消化する。
    /// snapshot にしてあるのは、起動から warmup 完了までの間に環境設定で値を変えられても
    /// 「起動時の意図」を尊重するため (live read だと race して意図しない fold が走る)。
    private var pendingFoldOnLaunch: Bool = false

    /// 環境設定ウィンドウ。右クリックメニュー「環境設定…」から開かれた際に 1 インスタンスのみ生成し、
    /// 以降は再 show するだけ。閉じても release されないので state も保持される (`isReleasedWhenClosed = false`)。
    private var preferencesWindowController: PreferencesWindowController?

    /// popover を開いている間だけ生きる、他アプリでのマウス押下監視。
    /// `popover.behavior = .applicationDefined` にしているため自動 close は走らない。
    /// 外クリックでの close は本 monitor が担当する（NSDraggingSession 後も transient 動作が
    /// 壊れない、というのが手動制御を選んだ理由）。
    private var outsideClickMonitor: Any?

    private static let expandedSeparatorLength: CGFloat = 8
    /// 折りたたみ length は「現在繋がっている全画面の最大幅」で十分。
    /// 画面幅 × 2 を試したが macOS のメニューバー再レイアウトが重く感じる原因になっていた。
    /// 単一画面で 1710 → 半分に短縮、ノッチを跨ぐ場合も論理長さは画面幅で覆える。
    private static var collapsedSeparatorLength: CGFloat {
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        return max(500, min(screenWidth, 10_000))
    }

    var isFolded: Bool {
        separatorItem.length > Self.expandedSeparatorLength
    }

    /// 蔵アイコン用 SF Symbol の cache。設定変更時に `rebuildIconCache()` で再生成する。
    /// fold/expand 時 (高頻度) は cache を read するだけ、symbol 変更時 (低頻度) のみ build しなおす。
    private var expandedIcon: NSImage?
    private var foldedIcon: NSImage?
    /// 現在 cache 中の symbol。設定変更通知時に同じ symbol なら再 build を skip する判定に使う。
    private var lastBuiltSymbol: KuraSymbol?

    /// FoldController 実装。cache 不完全な項目クリック時の選択的自動展開で使われる。
    func expandIfFolded() {
        if isFolded {
            setSeparatorLength(Self.expandedSeparatorLength)
        }
    }

    /// 折りたたみ length 変更の単一 entry point。`separatorItem.length` 変更と蔵アイコン更新の
    /// 不変条件 (length が変わったら fold 状態判定が変わるので icon も追従) を 1 箇所に集約する。
    private func setSeparatorLength(_ length: CGFloat) {
        separatorItem.length = length
        updateStatusIcon()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Kura] launch: AXIsProcessTrusted=\(AccessibilityPermission.requestIfNeeded())")
        pendingFoldOnLaunch = PreferencesStore.foldOnLaunch
        rebuildIconCache()
        setupStatusItem()
        setupSeparatorItem()
        // 蔵アイコンの初期描画は両 setup 完了後に呼ぶ。
        // `updateStatusIcon` は `isFolded` → `separatorItem.length` を参照するため、
        // `setupStatusItem` 内で呼ぶと separatorItem (IUO) がまだ nil でクラッシュする。
        updateStatusIcon()
        setupPopover()
        setupHotKey()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreferencesDidChange),
            name: .kuraPreferencesDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleOtherAppActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // warmup scan を複数タイミングで kick。
        // AccessibilityPermission プロンプトに対応するため、ユーザーが許可するであろう
        // 時間帯に複数回試す。認可済み scan が一度成功したら以降はスキップ。
        // 初回 0.1s は権限許可済みユーザーの起動時 fold (foldOnLaunch) のラグ縮減用。
        // 既起動アプリの NSStatusItem は applicationDidFinishLaunching の時点で
        // 大半が AX 列挙可能、未完了分は 2/5/10s リトライで救う。
        for delay in [0.1, 2.0, 5.0, 10.0] as [Double] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.didCompleteAuthorizedScan else { return }
                self.startScan()
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "kura.main"
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // image / imagePosition は updateStatusIcon() が責任を持つ。
        // updateStatusIcon() 自体は applicationDidFinishLaunching で setupSeparatorItem 後に呼ぶ。
    }

    /// 蔵アイコン用 SF Symbol を現在の `PreferencesStore.symbol` から build して cache に積む。
    /// 起動時 (`applicationDidFinishLaunching`) と設定変更時 (`handlePreferencesDidChange`) に呼ぶ。
    /// fold/expand 自体は高頻度に走るため、`updateStatusIcon()` 内では cache を read するだけ。
    /// 同じ symbol で既に build 済みなら何もせず skip（foldOnLaunch / launchAtLogin 変更時の
    /// 無駄な NSImage 再生成を抑止）。
    /// SF Symbol が両方 load 失敗した場合は `lastBuiltSymbol` を update せず、
    /// 後の設定変更通知で再試行可能な状態に保つ（フォールバック状態に永続的に閉じ込められないため）。
    private func rebuildIconCache() {
        let symbol = PreferencesStore.symbol
        guard symbol != lastBuiltSymbol else { return }
        let expanded = Self.makeKuraIcon(systemName: symbol.expandedSymbolName, description: "蔵 (展開中)")
        let folded   = Self.makeKuraIcon(systemName: symbol.foldedSymbolName,   description: "蔵 (折りたたみ中)")
        expandedIcon = expanded
        foldedIcon   = folded
        if expanded != nil || folded != nil {
            lastBuiltSymbol = symbol
        }
    }

    private static func makeKuraIcon(systemName: String, description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// 蔵アイコンを現在の fold 状態に合わせて差し替える。
    /// 折りたたみ中: `.fill` バリアント（中に格納されている／閉じた印象）
    /// 展開中:       `.fill` なし（開いている／覗ける印象）
    /// 具体的な symbol は `PreferencesStore.symbol` で決まる（v0.7 環境設定 UI で選択可能）。
    /// `separatorItem.length` を変更した**後**に呼ぶこと（`isFolded` は length で判定するため）。
    /// SF Symbol load 失敗時は「蔵」テキストにフォールバック（最低限の視認性を保つ）。
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        if let icon = isFolded ? foldedIcon : expandedIcon {
            button.imagePosition = .imageOnly
            button.image = icon
        } else {
            NSLog("[Kura] updateStatusIcon: SF Symbol unavailable — fallback to text")
            button.image = nil
            button.imagePosition = .noImage
            button.title = "蔵"
            button.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        }
    }

    @objc private func handlePreferencesDidChange() {
        rebuildIconCache()
        // フォールバック状態 (SF Symbol load 失敗) から復帰できるよう、symbol 不変でも updateStatusIcon を呼ぶ。
        // updateStatusIcon は cache を read するだけなので低コスト。
        updateStatusIcon()
        // ホットキー再登録。差分判定は HotKeyManager.update 内部で行うので、無関係な通知 (symbol 変更等) でも安全に no-op。
        let hotKey = PreferencesStore.hotKey
        hotKeyManager?.update(keyCode: hotKey.keyCode, modifiers: hotKey.modifiers)
        // 除外リスト (`AppExclusionStore`) 変更時に popover の表示を再フィルタで更新する。
        // 環境設定ウィンドウから除外切り替え時、popover が開いていれば即時反映。
        // 通常は環境設定がフォアグラウンドで popover は閉じているが、念のための復帰経路。
        // scan は走らせない (除外切り替えに AX 走査は不要)。
        if !isFolded, popover.isShown, let vc = popover.contentViewController as? KuraViewController {
            vc.setTargets(visibleApps)
        }
    }

    /// 起動時 fold (`pendingFoldOnLaunch` snapshot) を、初回 warmup scan 成功直後に消化する。
    /// 呼び出し側 (`applyScanResult`) が「初回 true 遷移時のみ」呼ぶことを保証する。
    /// - セパレータが蔵の左にないと折りたためないため、その場合は静かに諦める（次回起動でリトライ）。
    /// - 既に手動展開／折りたたみ中なら何もしない（ユーザー操作を優先）。
    /// - performToggleFold(silent:) 経由: detail scan 失敗時に alert を出さない (起動直後の modal を回避)。
    private func consumeFoldOnLaunchIfNeeded() {
        guard pendingFoldOnLaunch else { return }
        pendingFoldOnLaunch = false
        guard !isFolded, isSeparatorOnLeftOfMain else {
            NSLog("[Kura] foldOnLaunch skipped (folded=\(isFolded) leftOfMain=\(isSeparatorOnLeftOfMain))")
            return
        }
        performToggleFold(silent: true)
    }

    private func setupSeparatorItem() {
        separatorItem = NSStatusBar.system.statusItem(withLength: Self.expandedSeparatorLength)
        separatorItem.autosaveName = "kura.separator"
        separatorItem.isVisible = true
        if let button = separatorItem.button {
            button.image = Self.separatorImage
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

    private static let separatorImage: NSImage = {
        let size = NSSize(width: 6, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let bar = NSRect(x: 2, y: 1, width: 2, height: 16)
        NSColor.black.setFill()
        bar.fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()

    private var isSeparatorOnLeftOfMain: Bool {
        guard let mainX = statusItem.button?.window?.frame.minX,
              let sepX = separatorItem.button?.window?.frame.minX else {
            return false
        }
        return sepX < mainX
    }

    @objc private func handleScreenParametersChanged() {
        if isFolded {
            setSeparatorLength(Self.collapsedSeparatorLength)
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        // 4 列グリッドの幅に合わせる。高さは AppKit が VC の intrinsic size から決める。
        popover.contentSize = NSSize(
            width: KuraViewController.preferredPopoverWidth,
            height: KuraViewController.preferredPopoverHeight
        )
        // `.transient` は内部で NSDraggingSession を回すと壊れるケースがあるため避ける（D&D 後に
        // 他アプリへフォーカスを移しても close が走らなくなる）。手動 close 制御に切り替え:
        //   - 蔵アイコン再クリック → togglePopover で close（既存）
        //   - 外クリック → outsideClickMonitor で close
        //   - 他アプリ activate → handleOtherAppActivated で close
        //   - メニュー項目発火 → onItemActivated で close
        popover.behavior = .applicationDefined
        popover.delegate = self
        let vc = KuraViewController()
        vc.onItemActivated = { [weak self] in
            self?.dismissPopover(reason: "menu item activated")
        }
        vc.onReorder = { [weak self] orderedBundleIds in
            guard let self = self else { return }
            // 現在 popover に見えていないアプリ（終了中 / 一時的に蔵対象外）の bundleId を失わないよう、
            // 既存の保存順のうち「現在表示中の bundleId に含まれないもの」を末尾に追加して merge する。
            // 不在アプリの絶対位置は保持されない（並び替えの度に末尾へ押し下げられる）が、bundleId は
            // 記憶されるため、再蔵入り時に「未知」扱いではなくユーザー指定順の末尾に並ぶ。
            let existing = AppOrderStore.load()
            let visible = Set(orderedBundleIds)
            let absent = existing.filter { !visible.contains($0) }
            AppOrderStore.save(orderedBundleIds + absent)
            // 次回 setTargets が古い順序を見せないよう、現在の cache も新順序で同期する。
            // scan が並走していても applyScanResult 側で AppOrderStore.load() を読み直すので
            // ここで保存と cache 更新を MainActor 上で原子的に済ませれば順序が逆戻りすることはない。
            self.lastScanResult = AppOrderStore.applied(to: self.lastScanResult)
        }
        vc.foldController = self
        popover.contentViewController = vc
    }

    /// 折りたたみ／展開トグルのグローバルホットキーを登録（デフォルト ⌃⌥⌘K、環境設定で変更可、詳細は ARCHITECTURE.md）。
    /// カスタマイズ時は `handlePreferencesDidChange` で `hotKeyManager.update(keyCode:modifiers:)` を呼ぶ。
    private func setupHotKey() {
        let hotKey = PreferencesStore.hotKey
        hotKeyManager = HotKeyManager(
            keyCode: hotKey.keyCode,
            modifiers: hotKey.modifiers
        ) { [weak self] in
            self?.toggleFold(nil)
        }
    }

    /// 非同期 scan。折りたたみ中は AX position が画面外で意味がないのでスキップ。
    /// 折りたたみコミット待ち中も新規 scan を抑止して競合を防ぐ。
    /// 完了時に lastScanResult を更新し、ポップオーバーが開いていれば反映する。
    /// 蔵の座標が取れない場合は scan を kick せず、再試行可能な状態を保持する
    /// （フォールバック値で kick すると filter が無効になり、cache を空で上書きしてしまうため）。
    private func startScan() {
        guard !isFolded, !isCommittingFold else { return }
        guard let window = statusItem.button?.window else { return }
        let kuraX = window.frame.minX
        // 蔵が乗っているスクリーンを特定。マルチディスプレイで「別画面の正常な要素」を
        // 誤って蔵対象にしてしまわないよう、scan 側のフィルタで使う。
        let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let kuraScreenFrame = screen?.frame else { return }
        // NSScreen.frame は AppKit 左下原点、kAXPositionAttribute は主画面左上原点 (Y 下向き) なので
        // scan で contains 判定するために AX 座標系へ変換する。
        let mainHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? screen!).frame.height
        let kuraScreenFrameInAX = CGRect(
            x: kuraScreenFrame.origin.x,
            y: mainHeight - kuraScreenFrame.origin.y - kuraScreenFrame.height,
            width: kuraScreenFrame.width,
            height: kuraScreenFrame.height
        )
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = MenuBarLayoutScanner.scanLeftOfKura(kuraX: kuraX, kuraScreenFrameInAX: kuraScreenFrameInAX)
            await self?.applyScanResult(result, generation: generation)
        }
    }

    private func applyScanResult(_ result: ScanLayoutResult, generation: Int) {
        // 古い scan 完了は無視。Task.cancel() は signal だけで中身は走り切るため、
        // 完了タイミングが入れ替わって新しい結果を上書きするのを防ぐ。
        guard generation == scanGeneration else { return }
        scanTask = nil
        lastLayoutScanResult = result
        let summary: String
        switch result {
        case .unauthorized:
            // 権限なし: 前回キャッシュを保護（空で上書きしない）
            summary = "unauthorized"
        case .cancelled:
            // 途中キャンセル: 結果は信用できないので何もしない
            summary = "cancelled"
        case .items(let apps, let failedBundleIds):
            // 部分成功を許容するマージ戦略:
            //   - 一時失敗 (failedBundleIds) の bundle は前回キャッシュから保持
            //   - ただし同じ bundleId が今回 apps にも入っているケース（同 bundleId 複数プロセス等）は
            //     重複を避けるため成功分を優先し、preserved 側で除外する
            let successBundles = Set(apps.map { $0.bundleIdentifier })
            let preservedFromCache = lastScanResult.filter {
                failedBundleIds.contains($0.bundleIdentifier) && !successBundles.contains($0.bundleIdentifier)
            }
            lastScanResult = AppOrderStore.applied(to: apps + preservedFromCache)
            // 一時失敗が残っている間は warmup を停止しない（起動直後の AX 不安定状態で
            // キャッシュ未確立のまま打ち切るのを防ぐ）。
            if failedBundleIds.isEmpty {
                let isFirstAuthorizedSuccess = !didCompleteAuthorizedScan
                didCompleteAuthorizedScan = true
                if isFirstAuthorizedSuccess {
                    consumeFoldOnLaunchIfNeeded()
                }
            }
            summary = "items(\(apps.count) failed=\(failedBundleIds.count) preserved=\(preservedFromCache.count))"
        }
        NSLog("[Kura] applyScanResult result=%@ lastScanResult=%d", summary, lastScanResult.count)
        // popover が開いていなくても VC に反映。
        // 次回ポップオーバー表示時に最新 cache が表示され、各 AppNode のメニュー詳細も
        // setTargets 内で事前 scan される（折りたたみ後の AX 制限を避ける目的）。
        if !isFolded, let vc = popover.contentViewController as? KuraViewController {
            vc.setTargets(visibleApps)
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            if let vc = popover.contentViewController as? KuraViewController {
                // 折りたたみ中も展開中も visibleApps (除外適用後) を表示。
                vc.setTargets(visibleApps)
                // 展開中だけ裏で scan を更新（ポップオーバー閉じる→開くで最新化）
                // startScan 内部で座標未取得時の guard があるため、ここでは無条件呼び出しでよい。
                if !isFolded {
                    startScan()
                }
            }
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        // popover を開いた状態で右クリックすると、`.applicationDefined` なので自動 close が走らず
        // popover とコンテキストメニューが同時に残り、その先で「折りたたむ」を選ぶと折りたたみ後も
        // popover が居座る。先に明示的に閉じておく。
        dismissPopover(reason: "context menu")

        // メニュー操作（数百 ms ある）の裏で scan を kick。
        // 「ポップオーバーを開かずに折りたたみ」の場合でも、cache 最新化を間に合わせる狙い。
        startScan()

        let menu = NSMenu()

        let foldTitle = isFolded ? "展開する" : "折りたたむ"
        let foldItem = NSMenuItem(title: foldTitle, action: #selector(toggleFold(_:)), keyEquivalent: "")
        foldItem.target = self
        if !isFolded && !isSeparatorOnLeftOfMain {
            foldItem.isEnabled = false
            foldItem.toolTip = "セパレータを蔵の左に ⌘+ドラッグしてから使ってください"
        }
        menu.addItem(foldItem)

        menu.addItem(.separator())

        // accessory app は mainMenu を持たないため、⌘, / ⌘Q をグローバルショートカットとして
        // 登録できない。keyEquivalent を表示すると「どこからでも使える」とユーザーを誤誘導するため空に。
        // menu 表示中のキーボード操作は矢印キー + Enter で行える。
        let prefsItem = NSMenuItem(title: "環境設定…", action: #selector(showPreferences(_:)), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Kura を終了", action: #selector(quit(_:)), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    /// ユーザー操作 (右クリックメニュー / ホットキー) からの折りたたみトグル。
    /// 失敗時には alert を出してユーザーに状況を伝える。
    @objc private func toggleFold(_ sender: Any?) {
        performToggleFold(silent: false)
    }

    /// `toggleFold` の本体。`silent: true` を渡すと folded 失敗時の alert を出さない。
    /// 起動時 fold (`consumeFoldOnLaunchIfNeeded`) からは silent で呼ぶ
    /// (ユーザー操作起点ではないため、起動直後に modal alert を出すと UX 不快)。
    private func performToggleFold(silent: Bool) {
        if isFolded {
            setSeparatorLength(Self.expandedSeparatorLength)
            return
        }
        guard isSeparatorOnLeftOfMain else { return }
        guard !isCommittingFold else { return }  // 二重起動防止
        // 初回起動直後・権限直後でまだ一度も scan が走っていなければ、ここで kick してから待つ。
        // （warmup scan を待たずに「折りたたむ」を選んだケースで alert を回避する）
        if scanTask == nil, lastLayoutScanResult == nil {
            startScan()
        }
        // 折りたたみ前に scan を全て完了させる:
        // 1. AppDelegate.scanTask（位置情報スキャン）
        // 2. KuraViewController の各 AppNode のメニュー詳細 scan
        //    Claude のような「メニューが画面外だと AX children を返さない」アプリの cache を
        //    折りたたみ前に確定させる必要がある（折りたたみ後だと AXPress も画面外で空振り）。
        // isCommittingFold = true で新規 scan kick を抑止し、scan task が差し替わる競合を防ぐ。
        isCommittingFold = true
        let foldStart = DispatchTime.now()
        let triggerLabel = silent ? "auto" : "manual"
        Task { @MainActor [weak self] in
            if let task = self?.scanTask {
                _ = await task.value
            }
            let layoutEnd = DispatchTime.now()
            var detailScansOk = true
            if let vc = self?.popover.contentViewController as? KuraViewController {
                detailScansOk = await vc.waitForAllScansAndCheckSuccess()
            }
            let detailEnd = DispatchTime.now()
            guard let self = self else { return }
            self.isCommittingFold = false
            // 最新の layout scan が .items かつ failedBundleIds が空（= 全アプリで scan 成功）の場合のみ
            // folded を許可。部分失敗 (failedBundleIds に bundleId が積まれている) では、その bundle が
            // 初回 scan なら cache 未確立で folded 後に操作不能になるため、ブロック。
            let layoutOk: Bool
            if case .items(_, let failedBundleIds) = self.lastLayoutScanResult {
                layoutOk = failedBundleIds.isEmpty
            } else {
                layoutOk = false
            }
            // 計測ログは success/fail 双方で出す (失敗時の latency も baseline として有用)。
            // ok ラベルで成功/失敗を区別できるよう format に含める。
            let layoutMs = Double(layoutEnd.uptimeNanoseconds - foldStart.uptimeNanoseconds) / 1_000_000
            let detailMs = Double(detailEnd.uptimeNanoseconds - layoutEnd.uptimeNanoseconds) / 1_000_000
            let resultLabel = (layoutOk && detailScansOk) ? "ok" : "blocked"
            NSLog("[Kura] foldTiming %@ %@ layout=%.0fms detail=%.0fms",
                  triggerLabel, resultLabel, layoutMs, detailMs)
            guard layoutOk, detailScansOk else {
                if !silent {
                    self.showFoldUnavailableAlert(layoutOk: layoutOk, detailOk: detailScansOk)
                }
                return
            }
            self.commitFold()
        }
    }

    private func showFoldUnavailableAlert(layoutOk: Bool, detailOk: Bool) {
        let reason: String
        if !layoutOk {
            reason = "アクセシビリティ権限を許可して、メニューバー走査が成功してから再度お試しください。"
        } else if !detailOk {
            reason = "対象アプリのメニュー走査に失敗しました。少し時間を置いて再度お試しください。"
        } else {
            reason = "折りたたみ前の確認に失敗しました。"
        }
        let alert = NSAlert()
        alert.messageText = "折りたためません"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if !layoutOk {
            alert.addButton(withTitle: "システム設定を開く")
        }
        let response = alert.runModal()
        if !layoutOk, response == .alertSecondButtonReturn {
            AccessibilityPermission.openSystemSettings()
        }
    }

    private func commitFold() {
        setSeparatorLength(Self.collapsedSeparatorLength)
        NSLog("[Kura] commitFold sepLen=%.0f lastScanResult=%d", separatorItem.length, lastScanResult.count)
    }

    @objc private func showPreferences(_ sender: Any?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        // 「対象アプリ」タブが scan 結果から行を構築するため、開く度に snapshot を渡す。
        // ウィンドウ表示中の scan 更新はここでは反映しない (環境設定を閉じて開き直しで最新化)。
        // リアルタイム更新は table の行追加/削除アニメーションが絡んで複雑なので MVP では避ける。
        preferencesWindowController?.setScanResult(lastScanResult)
        preferencesWindowController?.showWindow(nil)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    // MARK: - 手動 close 制御（NSPopoverDelegate + 外クリック / 他アプリ activate 監視）

    func popoverDidShow(_ notification: Notification) {
        startOutsideClickMonitor()
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitor()
    }

    private func startOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        // global monitor は他アプリで発生したマウス押下のみ受け取る（自アプリの popover 内クリックは
        // 通常通り popover の view に届く）。popover 外のどこをクリックしても close するシンプルな挙動。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.dismissPopover(reason: "outside click")
            }
        }
    }

    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// 他アプリへのフォーカス移動で popover を閉じる。global monitor だけだと「Cmd+Tab」など
    /// マウス経由でないアプリ切替を拾えないため併用する。
    @objc private func handleOtherAppActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        dismissPopover(reason: "other app activated")
    }

    /// popover を閉じる唯一の入口。外クリック / 他アプリ activate / 将来追加される条件（⎋ キー等）すべてここを通す。
    private func dismissPopover(reason: String) {
        guard popover.isShown else { return }
        NSLog("[Kura] dismiss popover: %@", reason)
        popover.performClose(nil)
    }
}
