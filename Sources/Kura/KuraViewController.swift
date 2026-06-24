import AppKit

/// AppDelegate に折りたたみ状態を問い合わせ、必要に応じて展開を要求するための contract。
@MainActor
protocol FoldController: AnyObject {
    var isFolded: Bool { get }
    /// AX cache 不完全な項目（needsExpandToFire）クリック時の選択的自動展開で使用。
    func expandIfFolded()
}

/// MainActor 上でのみ生成・更新される。scan の Task.detached には AppNode 自体を渡さず、
/// 値型の StatusBarApp と generation だけを渡し、完了時に bundleId で再 lookup する設計。
/// 自身が解放される時に scanTask を自動キャンセルすることで、KuraViewController.deinit から
/// nodeCache を触る必要をなくす（nonisolated deinit から @MainActor property を触る Swift 6 エラーを回避）。
final class AppNode {
    let app: StatusBarApp
    var result: ScanResult?
    var scanTask: Task<Void, Never>?
    var scanGeneration: Int = 0

    init(_ app: StatusBarApp) {
        self.app = app
    }

    deinit {
        scanTask?.cancel()
    }
}

@MainActor
final class KuraViewController: NSViewController {
    private let gridView = IconGridView()
    private let scrollView = NSScrollView()
    private let emptyLabel = makeCursorlessLabel("")
    private let bannerContainer = NSView()
    private let bannerLabel = makeCursorlessLabel("⚠ アクセシビリティ未許可")
    private let bannerButton = NSButton()
    private var bannerHeightConstraint: NSLayoutConstraint!

    private var appNodes: [AppNode] = []
    private var nodeCache: [String: AppNode] = [:]
    /// アイコンクリック時の scan 待ち Task の世代トークン。クリック時に +1 し、Task 完了時に
    /// 「最新の request か」を比較して古い request の menu 表示を抑止する。popover 閉鎖 / 別アイコン
    /// クリック / 外側クリック / D&D 開始 後に遅れて menu が出るのを防ぐ。
    private var pendingMenuRequestID: UInt64 = 0

    var onItemActivated: (() -> Void)?
    /// AppNode の並び替え完了時に呼ばれる。引数は新しい順序の bundleIdentifier 配列。
    var onReorder: (([String]) -> Void)?
    weak var foldController: FoldController?

    /// IconView 間で共有する drag pasteboard 型。bundleIdentifier を string で乗せる。
    static let dragType = NSPasteboard.PasteboardType("kura.appRow")

    static let cellSize = NSSize(width: 44, height: 44)
    static let iconSize: CGFloat = 32
    static let columns = 4
    static let gridGap: CGFloat = 8
    static let gridPadding: CGFloat = 4
    static let contentHorizontalPadding: CGFloat = 12

    /// popover の幅を決める固定値。`AppDelegate` 側の `popover.contentSize` と整合させる。
    static var preferredPopoverWidth: CGFloat {
        let grid = CGFloat(columns) * cellSize.width
            + CGFloat(columns - 1) * gridGap
            + gridPadding * 2
        return grid + contentHorizontalPadding * 2
    }

    /// popover の初期高さ。実際の高さは `IconGridView.intrinsicContentSize` で再計算され、
    /// アイコン数に追従する。この値は最初の 1 フレームの見た目を安定させる目的のみ。
    static let preferredPopoverHeight: CGFloat = 240

