import AppKit

final class KuraViewController: NSViewController {
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private var observerToken: Any?

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

        listStack.orientation = .vertical
        listStack.spacing = 4
        listStack.alignment = .leading
        listStack.distribution = .fill
        listStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = listStack
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
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            listStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 8),
            listStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -8),
            listStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -16),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])

        view = container

        observerToken = NotificationCenter.default.addObserver(
            forName: Settings.didChange, object: nil, queue: .main
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
        for v in listStack.arrangedSubviews {
            listStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }

        let apps = Settings.shared.registeredApps
        emptyLabel.isHidden = !apps.isEmpty

        for app in apps {
            listStack.addArrangedSubview(makeRow(for: app))
        }
    }

    private func makeRow(for app: RegisteredApp) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        }
        row.addSubview(iconView)

        let label = NSTextField(labelWithString: app.name)
        label.font = NSFont.systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        let hint = NSTextField(labelWithString: "v0.2…")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(hint)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            hint.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            hint.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            hint.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            row.heightAnchor.constraint(equalToConstant: 30),
        ])

        return row
    }
}
