import AppKit

final class KuraViewController: NSViewController {
    private let tableView = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var observerToken: Any?

    private static let cellId = NSUserInterfaceItemIdentifier("kura.appRow")

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

        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.addTableColumn(NSTableColumn(identifier: Self.cellId))

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = tableView
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

            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
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
        reload()
    }

    deinit {
        if let token = observerToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func reload() {
        tableView.reloadData()
        emptyLabel.isHidden = !RegistrationStore.shared.registeredApps.isEmpty
    }
}

extension KuraViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        RegistrationStore.shared.registeredApps.count
    }
}

extension KuraViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let apps = RegistrationStore.shared.registeredApps
        guard apps.indices.contains(row) else { return nil }

        let cell: AppRowView
        if let recycled = tableView.makeView(withIdentifier: Self.cellId, owner: self) as? AppRowView {
            cell = recycled
        } else {
            cell = AppRowView()
            cell.identifier = Self.cellId
        }
        cell.configure(with: apps[row])
        return cell
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

        nameLabel.font = NSFont.systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

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