    override func loadView() {
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: Self.preferredPopoverWidth,
            height: Self.preferredPopoverHeight
        ))

        let title = makeCursorlessLabel("蔵")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        bannerContainer.wantsLayer = true
        bannerContainer.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        bannerContainer.layer?.cornerRadius = 6
        bannerContainer.clipsToBounds = true
        bannerContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bannerContainer)

        bannerLabel.font = NSFont.systemFont(ofSize: 11)
        bannerLabel.textColor = .secondaryLabelColor
        bannerLabel.lineBreakMode = .byTruncatingTail
        bannerLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerContainer.addSubview(bannerLabel)

        bannerButton.title = "設定を開く"
        bannerButton.bezelStyle = .rounded
        bannerButton.controlSize = .small
        bannerButton.target = self
        bannerButton.action = #selector(openAccessibilitySettings(_:))
        bannerButton.translatesAutoresizingMaskIntoConstraints = false
        bannerContainer.addSubview(bannerButton)

        bannerHeightConstraint = bannerContainer.heightAnchor.constraint(equalToConstant: 0)
        bannerHeightConstraint.isActive = true

        gridView.translatesAutoresizingMaskIntoConstraints = false
        gridView.onReorder = { [weak self] from, to in
            self?.handleReorder(from: from, to: to)
        }

        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = gridView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // NSScrollView は documentView に自動で constraint を貼らないので、明示的に bind する。
        // 幅は clipView 幅に固定（縦スクロール専用）、高さは `IconGridView.intrinsicContentSize` で決まる。
        // これがないと documentView の frame が伸びず、アイコンが popover 高さを超えた行はスクロールできない。
        NSLayoutConstraint.activate([
            gridView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            gridView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            gridView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        emptyLabel.stringValue = "蔵の左にアイコンがありません\n\n隠したいメニューバーアイコンを\n蔵の左側にドラッグしてください"
        emptyLabel.font = NSFont.systemFont(ofSize: 11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            separator.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.contentHorizontalPadding),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.contentHorizontalPadding),
            separator.heightAnchor.constraint(equalToConstant: 1),

            bannerContainer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            bannerContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.contentHorizontalPadding),
            bannerContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.contentHorizontalPadding),

            bannerLabel.leadingAnchor.constraint(equalTo: bannerContainer.leadingAnchor, constant: 10),
            bannerLabel.centerYAnchor.constraint(equalTo: bannerContainer.centerYAnchor),
            bannerLabel.trailingAnchor.constraint(lessThanOrEqualTo: bannerButton.leadingAnchor, constant: -8),

            bannerButton.trailingAnchor.constraint(equalTo: bannerContainer.trailingAnchor, constant: -8),
            bannerButton.centerYAnchor.constraint(equalTo: bannerContainer.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: bannerContainer.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.contentHorizontalPadding),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.contentHorizontalPadding),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])

        view = container
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updatePermissionBanner()
    }

    /// popover 閉鎖時に pending な scan 待ち request を全部 invalidate する。
    /// これがないと「クリック → scan 待ち中に popover を閉じる → 再オープン」で
    /// 古いリクエストが生き残り、再オープン後に意図しない menu が出る。
    override func viewDidDisappear() {
        super.viewDidDisappear()
        pendingMenuRequestID &+= 1
    }

    /// 進行中の全 AppNode のメニュー詳細 scan が完了するまで待ち、すべて .items（成功）かを返す。
    /// 折りたたみコミット前の判定に使う: いずれかが .failed/.notRunning なら cache 不完全のまま
    /// folded すると蔵から操作できなくなるため、folded をキャンセルすべき。
    func waitForAllScansAndCheckSuccess() async -> Bool {
        let tasks = appNodes.compactMap { $0.scanTask }
        for task in tasks {
            _ = await task.value
        }
        for node in appNodes {
            switch node.result {
            case .items: continue
            case .failed, .notRunning, nil: return false
            }
        }
        return true
    }

    /// AppDelegate から「これを表示せよ」と渡される。VC は scan しない。
    /// 折りたたみ中はメニュー詳細を取り直さない（アイコンが画面外で AX children が取れない
    /// アプリの cache を破壊しないため）。展開中のみ cache をリフレッシュして最新化する。
    func setTargets(_ apps: [StatusBarApp]) {
        loadViewIfNeeded()
        updatePermissionBanner()
        let folded = foldController?.isFolded ?? false
        appNodes = apps.map { app in
            let cached = nodeCache[app.bundleIdentifier]
            let node: AppNode
            if let cached, cached.app == app {
                node = cached
                if !folded {
                    node.scanTask?.cancel()
                    node.scanTask = nil
                    node.scanGeneration &+= 1
                    node.result = nil
                }
            } else {
                cached?.scanTask?.cancel()
                node = AppNode(app)
            }
            nodeCache[app.bundleIdentifier] = node
            return node
        }
        let activeIds = Set(apps.map { $0.bundleIdentifier })
        for (key, node) in nodeCache where !activeIds.contains(key) {
            node.scanTask?.cancel()
            nodeCache.removeValue(forKey: key)
        }
        let iconViews = appNodes.map { node -> IconView in
            let v = IconView(app: node.app)
            v.onClick = { [weak self] tapped in
                self?.handleIconClick(view: tapped)
            }
            v.onDragStart = { [weak self] _ in
                // D&D 開始で pending な click menu request を invalidate。drop の有無に関わらず、
                // drag を始めた時点で click 意図は捨てる。
                self?.pendingMenuRequestID &+= 1
            }
            return v
        }
        gridView.setIcons(iconViews)
        emptyLabel.isHidden = !appNodes.isEmpty
        // 折りたたみ中はアプリのアイコンが画面外で AX children を取得できないアプリが
        // 存在する（メニューを開いた時にしか children を提供しないアプリ等）。
        // 折りたたみ前の今のうちに全 AppNode のメニュー詳細を scan して cache 化しておく。
        if !folded {
            for node in appNodes {
                scanIfNeeded(node)
            }
        }
    }

    private func updatePermissionBanner() {
        bannerHeightConstraint.constant = AccessibilityPermission.isTrusted ? 0 : 32
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        AccessibilityPermission.openSystemSettings()
    }

    private func scanIfNeeded(_ node: AppNode) {
        guard node.result == nil, node.scanTask == nil else { return }
        let generation = node.scanGeneration
        let app = node.app
        node.scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = MenuBarScanner.scan(app)
            await self?.handleScanCompletion(app: app, generation: generation, result: result)
        }
    }

    private func handleScanCompletion(app: StatusBarApp, generation: Int, result: ScanResult) {
        guard let node = nodeCache[app.bundleIdentifier],
              node.app == app,
              node.scanGeneration == generation else { return }
        node.scanTask = nil
        node.result = result
        // 表示はクリック時に NSMenu を組み直すので、ここでは何もしない。
    }
}

