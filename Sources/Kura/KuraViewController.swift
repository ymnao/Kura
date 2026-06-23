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
protocol IconViewDelegate: AnyObject {
    func iconViewClicked(_ view: IconView)
}

@MainActor
protocol IconGridReorderDelegate: AnyObject {
    func iconGrid(_ view: IconGridView, didReorderTo newBundleIds: [String])
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

    override func loadView() {
        let container = NSView(frame: NSRect(
            x: 0, y: 0,
            width: Self.preferredPopoverWidth,
            height: 240
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
        gridView.reorderDelegate = self

        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = gridView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

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
            v.delegate = self
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

// MARK: - IconViewDelegate

extension KuraViewController: IconViewDelegate {
    func iconViewClicked(_ view: IconView) {
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

// MARK: - IconGridReorderDelegate

extension KuraViewController: IconGridReorderDelegate {
    func iconGrid(_ view: IconGridView, didReorderTo newBundleIds: [String]) {
        // appNodes も新順序に合わせる。新順序に存在しない bundleId（あり得ないはずだが念のため）は末尾へ。
        var remaining = appNodes
        var reordered: [AppNode] = []
        for id in newBundleIds {
            if let idx = remaining.firstIndex(where: { $0.app.bundleIdentifier == id }) {
                reordered.append(remaining.remove(at: idx))
            }
        }
        reordered.append(contentsOf: remaining)
        appNodes = reordered
        NSLog("[Kura] reorder applied: %d", appNodes.count)
        onReorder?(newBundleIds)
    }
}

// MARK: - IconView

/// アプリアイコン 1 個のセル。
/// - `resetCursorRects` で `.pointingHand` を登録 → AppKit が自動でカーソル切替（push/pop スタック乱れなし）
/// - `mouseDown/Dragged/Up` で「クリック」「ドラッグ」を自前判定。NSCollectionView の機構には依存しない
/// - ドラッグ開始は `beginDraggingSession`（`NSDraggingSource` 自己実装）
/// - `hitTest` で子 view (NSImageView) を素通り → mouseDown を確実に受ける
final class IconView: NSView, NSDraggingSource {
    let app: StatusBarApp
    weak var delegate: IconViewDelegate?

    private let backgroundView = NSView()
    private let iconImageView = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var mouseDownLocation: NSPoint?
    private var dragStarted = false
    private static let clickSlop: CGFloat = 4

    init(app: StatusBarApp) {
        self.app = app
        super.init(frame: NSRect(origin: .zero, size: KuraViewController.cellSize))
        wantsLayer = true
        toolTip = app.name
        setupSubviews()
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

    /// 子の NSImageView ではなく自分でマウスイベントを受けるため、hitTest を一段で打ち切る。
    override func hitTest(_ point: NSPoint) -> NSView? {
        // point は superview 座標系で来る。bounds は self 座標系なので変換が必要だが、
        // 矩形内ならどこでも self を返せばよいので superview 座標系の frame で判定する。
        return frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        // AppKit 標準のカーソル管理。push/pop と違ってスタック乱れがない。
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
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
        dragStarted = false
        // super は呼ばない。AppKit のデフォルト動作（focus 取得や次レスポンダへの転送）は不要。
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, let start = mouseDownLocation else { return }
        let current = event.locationInWindow
        let distance = hypot(current.x - start.x, current.y - start.y)
        guard distance > Self.clickSlop else { return }
        startDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocation = nil
            dragStarted = false
        }
        guard !dragStarted, let start = mouseDownLocation else { return }
        let end = event.locationInWindow
        let distance = hypot(end.x - start.x, end.y - start.y)
        if distance <= Self.clickSlop {
            delegate?.iconViewClicked(self)
        }
    }

    private func startDrag(with event: NSEvent) {
        guard let image = app.icon else { return }
        dragStarted = true
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
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // セッション終了時にホバー状態を初期化。drag 中は mouseExited が来ないことがある。
        setHighlighted(false)
    }
}

// MARK: - IconGridView

/// IconView を 4 列で並べるグリッド。
/// `NSStackView` の縦 / 横ネストで自然なレイアウト、`NSDraggingDestination` で drop 位置を index に変換。
/// 数十アイコン規模なら NSCollectionView より軽量（reuse 不要、event handling もシンプル）。
final class IconGridView: NSView {
    weak var reorderDelegate: IconGridReorderDelegate?

    private let vStack = NSStackView()
    private var rows: [NSStackView] = []
    private var icons: [IconView] = []

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
    }

    // MARK: NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return validate(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return validate(sender)
    }

    private func validate(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.types?.contains(KuraViewController.dragType) == true else { return [] }
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let bundleId = sender.draggingPasteboard.string(forType: KuraViewController.dragType),
              let oldIndex = icons.firstIndex(where: { $0.app.bundleIdentifier == bundleId })
        else { return false }
        let dropLocation = convert(sender.draggingLocation, from: nil)
        let insertIndex = computeInsertIndex(at: dropLocation)
        // 「自分より後ろに移動」する場合、自分を remove 後の挿入位置は 1 つ手前にズレる。
        let adjusted = oldIndex < insertIndex ? insertIndex - 1 : insertIndex
        let clamped = max(0, min(adjusted, icons.count - 1))
        guard clamped != oldIndex else { return false }
        let icon = icons.remove(at: oldIndex)
        icons.insert(icon, at: clamped)
        setIcons(icons)
        let newOrder = icons.map { $0.app.bundleIdentifier }
        NSLog("[Kura] dnd reorder %@ %d→%d", bundleId, oldIndex, clamped)
        reorderDelegate?.iconGrid(self, didReorderTo: newOrder)
        return true
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
