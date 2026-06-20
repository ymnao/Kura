import AppKit

final class KuraViewController: NSViewController {
    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 420))

        let title = NSTextField(labelWithString: "蔵")
        title.font = NSFont.systemFont(ofSize: 32, weight: .bold)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Kura — menu bar tucker")
        subtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)

        let status = NSTextField(labelWithString: "蔵は空です。\n(次フェーズで登録UI実装)")
        status.font = NSFont.systemFont(ofSize: 12)
        status.textColor = .tertiaryLabelColor
        status.alignment = .center
        status.translatesAutoresizingMaskIntoConstraints = false
        status.maximumNumberOfLines = 0
        container.addSubview(status)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 40),

            subtitle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),

            status.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            status.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 60),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 20),
            status.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
        ])

        view = container
    }
}
