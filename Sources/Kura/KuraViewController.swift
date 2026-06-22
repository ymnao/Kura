import AppKit

/// AppDelegate に折りたたみ状態を問い合わせ、必要に応じて展開を要求するための contract。
@MainActor
protocol FoldController: AnyObject {
    var isFolded: Bool { get }
    /// AX cache 不完全な項目（needsExpandToFire）クリック時の選択的自動展開で使用。
    func expandIfFolded()
}

fileprivate final class StatusRow {
    var text: String = "読込中…"
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
    fileprivate let statusRow = StatusRow()

    init(_ app: StatusBarApp) {
        self.app = app
    }

    deinit {
        scanTask?.cancel()
    }
}

@MainActor
final class KuraViewController: NSViewController {
    private let outlineView = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let bannerContainer = NSView()
    private let bannerLabel = NSTextField(labelWithString: "⚠ アクセシビリティ未許可")
    private let bannerButton = NSButton()
    private var bannerHeightConstraint: NSLayoutConstraint!

    private var appNodes: [AppNode] = []
    private var nodeCache: [String: AppNode] = [:]

    var onItemActivated: (() -> Void)?
    weak var foldController: FoldController?

    private static let appCellId = NSUserInterfaceItemIdentifier("kura.appRow")
    private static let itemCellId = NSUserInterfaceItemIdentifier("kura.itemRow")

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 420))

        let title = NSTextField(labelWithString: "蔵")
        title.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kura.row"))
        outlineView.headerView = nil
        outlineView.rowHeight = 28
        outlineView.gridStyleMask = []
        outlineView.selectionHighlightStyle = .none
        outlineView.backgroundColor = .clear
        outlineView.indentationPerLevel = 14
        outlineView.indentationMarkerFollowsCell = true
        outlineView.intercellSpacing = NSSize(width: 0, height: 2)
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineViewClicked(_:))

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

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        emptyLabel.stringValue = "蔵の左にアイコンがありません\n\n隠したいメニューバーアイコンを\n蔵の左側にドラッグしてください"
        emptyLabel.font = NSFont.systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),

            separator.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            separator.heightAnchor.constraint(equalToConstant: 1),

            bannerContainer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            bannerContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            bannerContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            bannerLabel.leadingAnchor.constraint(equalTo: bannerContainer.leadingAnchor, constant: 10),
            bannerLabel.centerYAnchor.constraint(equalTo: bannerContainer.centerYAnchor),
            bannerLabel.trailingAnchor.constraint(lessThanOrEqualTo: bannerButton.leadingAnchor, constant: -8),

            bannerButton.trailingAnchor.constraint(equalTo: bannerContainer.trailingAnchor, constant: -8),
            bannerButton.centerYAnchor.constraint(equalTo: bannerContainer.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: bannerContainer.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
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
                // 折りたたみ中は cache 保持。展開中だけ result をリセットして再 scan する。
                if !folded {
                    node.scanTask?.cancel()
                    node.scanTask = nil
                    node.scanGeneration &+= 1
                    node.result = nil
                    node.statusRow.text = "読込中…"
                }
            } else {
                // 別アプリに入れ替わった場合は cache 破棄して新規ノード
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
        outlineView.reloadData()
        emptyLabel.isHidden = !appNodes.isEmpty
        // 折りたたみ中はアプリのアイコンが画面外で AX children を取得できないアプリが
        // 存在する（メニューを開いた時にしか children を提供しないアプリ等）。
        // 折りたたみ前の今のうちに全 AppNode のメニュー詳細を scan して cache 化しておく。
        // 折りたたみ中はキックしない（result も保持されているのでそのまま再利用）。
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

    @objc private func outlineViewClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? MenuBarItem else { return }
        let folded = foldController?.isFolded ?? false
        // 子を持つ行（サブメニュー）は展開/折りたたみで開閉。葉のみ AXPress で発火する。
        if !item.children.isEmpty {
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
            return
        }
        guard item.isExecutable else { return }
        // 折りたたみ中 + cache 不完全（needsExpandToFire）は「折りたたみ非対応」として無効化。
        // 自動展開すると「隠す」目的が崩れるため、ユーザーが手動で展開してから操作する流れに統一。
        if folded && item.needsExpandToFire {
            NSLog("[Kura] click: needsExpandToFire while folded → skip (unsupported)")
            return
        }
        // 折りたたみ中 + AXMenuBarItem（NSStatusItem アイコン自体）クリックは AXPress でアイコンが
        // 画面に戻ってしまうのでスキップ。
        if folded && !item.isMenuItem {
            NSLog("[Kura] click: folded+AXMenuBarItem → skip")
            return
        }
        NSLog("[Kura] click: direct press")
        onItemActivated?()
        MenuBarDispatcher.press(item)
    }

    // VC が解放されると appNodes / nodeCache の AppNode も解放されるため、
    // 各 AppNode.deinit が自身の scanTask をキャンセルしてくれる。deinit から
    // nodeCache を触ると Swift 6 strict-concurrency でエラーになるため明示的な deinit は不要。

    private func scanIfNeeded(_ node: AppNode) {
        guard node.result == nil, node.scanTask == nil else { return }
        let generation = node.scanGeneration
        // Task.detached には value 型 (StatusBarApp) と generation のみ渡す。
        // AppNode 参照を持ち出さないので、MainActor からの隔離が型レベルで保たれる。
        let app = node.app
        node.scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = MenuBarScanner.scan(app)
            await self?.handleScanCompletion(app: app, generation: generation, result: result)
        }
    }

    /// 完了結果を反映する条件は「同じ bundleId のノードが現存」「ノードの app が値として一致」
    /// 「generation も一致」の 3 点。PID 変更や対象 index 変更で新ノードに入れ替わった場合、
    /// 新ノードは generation = 1 で始まるため、旧 Task (同じく generation = 1) の完了で
    /// 新ノードを汚染するリスクがある。app を value 比較することでこれを防ぐ。
    private func handleScanCompletion(app: StatusBarApp, generation: Int, result: ScanResult) {
        guard let node = nodeCache[app.bundleIdentifier],
              node.app == app,
              node.scanGeneration == generation else { return }
        node.scanTask = nil
        node.result = result
        node.statusRow.text = Self.statusText(for: result)
        guard appNodes.contains(where: { $0 === node }) else { return }
        outlineView.reloadItem(node, reloadChildren: true)
    }

    private static func statusText(for result: ScanResult) -> String {
        switch result {
        case .notRunning: return "起動していません"
        case .failed(let reason): return "走査失敗: \(reason)"
        case .items(let items) where items.isEmpty: return "メニュー項目なし"
        case .items: return ""
        }
    }

    private func dequeue<T: NSTableCellView>(_ id: NSUserInterfaceItemIdentifier) -> T {
        if let recycled = outlineView.makeView(withIdentifier: id, owner: self) as? T {
            return recycled
        }
        let cell = T()
        cell.identifier = id
        return cell
    }
}

