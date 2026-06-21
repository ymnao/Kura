import AppKit

final class SettingsViewController: NSViewController {
    private let tableView = NSTableView()
    private var observerToken: Any?

    private static let iconColumnId = NSUserInterfaceItemIdentifier("icon")
    private static let nameColumnId = NSUserInterfaceItemIdentifier("name")
    private static let actionColumnId = NSUserInterfaceItemIdentifier("action")

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 420))

        let title = NSTextField(labelWithString: "蔵に納めるアプリ")
        title.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let hint = NSTextField(labelWithString: "ここに登録したアプリのメニューバー項目が、蔵のポップオーバーから呼び出せるようになります（操作の実装は v0.2 以降）。")
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 0
        hint.preferredMaxLayoutWidth = 480
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        tableView.rowHeight = 32
        tableView.headerView = nil
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.gridStyleMask = []
        tableView.intercellSpacing = NSSize(width: 0, height: 4)

        let iconColumn = NSTableColumn(identifier: Self.iconColumnId)
        iconColumn.width = 28
        iconColumn.minWidth = 28
        iconColumn.maxWidth = 28
        tableView.addTableColumn(iconColumn)

        let nameColumn = NSTableColumn(identifier: Self.nameColumnId)
        nameColumn.width = 340
        tableView.addTableColumn(nameColumn)

        let actionColumn = NSTableColumn(identifier: Self.actionColumnId)
        actionColumn.width = 100
        actionColumn.minWidth = 100
        actionColumn.maxWidth = 100
        tableView.addTableColumn(actionColumn)

        scrollView.documentView = tableView

        let addButton = NSButton(title: "＋ アプリを追加", target: self, action: #selector(addApp(_:)))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(addButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            scrollView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),

            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        view = container

        observerToken = NotificationCenter.default.addObserver(
            forName: RegistrationStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.tableView.reloadData()
        }
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    @objc private func addApp(_ sender: NSButton) {
        let menu = NSMenu()
        let candidates = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
            .compactMap { app -> (String, String, NSImage?)? in
                guard let bid = app.bundleIdentifier,
                      bid != Bundle.main.bundleIdentifier else { return nil }
                let name = app.localizedName ?? bid
                return (bid, name, app.icon)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }

        let registeredIds = Set(RegistrationStore.shared.registeredApps.map { $0.bundleIdentifier })

        if candidates.isEmpty {
            let item = NSMenuItem(title: "起動中のアプリがありません", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        for (bid, name, icon) in candidates {
            let item = NSMenuItem(title: name, action: #selector(menuPickApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = RegisteredApp(bundleIdentifier: bid, name: name)
            if let icon = icon {
                let resized = icon.copy() as! NSImage
                resized.size = NSSize(width: 16, height: 16)
                item.image = resized
            }
            if registeredIds.contains(bid) {
                item.state = .on
                item.isEnabled = false
            }
            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func menuPickApp(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? RegisteredApp else { return }
        RegistrationStore.shared.add(app)
    }

    @objc private func removeApp(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        let apps = RegistrationStore.shared.registeredApps
        guard apps.indices.contains(row) else { return }
        RegistrationStore.shared.remove(apps[row])
    }
}

extension SettingsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        RegistrationStore.shared.registeredApps.count
    }
}

extension SettingsViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let apps = RegistrationStore.shared.registeredApps
        guard apps.indices.contains(row) else { return nil }
        let app = apps[row]

        switch column.identifier {
        case Self.iconColumnId:
            let cell: NSImageView
            if let recycled = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSImageView {
                cell = recycled
            } else {
                cell = NSImageView()
                cell.identifier = column.identifier
                cell.imageScaling = .scaleProportionallyDown
            }
            cell.image = app.icon
            return cell

        case Self.nameColumnId:
            let cell: NSTextField
            if let recycled = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField {
                cell = recycled
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = column.identifier
                cell.lineBreakMode = .byTruncatingTail
            }
            cell.stringValue = app.name
            return cell

        case Self.actionColumnId:
            let cell: NSButton
            if let recycled = tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSButton {
                cell = recycled
            } else {
                cell = NSButton(title: "蔵から出す", target: self, action: #selector(removeApp(_:)))
                cell.identifier = column.identifier
                cell.bezelStyle = .rounded
                cell.controlSize = .small
            }
            return cell

        default:
            return nil
        }
    }
}
