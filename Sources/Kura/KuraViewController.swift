import AppKit

fileprivate final class StatusRow {
    var text: String = "読込中…"
}

final class AppNode {
    let app: RegisteredApp
    var result: ScanResult?
    var scanTask: Task<Void, Never>?
    var scanGeneration: Int = 0
    fileprivate let statusRow = StatusRow()

    init(_ app: RegisteredApp) {
        self.app = app
    }
}

final class KuraViewController: NSViewController {
    private let outlineView = NSOutlineView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let bannerContainer = NSView()
    private let bannerLabel = NSTextField(labelWithString: "⚠ アクセシビリティ未許可")
    private let bannerButton = NSButton()
    private var bannerHeightConstraint: NSLayoutConstraint!
    private var observerToken: Any?

    private var appNodes: [AppNode] = []
    private var nodeCache: [String: AppNode] = [:]

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

        emptyLabel.stringValue = "蔵は空です\n\n右クリック → 設定… から\nアプリを納めてください"
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

        observerToken = NotificationCenter.default.addObserver(
            forName: RegistrationStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updatePermissionBanner()
        reload()
    }

    private func updatePermissionBanner() {
        bannerHeightConstraint.constant = AccessibilityPermission.isTrusted ? 0 : 32
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        AccessibilityPermission.openSystemSettings()
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
        nodeCache.values.forEach { $0.scanTask?.cancel() }
    }

    private func reload() {
        let apps = RegistrationStore.shared.registeredApps
        appNodes = apps.map { app in
            let node = nodeCache[app.bundleIdentifier].map { $0.app == app ? $0 : AppNode(app) } ?? AppNode(app)
            node.scanTask?.cancel()
            node.scanTask = nil
            node.scanGeneration &+= 1
            node.result = nil
            node.statusRow.text = "読込中…"
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
    }

    private func scanIfNeeded(_ node: AppNode) {
        guard node.result == nil, node.scanTask == nil else { return }
        let generation = node.scanGeneration
        node.scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = MenuBarScanner.scan(node.app)
            await MainActor.run {
                guard node.scanGeneration == generation else { return }
                node.scanTask = nil
                if Task.isCancelled { return }
                node.result = result
                node.statusRow.text = Self.statusText(for: result)
                guard let self = self, self.appNodes.contains(where: { $0 === node }) else { return }
                self.outlineView.reloadItem(node, reloadChildren: true)
            }
        }
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
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return appNodes[index]
        }
        let node = item as! AppNode
        if case .items(let items) = node.result, !items.isEmpty {
            return items[index]
        }
        return node.statusRow
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is AppNode
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
            cell.configure(title: menuItem.title, isPlaceholder: false)
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

    func configure(with app: RegisteredApp) {
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
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func configure(title: String, isPlaceholder: Bool) {
        titleLabel.stringValue = title
        titleLabel.textColor = isPlaceholder ? .tertiaryLabelColor : .secondaryLabelColor
    }
}
