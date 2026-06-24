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
    private let emptyLabel = NSTextField(labelWithString: "")
    private let bannerContainer = NSView()
    private let bannerLabel = NSTextField(labelWithString: "⚠ アクセシビリティ未許可")
    private let bannerButton = NSButton()
    private var bannerHeightConstraint: NSLayoutConstraint!

    private var appNodes: [AppNode] = []
    private var nodeCache: [String: AppNode] = [:]

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

    /// popover の初期高さ。`loadView` の container frame と `AppDelegate.popover.contentSize` で共有する。
    static let preferredPopoverHeight: CGFloat = 240

    override func loadView() {
        let container = PopoverRootView(frame: NSRect(
            x: 0, y: 0,
            width: Self.preferredPopoverWidth,
            height: Self.preferredPopoverHeight
        ))

        let title = NSTextField(labelWithString: "蔵")
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
        guard let node = appNodes.first(where: { $0.app.bundleIdentifier == view.app.bundleIdentifier })
        else { return }
        let folded = foldController?.isFolded ?? false
        scanIfNeeded(node)
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
/// - `resetCursorRects` で `.pointingHand` を登録 → AppKit が自動でカーソル切替（push/pop スタック乱れなし）
/// - `mouseDown/Dragged/Up` で「クリック」「ドラッグ」を自前判定
/// - ドラッグ開始は `beginDraggingSession`（`NSDraggingSource` 自己実装）
/// - `hitTest` で子 view (NSImageView) を素通り → mouseDown を確実に受ける
final class IconView: NSView, NSDraggingSource {
    let app: StatusBarApp
    /// クリック時のコールバック。delegate protocol だと「メソッド 1 個 / 利用箇所 1 か所」で過剰なので
    /// 同ファイル内の `onItemActivated` / `onReorder` と同じ closure パターンで統一する。
    var onClick: ((IconView) -> Void)?

    private let backgroundView = NSView()
    private let iconImageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    /// mouseDown 位置。クリック判定の基準。ドラッグ開始時に nil にすることでフラグ代わりに使い、
    /// `mouseUp` でこれが残っていれば「ドラッグ未開始 = クリック」と判定する。
    private var mouseDownLocation: NSPoint?
    /// ドラッグ中フラグ。mouseMoved 中のカーソルを `pointingHand` ではなく `closedHand` に切り替える。
    private var isDragging = false
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

        iconImageView.image = app.icon
        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        // NSImageView がドラッグの送受信元になると IconView の自前 D&D とぶつかる。
        // mouseDown は isEditable=false (デフォルト) なら responder chain で IconView に届く。
        iconImageView.unregisterDraggedTypes()
        addSubview(iconImageView)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: KuraViewController.iconSize),
            iconImageView.heightAnchor.constraint(equalToConstant: KuraViewController.iconSize),
        ])
    }

    override var intrinsicContentSize: NSSize {
        return KuraViewController.cellSize
    }

    /// 子の NSImageView / backgroundView ではなく自分でマウスイベントとカーソル rect を受けるため、
    /// hitTest を一段で打ち切る。これがないと subview に hit が降りて `resetCursorRects` で登録した
    /// pointingHand が effectsless になり、矢印カーソルに戻ってしまう（AppKit の cursor rect は
    /// 階層を上に登らない）。
    /// `NSView.hitTest(_:)` の point は **superview 座標系** で渡される（Apple Doc 明記）ので、
    /// 親座標系の `frame` で判定する。
    override func hitTest(_ point: NSPoint) -> NSView? {
        return frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    /// init からも `updateTrackingAreas` 経由でも呼ぶ。`updateTrackingAreas` の初回呼び出しが
    /// popover 内で必ずしも走らないため、init で確実に installation する。
    private func installTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        // `.mouseMoved` で mouseMoved event を毎 frame 受けて、cursor を `set()` し続ける。
        // AppKit には disableCursorRects 後でも cursor を arrow に戻す経路があり、push したものも
        // 一瞬で消える症状が出る。set を mouseMoved の頻度で繰り返すと AppKit の reset の直後に
        // 必ず上書きできるので、表示上は意図の cursor が持続する。
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .cursorUpdate, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor()
    }

    override func mouseMoved(with event: NSEvent) {
        // AppKit の cursor reset 経路を上書きし続けるため、毎 frame set する。
        applyCursor()
    }

    override func mouseEntered(with event: NSEvent) {
        applyCursor()
        setHighlighted(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHighlighted(false)
    }

    private func applyCursor() {
        if isDragging {
            NSCursor.closedHand.set()
        } else {
            NSCursor.pointingHand.set()
        }
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

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
    }

    func draggingSession(_ session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint) {
        isDragging = true
        NSCursor.closedHand.set()
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        isDragging = false
        setHighlighted(false)
    }
}

// MARK: - IconGridView

/// IconView を 4 列で並べるグリッド。
/// `NSStackView` の縦 / 横ネストで自然なレイアウト、`NSDraggingDestination` で drop 位置を index に変換。
/// 数十アイコン規模なら NSCollectionView より軽量（reuse 不要、event handling もシンプル）。
final class IconGridView: NSView {
    /// 並び替え完了時に「どこからどこへ動いた」を通知する。`from < to` 補正は IconGridView 側で済み、
    /// 受け手は自分のデータ配列に同じ `move(from:to:)` を当てるだけでよい（appNodes との二重 source-of-truth を防ぐ）。
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

// MARK: - PopoverRootView

/// popover 全体のルート view。`cursorUpdate` で `arrow` を明示する。
/// AppKit は階層で最も深い `cursorUpdate` を持つ view を採用するため、
/// IconView 領域では IconView 側の `cursorUpdate`（pointingHand）が優先される。
/// これがないと、popover の window エッジに AppKit が貼る resize cursor や、
/// 子 view の cursor rect の残滓（I-beam など）が popover 内に漏れる。
private final class PopoverRootView: NSView {
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installTrackingArea()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTrackingArea()
    }

    private func installTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        // `.inVisibleRect` があるので rect 自体は使われないが、API として渡す必要あり。
        // init から呼ぶので bounds がまだ確定していないことに依存しない。
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}
