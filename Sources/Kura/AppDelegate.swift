import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, FoldController {
    /// 蔵本体（左クリックでポップオーバー、右クリックでメニュー）
    private var statusItem: NSStatusItem!
    /// セパレータ（折りたたみ時に length 膨張、蔵の左に置かれる前提）
    private var separatorItem: NSStatusItem!
    private var popover: NSPopover!

    /// 蔵対象アプリの単一データソース。AppDelegate がスキャンの責任を持ち、
    /// 折りたたみ中も展開中も同じキャッシュを表示することで一貫性を保つ。
    private var lastScanResult: [StatusBarApp] = []
    private var scanTask: Task<Void, Never>?

    private static let expandedSeparatorLength: CGFloat = 8
    private static var collapsedSeparatorLength: CGFloat {
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        return max(500, min(screenWidth * 2, 10_000))
    }

    var isFolded: Bool {
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
        // 起動 0.5 秒後に初回 scan を仕込む。権限プロンプト中は空になる可能性があるので
        // ポップオーバー開時にも再 scan する設計でカバーする。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startScan()
        }
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

    private func setupSeparatorItem() {
        separatorItem = NSStatusBar.system.statusItem(withLength: Self.expandedSeparatorLength)
        separatorItem.autosaveName = "kura.separator"
        separatorItem.isVisible = true
        if let button = separatorItem.button {
            button.image = Self.separatorImage
            button.imagePosition = .imageOnly
            button.title = ""
        }
    }

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

    private var isSeparatorOnLeftOfMain: Bool {
        guard let mainX = statusItem.button?.window?.frame.minX,
              let sepX = separatorItem.button?.window?.frame.minX else {
            return false
        }
        return sepX < mainX
    }

    @objc private func handleScreenParametersChanged() {
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
        vc.foldController = self
        popover.contentViewController = vc
    }

    /// 非同期 scan。折りたたみ中は AX position が画面外で意味がないのでスキップ。
    /// 完了時に lastScanResult を更新し、ポップオーバーが開いていれば反映する。
    private func startScan() {
        guard !isFolded else { return }
        guard let button = statusItem.button else { return }
        let kuraX = button.window?.frame.minX ?? -.greatestFiniteMagnitude
        scanTask?.cancel()
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let apps = MenuBarLayoutScanner.scanLeftOfKura(kuraX: kuraX)
            await self?.applyScanResult(apps)
        }
    }

    private func applyScanResult(_ apps: [StatusBarApp]) {
        scanTask = nil
        lastScanResult = apps
        // ポップオーバーが開いていて、展開中なら表示も最新化
        if popover.isShown, !isFolded,
           let vc = popover.contentViewController as? KuraViewController {
            vc.setTargets(apps)
        }
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
                // 折りたたみ中も展開中も lastScanResult を直接表示。
                vc.setTargets(lastScanResult)
                // 展開中だけ裏で scan を更新（ポップオーバー閉じる→開くで最新化）
                if !isFolded {
                    startScan()
                }
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

        menu.autoenablesItems = false
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func toggleFold(_ sender: Any?) {
        if isFolded {
            separatorItem.length = Self.expandedSeparatorLength
        } else {
            guard isSeparatorOnLeftOfMain else { return }
            // キャッシュが空ならフォールバックで同期 scan を 1 回走らせる。
            // これにより warmup が間に合わなかった場合でも folded 中の表示が必ず動く。
            if lastScanResult.isEmpty, let button = statusItem.button {
                let kuraX = button.window?.frame.minX ?? -.greatestFiniteMagnitude
                lastScanResult = MenuBarLayoutScanner.scanLeftOfKura(kuraX: kuraX)
            }
            separatorItem.length = Self.collapsedSeparatorLength
        }
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