// MARK: - クリック → NSMenu

extension KuraViewController {
    fileprivate func handleIconClick(view: IconView) {
        // 待機中に setTargets が走って node / view が差し替わるケースに対応するため、bundleId だけ
        // 捕まえて await 後に最新を引き直す。view 引数の直接保持は避ける（差し替わると stale になる）。
        let bundleId = view.app.bundleIdentifier
        pendingMenuRequestID &+= 1
        let requestID = pendingMenuRequestID
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            // scan task の完了を待つ。途中で別の scan が kick されたら（setTargets で世代更新）
            // 再 lookup して新しい task を待つ。最大 3 回までで諦める（無限ループ防止）。
            // node の取り直しは `nodeCache[bundleId]` で O(1)（`setTargets` で appNodes と同期更新されている）。
            for _ in 0..<3 {
                guard self.pendingMenuRequestID == requestID,
                      let node = self.nodeCache[bundleId]
                else { return }
                self.scanIfNeeded(node)
                if let task = node.scanTask {
                    _ = await task.value
                    continue
                }
                break
            }
            // 最新の request か、view がまだ window に乗っているかを最終確認。
            // popover 閉鎖 / 別アイコンクリック / 外側クリック / D&D 開始 で dismiss された場合は古い request
            // → 表示しない。`result != nil` && `scanTask == nil` で「読込中…だけの menu」を回避
            // (loop 後も未完了なら表示しない、次回クリックでリトライ)。
            guard self.pendingMenuRequestID == requestID,
                  let node = self.nodeCache[bundleId],
                  node.scanTask == nil,
                  node.result != nil,
                  let currentView = self.gridView.iconView(forBundleId: bundleId),
                  currentView.window != nil
            else { return }
            // folded はクリック時点でなく menu 表示直前に取得。scan 待ち中にホットキー (⌃⌥⌘K) で
            // 折りたたみ状態が変わると `needsExpandToFire` / `!isMenuItem` の enable/disable 判定が
            // 古くなって誤った menu が出るため。
            let folded = self.foldController?.isFolded ?? false
            self.presentMenu(for: node, folded: folded, anchor: currentView)
        }
    }

    private func presentMenu(for node: AppNode, folded: Bool, anchor view: IconView) {
        let menu = buildMenu(for: node, folded: folded)
        // セル直下に NSMenu を popUp。popover は閉じない。
        let location = NSPoint(x: 0, y: view.bounds.maxY + 2)
        menu.popUp(positioning: nil, at: location, in: view)
    }

    private func buildMenu(for node: AppNode, folded: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch node.result {
        case nil:
            menu.addItem(disabledItem(title: "読込中…"))
        case .notRunning:
            menu.addItem(disabledItem(title: "起動していません"))
        case .failed(let reason):
            menu.addItem(disabledItem(title: "走査失敗: \(reason)"))
        case .items(let items) where items.isEmpty:
            menu.addItem(disabledItem(title: "メニュー項目なし"))
        case .items(let items):
            for child in items {
                menu.addItem(buildMenuItem(for: child, folded: folded))
            }
        }
        return menu
    }

    private func buildMenuItem(for item: MenuBarItem, folded: Bool) -> NSMenuItem {
        if !item.children.isEmpty {
            let parent = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for child in item.children {
                submenu.addItem(buildMenuItem(for: child, folded: folded))
            }
            parent.submenu = submenu
            return parent
        }
        let title: String
        let enabled: Bool
        if item.needsExpandToFire {
            title = "\(item.title)（折りたたみ非対応）"
            enabled = !folded && item.isExecutable
        } else if !item.isExecutable {
            title = item.title
            enabled = false
        } else if folded && !item.isMenuItem {
            title = item.title
            enabled = false
        } else {
            title = item.title
            enabled = true
        }
        let nsItem = NSMenuItem(title: title, action: #selector(menuItemActivated(_:)), keyEquivalent: "")
        nsItem.target = self
        nsItem.representedObject = item
        nsItem.isEnabled = enabled
        return nsItem
    }

    private func disabledItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func menuItemActivated(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MenuBarItem else { return }
        NSLog("[Kura] menu activate: %@", item.title)
        onItemActivated?()
        MenuBarDispatcher.press(item)
    }
}

