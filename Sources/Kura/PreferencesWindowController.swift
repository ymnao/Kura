import AppKit

/// 環境設定ウィンドウ。独立 NSWindow + NSWindowController で AppDelegate から 1 インスタンスのみ保持する。
/// 値変更は即座に `PreferencesStore` に書き戻し、`.kuraPreferencesDidChange` 経由で他箇所が追従する。
/// macOS の System Settings 流の即時反映 UX (Apply ボタンなし)。
@MainActor
final class PreferencesWindowController: NSWindowController {
    private var symbolPopUp: NSPopUpButton!
    private var foldOnLaunchCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kura 環境設定"
        // accessory app では window close で release されると AppDelegate の参照が dangle するため明示的に抑止。
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
        reloadFromStore()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let symbolLabel = NSTextField(labelWithString: "蔵アイコン:")

        let popUp = NSPopUpButton()
        for symbol in KuraSymbol.allCases {
            popUp.addItem(withTitle: symbol.displayName)
            popUp.lastItem?.representedObject = symbol
        }
        popUp.target = self
        popUp.action = #selector(symbolChanged(_:))
        self.symbolPopUp = popUp

        let symbolRow = NSStackView(views: [symbolLabel, popUp])
        symbolRow.orientation = .horizontal
        symbolRow.spacing = 8
        symbolRow.alignment = .firstBaseline

        let foldCheckbox = NSButton(checkboxWithTitle: "起動時に折りたたんでおく",
                                    target: self,
                                    action: #selector(foldOnLaunchChanged(_:)))
        self.foldOnLaunchCheckbox = foldCheckbox

        let launchCheckbox = NSButton(checkboxWithTitle: "Mac 起動時に Kura を自動で起動する",
                                      target: self,
                                      action: #selector(launchAtLoginChanged(_:)))
        self.launchAtLoginCheckbox = launchCheckbox

        let stack = NSStackView(views: [symbolRow, foldCheckbox, launchCheckbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20)
        ])
    }

    /// ウィンドウ表示直前に store の最新値で UI を同期する。
    /// `.kuraPreferencesDidChange` 経由で他ウィンドウから変更される想定は今のところないが、
    /// SMAppService の状態がシステム側で変わる (ユーザーがシステム設定で外す等) ケースに備える。
    private func reloadFromStore() {
        let currentSymbol = PreferencesStore.symbol
        if let idx = KuraSymbol.allCases.firstIndex(of: currentSymbol) {
            symbolPopUp.selectItem(at: idx)
        }
        foldOnLaunchCheckbox.state = PreferencesStore.foldOnLaunch ? .on : .off
        launchAtLoginCheckbox.state = PreferencesStore.launchAtLogin ? .on : .off
    }

    @objc private func symbolChanged(_ sender: NSPopUpButton) {
        guard let symbol = sender.selectedItem?.representedObject as? KuraSymbol else { return }
        PreferencesStore.symbol = symbol
    }

    @objc private func foldOnLaunchChanged(_ sender: NSButton) {
        PreferencesStore.foldOnLaunch = (sender.state == .on)
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        PreferencesStore.launchAtLogin = (sender.state == .on)
        // SMAppService.register/unregister が失敗してもチェックボックスの見た目が先に変わってしまうため、
        // store の真値で UI を再同期する (失敗時はチェックが元に戻る)。
        sender.state = PreferencesStore.launchAtLogin ? .on : .off
    }

    override func showWindow(_ sender: Any?) {
        reloadFromStore()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        // accessory app は通常 inactive なので、設定ウィンドウを開くときだけ前面に出す。
        NSApp.activate(ignoringOtherApps: true)
    }
}
