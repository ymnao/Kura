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
        // `.miniaturizable` を含めない: accessory app は Dock アイコンを持たないため、
        // 一度 minimize すると window を復帰させる経路 (Dock クリック等) がなく詰むため。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Kura 環境設定"
        // accessory app では window close で release されると AppDelegate の参照が dangle するため明示的に抑止。
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildContent()
        // showWindow を経由しない経路 (NSWindow restoration 等) でも UI が初期値で残らないよう、
        // ここでも初期値を流し込む。showWindow も冒頭で reloadFromStore を呼ぶが idempotent。
        reloadFromStore()
    }

    private func buildContent() {
        // NSWindow(contentRect:...) で生成した window の contentView は AppKit が必ず作るため
        // force unwrap で OK。defensive な guard は IUO 未代入による後続クラッシュを隠してしまう。
        let contentView = window!.contentView!

        let symbolLabel = NSTextField(labelWithString: "蔵アイコン:")

        let popUp = NSPopUpButton()
        // addItem(withTitle:) は重複タイトルがあると既存項目を再利用するため、representedObject を
        // lastItem? に置く方式だと将来 displayName が衝突したときに silent footgun を生む。
        // NSMenuItem を直接生成して menu に add することで重複を許容する。
        for symbol in KuraSymbol.allCases {
            let item = NSMenuItem(title: symbol.displayName, action: nil, keyEquivalent: "")
            item.representedObject = symbol
            popUp.menu?.addItem(item)
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
        let idx = symbolPopUp.indexOfItem(withRepresentedObject: PreferencesStore.symbol)
        if idx >= 0 {
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
        // store の真値で UI を全部再同期する (失敗時はチェックが元に戻る)。
        reloadFromStore()
    }

    override func showWindow(_ sender: Any?) {
        reloadFromStore()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        // accessory app は通常 inactive なので、設定ウィンドウを開くときだけ前面に出す。
        NSApp.activate(ignoringOtherApps: true)
    }
}