// MARK: - 並び替え

extension KuraViewController {
    fileprivate func handleReorder(from oldIndex: Int, to newIndex: Int) {
        guard oldIndex != newIndex,
              appNodes.indices.contains(oldIndex),
              appNodes.indices.contains(newIndex) else { return }
        let node = appNodes.remove(at: oldIndex)
        appNodes.insert(node, at: newIndex)
        let newOrder = appNodes.map { $0.app.bundleIdentifier }
        NSLog("[Kura] reorder applied %d→%d", oldIndex, newIndex)
        onReorder?(newOrder)
    }
}

// MARK: - IconView

/// アプリアイコン 1 個のセル。
/// - cursor 切替は `resetCursorRects` + `addCursorRect(.pointingHand)` の AppKit 標準ルートで実装。
///   `mouseMoved.set()` / `cursorUpdate.set()` / push/pop は AppKit 内部の cursor 評価ループと
///   競合してちらつきを生むため使わない。
/// - アイコン描画は `NSImageView` ではなく `CALayer.contents` で行う。`NSImageView` (cell-based view)
///   は内部で cursor rect を登録する経路を持っていて、IconView の `pointingHand` を上書きして
///   I-beam 等の不正な cursor が表示される根本原因になっていた。
/// - `mouseDown/Dragged/Up` で「クリック」「ドラッグ」を自前判定。ドラッグ開始は `beginDraggingSession`。
/// - drag 中の `closedHand` は `NSCursor.closedHand.push()` / `pop()` で cursor stack に積む。
/// - `hitTest` を override して subview への hit を打ち切り、cursor rect と mouseDown を IconView に集める。
final class IconView: NSView, NSDraggingSource {
    let app: StatusBarApp
    /// クリック時のコールバック。delegate protocol だと「メソッド 1 個 / 利用箇所 1 か所」で過剰なので
    /// 同ファイル内の `onItemActivated` / `onReorder` と同じ closure パターンで統一する。
    var onClick: ((IconView) -> Void)?
    /// ドラッグ開始時のコールバック。VC 側で「scan 待ち中の click menu request」を invalidate するために
    /// 使う（D&D は別操作なので、その時点で pending な click は捨てるべき）。
    var onDragStart: ((IconView) -> Void)?

