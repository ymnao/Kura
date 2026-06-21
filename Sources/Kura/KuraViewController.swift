import AppKit

final class AppNode {
    let app: RegisteredApp
    var items: [MenuBarItem]?

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

    private static let columnId = NSUserInterfaceItemIdentifier("kura.row")
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

        let column = NSTableColumn(identifier: Self.columnId)
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
        let trusted = AccessibilityPermission.isTrusted
        bannerContainer.isHidden = trusted
        bannerHeightConstraint.constant = trusted ? 0 : 32
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        AccessibilityPermission.openSystemSettings()
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func reload() {
        let apps = RegistrationStore.shared.registeredApps
        appNodes = apps.map { app in
            if let cached = nodeCache[app.bundleIdentifier], cached.app == app {
                return cached
            }
            let node = AppNode(app)
            nodeCache[app.bundleIdentifier] = node
            return node
        }
        let activeIds = Set(apps.map { $0.bundleIdentifier })
        nodeCache = nodeCache.filter { activeIds.contains($0.key) }

        outlineView.reloadData()
        emptyLabel.isHidden = !appNodes.isEmpty
    }
}

extension KuraViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return appNodes.count
        }
        if let node = item as? AppNode {
            if node.items == nil {
                node.items = MenuBarScanner.scan(node.app)
            }
            return node.items?.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return appNodes[index]
        }
        let node = item as! AppNode
        return node.items![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is AppNode
    }
}

extension KuraViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let node = item as? AppNode {
            let cell: AppRowView
            if let recycled = outlineView.makeView(withIdentifier: Self.appCellId, owner: self) as? AppRowView {
                cell = recycled
            } else {
                cell = AppRowView()
                cell.identifier = Self.appCellId
            }
            cell.configure(with: node.app)
            return cell
        }
        if let item = item as? MenuBarItem {
            let cell: MenuItemRowView
            if let recycled = outlineView.makeView(withIdentifier: Self.itemCellId, owner: self) as? MenuItemRowView {
                cell = recycled
            } else {
                cell = MenuItemRowView()
                cell.identifier = Self.itemCellId
            }
            cell.configure(with: item)
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
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func configure(with item: MenuBarItem) {
        titleLabel.stringValue = item.title
        titleLabel.textColor = item.element == nil ? .tertiaryLabelColor : .secondaryLabelColor
    }
}
