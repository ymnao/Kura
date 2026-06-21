import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 蔵本体（左クリックでポップオーバー、右クリックでメニュー）
    private var statusItem: NSStatusItem!
    /// セパレータ（折りたたみ時に length 膨張、蔵の左に置かれる前提）
    private var separatorItem: NSStatusItem!
    private var popover: NSPopover!

    private static let expandedSeparatorLength: CGFloat = 8
    /// macOS の NSStatusItem.length 上限は 10000pt。画面幅の 2 倍 (Hidden Bar 流) でクランプ。
    private static var collapsedSeparatorLength: CGFloat {
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        return max(500, min(screenWidth * 2, 10_000))
    }

    private var isFolded: Bool {
        separatorItem.length > Self.expandedSeparatorLength
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Kura] launch: AXIsProcessTrusted=\(AccessibilityPermission.requestIfNeeded())")
        setupStatusItem()
        setupSeparatorItem()
        setupPopover()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "kura.main"
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        button.title = "蔵"
        button.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// セパレータ NSStatusItem。
    /// - 通常時: length=expandedSeparatorLength（細い縦線、視認可能）
    /// - 折りたたみ時: length=collapsedSeparatorLength（左隣のアイコンを画面外に押し出す）
    /// length を効かせるためには button.image が必須（content がないと length が反映されない）。
    /// 透明 image だと「ユーザーが ⌘+ドラッグで動かせない」ので、薄い縦線アイコンを使う（Hidden Bar 方式）。
    private func setupSeparatorItem() {
        separatorItem = NSStatusBar.system.statusItem(withLength: Self.expandedSeparatorLength)
        separatorItem.autosaveName = "kura.separator"
        separatorItem.isVisible = true
        if let button = separatorItem.button {
            button.image = Self.separatorImage
            button.imagePosition = .imageOnly
            button.title = ""
            // セパレータはユーザーが間違ってクリックしても何も起きないように target/action を設定しない。
        }
    }

    /// セパレータ用の薄い縦線 image (template image)。
    /// ⌘+ドラッグでつかむためにある程度の幅とコントラストが必要。
    private static let separatorImage: NSImage = {
        let size = NSSize(width: 6, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let bar = NSRect(x: 2, y: 1, width: 2, height: 16)
        NSColor.black.setFill()
        bar.fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }()

    /// 蔵がセパレータの右にあるか（=折りたたみが意味を持つ配置か）。
    /// ユーザーが ⌘+ドラッグで「セパレータを蔵の左」に置く必要がある。
    private var isSeparatorOnLeftOfMain: Bool {
        guard let mainX = statusItem.button?.window?.frame.minX,
              let sepX = separatorItem.button?.window?.frame.minX else {
            return false
        }
        return sepX < mainX
    }

    @objc private func handleScreenParametersChanged() {
        // 折りたたみ中に画面構成が変わったら collapse length を計算し直す。
        if isFolded {
            separatorItem.length = Self.collapsedSeparatorLength
        }
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        let vc = KuraViewController()
        vc.onItemActivated = { [weak self] in
            self?.popover.performClose(nil)
        }
        popover.contentViewController = vc
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            if let vc = popover.contentViewController as? KuraViewController {
                let kuraX = button.window?.frame.minX ?? -.greatestFiniteMagnitude
                vc.refreshTargets(kuraX: kuraX)
            }
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()

        let foldTitle = isFolded ? "展開する" : "折りたたむ"
        let foldItem = NSMenuItem(title: foldTitle, action: #selector(toggleFold(_:)), keyEquivalent: "")
        foldItem.target = self
        if !isFolded && !isSeparatorOnLeftOfMain {
            foldItem.isEnabled = false
            foldItem.toolTip = "セパレータを蔵の左に ⌘+ドラッグしてから使ってください"
        }
        menu.addItem(foldItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Kura を終了", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // 通常メニューの自動有効化を切る（isEnabled の手動制御を効かせるため）
        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func toggleFold(_ sender: Any?) {
        if isFolded {
            separatorItem.length = Self.expandedSeparatorLength
        } else {
            guard isSeparatorOnLeftOfMain else { return }
            separatorItem.length = Self.collapsedSeparatorLength
        }
        NSLog("[Kura] toggleFold: isFolded=\(isFolded) sepLen=\(separatorItem.length)")
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