extension KuraViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return appNodes.count
        }
        if let node = item as? AppNode {
            scanIfNeeded(node)
            if case .items(let items) = node.result, !items.isEmpty {
                return items.count
            }
            return 1
        }
        if let menuItem = item as? MenuBarItem {
            return menuItem.children.count
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return appNodes[index]
        }
        if let node = item as? AppNode {
            if case .items(let items) = node.result, !items.isEmpty {
                return items[index]
            }
            return node.statusRow
        }
        if let menuItem = item as? MenuBarItem {
            return menuItem.children[index]
        }
        fatalError("unexpected outline parent: \(item ?? "nil")")
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is AppNode { return true }
        if let menuItem = item as? MenuBarItem {
            return !menuItem.children.isEmpty
        }
        return false
    }
}

extension KuraViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let node = item as? AppNode {
            let cell: AppRowView = dequeue(Self.appCellId)
            cell.configure(with: node.app)
            return cell
        }
        if let menuItem = item as? MenuBarItem {
            let cell: MenuItemRowView = dequeue(Self.itemCellId)
            cell.configure(
                title: menuItem.title,
                isPlaceholder: false,
                isExecutable: menuItem.isExecutable,
                needsExpandToFire: menuItem.needsExpandToFire
            )
            return cell
        }
        if let status = item as? StatusRow {
            let cell: MenuItemRowView = dequeue(Self.itemCellId)
            cell.configure(title: status.text, isPlaceholder: true)
            return cell
        }
        return nil
    }
}

final class AppRowView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func configure(with app: StatusBarApp) {
        iconView.image = app.icon
        nameLabel.stringValue = app.name
    }
}

final class MenuItemRowView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func configure(title: String, isPlaceholder: Bool, isExecutable: Bool = true, needsExpandToFire: Bool = false) {
        if needsExpandToFire {
            // AX にメニュー情報を公開しないアプリ（Claude 等）。折りたたみ中は操作不能、
            // 展開状態でのみ動作する。ユーザーが事前に把握できるようマーキングする。
            titleLabel.stringValue = "\(title)（折りたたみ非対応）"
            titleLabel.textColor = .tertiaryLabelColor
        } else if isPlaceholder || !isExecutable {
            titleLabel.stringValue = title
            titleLabel.textColor = .tertiaryLabelColor
        } else {
            titleLabel.stringValue = title
            titleLabel.textColor = .secondaryLabelColor
        }
    }
}