    private let backgroundView = NSView()
    /// アプリアイコン描画用 layer。`NSImageView` を経由しないことで cell の cursor rect 経路を排除する。
    private let iconLayer = CALayer()
    private var trackingArea: NSTrackingArea?
    /// mouseDown 位置。クリック判定の基準。ドラッグ開始時に nil にすることでフラグ代わりに使い、
    /// `mouseUp` でこれが残っていれば「ドラッグ未開始 = クリック」と判定する。
    private var mouseDownLocation: NSPoint?
    /// drag 中の closedHand を `push` した状態かどうか。`pop` 漏れを防ぐ。
    private var closedHandPushed = false
    private static let clickSlop: CGFloat = 4

    init(app: StatusBarApp) {
        self.app = app
        super.init(frame: NSRect(origin: .zero, size: KuraViewController.cellSize))
        wantsLayer = true
        toolTip = app.name
        setupSubviews()
        installTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    private func setupSubviews() {
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 6
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundView)

        // CALayer.contents は NSImage を直接受け取れる（macOS 10.6+）。
        // NSImageView を介さないので、cell が cursor rect を登録する経路がない。
        iconLayer.contents = app.icon
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        backgroundView.layer?.addSublayer(iconLayer)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        // iconLayer は backgroundView.layer 内、中央配置。
        let s = KuraViewController.iconSize
        iconLayer.frame = NSRect(
            x: (bounds.width - s) / 2,
            y: (bounds.height - s) / 2,
            width: s,
            height: s
        )
    }

    override var intrinsicContentSize: NSSize {
        return KuraViewController.cellSize
    }

    /// 子の backgroundView / その sublayer ではなく自分でマウスイベントと cursor rect を受けるため、
    /// hitTest を一段で打ち切る。AppKit の `NSView.hitTest(_:)` の point は **superview 座標系**
    /// で渡される（Apple Doc 明記）ので、親座標系の `frame` で判定する。
    override func hitTest(_ point: NSPoint) -> NSView? {
        return frame.contains(point) ? self : nil
    }

    /// AppKit 標準の cursor rect 機構。`addCursorRect` 内の bounds に入ると AppKit が自動で
    /// `pointingHand` に切り替え、外れると元に戻す。set() ベースの自前ループと違って AppKit の
    /// cursor 評価ループと協調動作するため、ちらつき経路が発生しない。
    /// drag 中の `closedHand` は別経路（`draggingSession.willBeginAt` で `push`）。
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// `addCursorRect` が AppKit に採用されない経路（popover の自動 I-beam 等）に対する補強。
    /// `cursorUpdate(with:)` で明示的に `set()` することで、IconView 領域内では確実に pointingHand。
    /// tracking area に `.cursorUpdate` を入れているので、mouse move で AppKit が呼んでくれる。
    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    /// IconView が window に attach された時点で `resetCursorRects` を確実に呼ばせる。
    /// popover の中では cursor rect の自動再評価が走らないケースがあるため。
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    /// init からも `updateTrackingAreas` 経由でも呼ぶ。`updateTrackingAreas` の初回呼び出しが
    /// popover 内で必ずしも走らないため、init で確実に installation する。
    /// hover ハイライト用に `.mouseEnteredAndExited`、cursor 補強用に `.cursorUpdate` を入れる。
    /// `.cursorUpdate` は `cursorUpdate(with:)` の trigger 元。
    private func installTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setHighlighted(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        // super は呼ばない。AppKit のデフォルト動作（focus 取得や次レスポンダへの転送）は不要。
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownLocation else { return }
        let current = event.locationInWindow
        let distance = hypot(current.x - start.x, current.y - start.y)
        guard distance > Self.clickSlop else { return }
        startDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownLocation = nil }
        guard let start = mouseDownLocation else { return }
        let end = event.locationInWindow
        let distance = hypot(end.x - start.x, end.y - start.y)
        if distance <= Self.clickSlop {
            onClick?(self)
        }
    }

    private func startDrag(with event: NSEvent) {
        guard let image = app.icon else { return }
        // mouseDownLocation を nil にすることで「ドラッグ開始済み」フラグを兼ねる。
        // この後の mouseUp は guard で早期 return し、クリック扱いにならない。
        mouseDownLocation = nil
        // VC に通知して pending な click menu request を invalidate させる。
        onDragStart?(self)
        let pb = NSPasteboardItem()
        pb.setString(app.bundleIdentifier, forType: KuraViewController.dragType)
        let draggingItem = NSDraggingItem(pasteboardWriter: pb)
        draggingItem.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    private func setHighlighted(_ on: Bool) {
        backgroundView.layer?.backgroundColor = on
            ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            : NSColor.clear.cgColor
    }

    /// drag 中に view が解放されると closedHand の `pop` 漏れで cursor stack が乱れるので、
    /// window から外れる時点で確実に pop しておく。
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, closedHandPushed {
            NSCursor.pop()
            closedHandPushed = false
        }
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint) {
        // closedHand を cursor stack に積む。`set()` と違い、AppKit の cursor 評価ループでも
        // stack の trailing edge が選ばれ続けるので drag 中は持続する。
        if !closedHandPushed {
            NSCursor.closedHand.push()
            closedHandPushed = true
        }
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        setHighlighted(false)
        if closedHandPushed {
            NSCursor.pop()
            closedHandPushed = false
        }
    }
}

// MARK: - IconGridView

/// IconView を 4 列で並べるグリッド。
/// `NSStackView` の縦 / 横ネストで自然なレイアウト、`NSDraggingDestination` で drop 位置を index に変換。
/// 数十アイコン規模なら NSCollectionView より軽量（reuse 不要、event handling もシンプル）。
final class IconGridView: NSView {
    /// 並び替え完了時に「どこからどこへ動いた」を通知する。`from < to` 補正は IconGridView 側で済み、
    /// 受け手は自分のデータ配列にも同じ `move(from:to:)` を当てて view と順序を同期する責務。
    /// （IconGridView 側は view 配列 `icons` を再構築済み、KuraViewController 側は data 配列 `appNodes` を
    /// 更新する役割分担。同じ操作が view / data 両側で起きるが、責務分離としてこの並走を許容する。）
    var onReorder: ((_ from: Int, _ to: Int) -> Void)?

    private let vStack = NSStackView()
    private var rows: [NSStackView] = []
    private var icons: [IconView] = []
    /// drop 位置に描く縦線インジケータ。NSCollectionView 標準の drop indicator 代わり。
    private let dropIndicator = NSView()
    private static let indicatorWidth: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// AppKit デフォルトは左下原点。drop 座標 → index 計算を素直に書きたいので flip する。
    override var isFlipped: Bool { true }

    private func setup() {
        vStack.orientation = .vertical
        vStack.alignment = .leading
        vStack.spacing = KuraViewController.gridGap
        vStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vStack)
        NSLayoutConstraint.activate([
            vStack.topAnchor.constraint(equalTo: topAnchor, constant: KuraViewController.gridPadding),
            vStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: KuraViewController.gridPadding),
            vStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -KuraViewController.gridPadding),
            vStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -KuraViewController.gridPadding),
        ])

        // dropIndicator は IconGridView の絶対座標で manual frame 配置する。
        dropIndicator.wantsLayer = true
        dropIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dropIndicator.layer?.cornerRadius = 1
        dropIndicator.isHidden = true
        addSubview(dropIndicator)

        registerForDraggedTypes([KuraViewController.dragType])
    }

    /// クリック時の menu popUp のアンカーを引き直すための lookup。
    /// 直接 IconView 参照を引き継ぐと `setTargets` で view が再生成された後に stale になるため、
    /// bundleId 経由で「現時点で表示中の IconView」を取り直す。
    func iconView(forBundleId bundleId: String) -> IconView? {
        return icons.first { $0.app.bundleIdentifier == bundleId }
    }

    func setIcons(_ iconViews: [IconView]) {
        for row in rows {
            vStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rows.removeAll()
        icons = iconViews
        var index = 0
        while index < iconViews.count {
            let end = min(index + KuraViewController.columns, iconViews.count)
            let chunk = Array(iconViews[index..<end])
            let row = NSStackView(views: chunk)
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = KuraViewController.gridGap
            rows.append(row)
            vStack.addArrangedSubview(row)
            index = end
        }
        // documentView の intrinsicContentSize が変わったので NSScrollView に再計算させる。
        // これがないとアイコン数が増えた時に下の行がスクロール範囲外になる。
        invalidateIntrinsicContentSize()
    }

    /// NSScrollView の `documentView` として正しい content height を提供する。
    /// 横は `noIntrinsicMetric` のまま（scrollView の clipView 幅に合わせる）。
    override var intrinsicContentSize: NSSize {
        let cellH = KuraViewController.cellSize.height
        let gap = KuraViewController.gridGap
        let pad = KuraViewController.gridPadding
        let rowCount = rows.count
        let height: CGFloat
        if rowCount == 0 {
            height = pad * 2
        } else {
            height = pad * 2 + CGFloat(rowCount) * cellH + CGFloat(rowCount - 1) * gap
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return validate(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return validate(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideDropIndicator()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hideDropIndicator()
    }

    private func validate(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(KuraViewController.dragType) == true else {
            hideDropIndicator()
            return []
        }
        let local = convert(sender.draggingLocation, from: nil)
        let insertIndex = computeInsertIndex(at: local)
        updateDropIndicator(at: insertIndex)
        return .move
    }

    private func hideDropIndicator() {
        dropIndicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideDropIndicator()
        guard let bundleId = sender.draggingPasteboard.string(forType: KuraViewController.dragType),
              let oldIndex = icons.firstIndex(where: { $0.app.bundleIdentifier == bundleId })
        else { return false }
        let dropLocation = convert(sender.draggingLocation, from: nil)
        let insertIndex = computeInsertIndex(at: dropLocation)
        // 「自分より後ろに移動」する場合、自分を remove 後の挿入位置は 1 つ手前にズレる。
        let adjusted = oldIndex < insertIndex ? insertIndex - 1 : insertIndex
        let clamped = max(0, min(adjusted, icons.count - 1))
        guard clamped != oldIndex else { return false }
        moveIcon(from: oldIndex, to: clamped)
        NSLog("[Kura] dnd reorder %@ %d→%d", bundleId, oldIndex, clamped)
        onReorder?(oldIndex, clamped)
        return true
    }

    private func moveIcon(from oldIndex: Int, to newIndex: Int) {
        let icon = icons.remove(at: oldIndex)
        icons.insert(icon, at: newIndex)
        setIcons(icons)
    }

    /// `computeInsertIndex` の結果から drop indicator の frame を計算して表示。
    /// 基準は NSStackView が実際に配置した IconView の frame（grid 定数の掛け算ではなく実 layout に追従）。
    /// 末尾挿入 (insertIndex == icons.count) は「最終 cell の右側」、それ以外は「cell colIndex の左側」の gap 中央に縦線。
    private func updateDropIndicator(at insertIndex: Int) {
        guard !icons.isEmpty else {
            hideDropIndicator()
            return
        }
        let gap = KuraViewController.gridGap
        let displayIndex: Int
        let placeAfter: Bool
        if insertIndex >= icons.count {
            displayIndex = icons.count - 1
            placeAfter = true
        } else {
            displayIndex = insertIndex
            placeAfter = false
        }
        let target = icons[displayIndex]
        let frameInGrid = convert(target.bounds, from: target)
        let x: CGFloat
        if placeAfter {
            x = frameInGrid.maxX + gap / 2 - Self.indicatorWidth / 2
        } else {
            x = frameInGrid.minX - gap / 2 - Self.indicatorWidth / 2
        }
        dropIndicator.frame = NSRect(
            x: x,
            y: frameInGrid.minY,
            width: Self.indicatorWidth,
            height: frameInGrid.height
        )
        dropIndicator.isHidden = false
    }

    /// drop 座標から「挿入する index」を求める。
    /// flipped 座標（左上原点）で行 / 列を割って、X がセル中央より右なら +1（後ろに挿入）。
    private func computeInsertIndex(at point: NSPoint) -> Int {
        guard !icons.isEmpty else { return 0 }
        let cellW = KuraViewController.cellSize.width + KuraViewController.gridGap
        let cellH = KuraViewController.cellSize.height + KuraViewController.gridGap
        let xInGrid = max(0, point.x - KuraViewController.gridPadding)
        let yInGrid = max(0, point.y - KuraViewController.gridPadding)
        let rowIndex = max(0, min(Int(yInGrid / cellH), rows.count - 1))
        let colIndexRaw = Int(xInGrid / cellW)
        let xInCell = xInGrid.truncatingRemainder(dividingBy: cellW)
        let extra = xInCell > KuraViewController.cellSize.width / 2 ? 1 : 0
        let colIndex = max(0, min(colIndexRaw + extra, KuraViewController.columns))
        let flat = rowIndex * KuraViewController.columns + colIndex
        return min(flat, icons.count)
    }
}

// MARK: - CursorlessLabel

/// AppKit のテキスト系 view (NSTextField) は I-beam を **複数経路** で登録する:
///   1. `NSView.resetCursorRects()` (legacy cursor rect)
///   2. `NSCell.resetCursorRect(_:inView:)` (cell-based legacy cursor rect)
///   3. `NSTrackingArea` 経由の `cursorUpdate` (modern)
/// それぞれ独立に動くため、全部塞がないと I-beam が出る。CursorlessLabel は全経路の override を持つ。
///
/// レイアウト挙動を壊さないため、`NSTextField(labelWithString:)` で正規ラベルを作ったあと、
/// view と cell を `object_setClass` で動的に差し替える方式を採る（どちらも stored property を追加
/// していないので安全）。
private final class CursorlessLabel: NSTextField {
    override func resetCursorRects() {
        // 経路 1 を抑止: view レベルの legacy cursor rect 登録なし。
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // 経路 3 を抑止: AppKit が NSTextField のために追加した cursor update tracking area を全削除。
        // super を呼んだ直後に消すことで、AppKit が登録したものを確実に除去できる。
        for area in trackingAreas {
            removeTrackingArea(area)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        // tracking area を全削除しても、cursorUpdate event が何かの経路で届いた場合の最終防壁。
        // NSCursor.IBeam.set() が default なので、override で何もしないことで I-beam を上書きしない。
    }
}

/// NSTextFieldCell から I-beam の cursor rect が登録される経路を塞ぐ。
private final class CursorlessLabelCell: NSTextFieldCell {
    override func resetCursorRect(_ cellFrame: NSRect, in controlView: NSView) {
        // 経路 2 を抑止: cell レベルの legacy cursor rect 登録なし。
    }
}

/// `NSTextField.labelWithString(_:)` の挙動をそのままに、view + cell の cursor rect 登録を抑止した label を返す。
private func makeCursorlessLabel(_ string: String) -> NSTextField {
    let label = NSTextField(labelWithString: string)
    object_setClass(label, CursorlessLabel.self)
    if let cell = label.cell {
        object_setClass(cell, CursorlessLabelCell.self)
    }
    return label
}
