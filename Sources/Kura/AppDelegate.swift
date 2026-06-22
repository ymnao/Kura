import AppKit
import Carbon.HIToolbox
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, FoldController {
    /// 蔵本体（左クリックでポップオーバー、右クリックでメニュー）
    private var statusItem: NSStatusItem!
    /// セパレータ（折りたたみ時に length 膨張、蔵の左に置かれる前提）
    private var separatorItem: NSStatusItem!
    private var popover: NSPopover!
    /// グローバルホットキー（⌃⌥⌘K で折りたたみ／展開トグル）。
    /// アプリ寿命と同じライフタイムで保持し、プロセス終了時に OS が Carbon ホットキーを自動解除する。
    private var hotKeyManager: HotKeyManager?

    /// 蔵対象アプリの単一データソース。AppDelegate がスキャンの責任を持ち、
    /// 折りたたみ中も展開中も同じキャッシュを表示することで一貫性を保つ。
    private var lastScanResult: [StatusBarApp] = []
    private var scanTask: Task<Void, Never>?
    /// 古い scan 完了が新しい結果を上書きしないよう世代管理する。
    /// startScan で +1、applyScanResult で世代一致のみ反映。
    private var scanGeneration: Int = 0
    /// 認可済み scan が一度でも成功したか。warmup の重複 kick をスキップするフラグ。
    /// 「lastScanResult が空でない」では正常な空 (.items([])) と未認可を区別できないため別フラグにする。
    private var didCompleteAuthorizedScan: Bool = false
    /// 直近の layout scan の生 result。`.items` 以外（未認可/キャンセル）なら最新の cache が
    /// 信用できない状態なので、折りたたみコミット時の判定に使う。
    private var lastLayoutScanResult: ScanLayoutResult?
    /// 折りたたみコミット待ち中フラグ。true の間は新規 scan kick を抑止し、
    /// 「待っている scan task が完了直後に別の scan に差し替わって commitFold が cache 未確定で走る」競合を防ぐ。
    private var isCommittingFold: Bool = false

    private static let expandedSeparatorLength: CGFloat = 8
    /// 折りたたみ length は「現在繋がっている全画面の最大幅」で十分。
    /// 画面幅 × 2 を試したが macOS のメニューバー再レイアウトが重く感じる原因になっていた。
    /// 単一画面で 1710 → 半分に短縮、ノッチを跨ぐ場合も論理長さは画面幅で覆える。
    private static var collapsedSeparatorLength: CGFloat {
        let screenWidth = NSScreen.screens.map { $0.frame.width }.max() ?? 1728
        return max(500, min(screenWidth, 10_000))
    }

    /// 開閉アニメーション設定。短すぎると瞬間遷移と区別しづらく、長すぎると操作の応答性が損なわれる。
    /// 180ms はメニューバー再レイアウトの体感コストとフィードバックの分かりやすさのバランス点。
    private static let foldAnimationDuration: TimeInterval = 0.18
    private static let foldAnimationFrameInterval: TimeInterval = 1.0 / 60.0
    private var animationTimer: Timer?
    private var animationStartTime: CFTimeInterval = 0
    private var animationStartLength: CGFloat = 0
    private var animationTargetLength: CGFloat = 0
    private var animationDuration: TimeInterval = 0

    var isFolded: Bool {
        separatorItem.length > Self.expandedSeparatorLength
    }

    /// FoldController 実装。cache 不完全な項目クリック時の選択的自動展開で使われる。
    func expandIfFolded() {
        if isFolded {
            animateSeparatorLength(to: Self.expandedSeparatorLength)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[Kura] launch: AXIsProcessTrusted=\(AccessibilityPermission.requestIfNeeded())")
        setupStatusItem()
        setupSeparatorItem()
        setupPopover()
        setupHotKey()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        // warmup scan を複数タイミングで kick。
        // AccessibilityPermission プロンプトに対応するため、ユーザーが許可するであろう
        // 時間帯に複数回試す。認可済み scan が一度成功したら以降はスキップ。
        for delay in [0.5, 2.0, 5.0, 10.0] as [Double] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.didCompleteAuthorizedScan else { return }
                self.startScan()
            }
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
        let newCollapsed = Self.collapsedSeparatorLength
        if animationTimer != nil {
            // アニメ中は target を更新するだけ。展開方向 (target=expanded) のアニメは触らない
            // ことで「展開しようとしていたら勝手に折りたたみに転じる」を防ぐ。
            if animationTargetLength > Self.expandedSeparatorLength {
                animationTargetLength = newCollapsed
            }
        } else if isFolded {
            separatorItem.length = newCollapsed
        }
    }

    /// separatorItem.length をフレーム駆動で補間する。NSStatusItem は NSAnimatablePropertyContainer 非準拠
    /// なので animator() プロキシは使えず、Timer で手動補間する。
    /// 進行中のアニメは invalidate して新規アニメに差し替えるので、向きが変わるトグル連打にも追随する。
    private func animateSeparatorLength(to targetLength: CGFloat, duration: TimeInterval = AppDelegate.foldAnimationDuration) {
        animationTimer?.invalidate()
        animationStartLength = separatorItem.length
        animationTargetLength = targetLength
        animationStartTime = CACurrentMediaTime()
        animationDuration = duration
        // RunLoop.common に追加することで、右クリックメニュー表示中などの tracking mode 中もアニメ継続。
        let timer = Timer(
            timeInterval: Self.foldAnimationFrameInterval,
            target: self,
            selector: #selector(tickAnimation),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    @objc private func tickAnimation() {
        let elapsed = CACurrentMediaTime() - animationStartTime
        let progress = min(max(elapsed / animationDuration, 0), 1)
        if progress >= 1 {
            separatorItem.length = animationTargetLength
            animationTimer?.invalidate()
            animationTimer = nil
            return
        }
        // easeInOutQuad: 慣性のある自然な動きで、メニューバー再レイアウト負荷も中央でピーク。
        let eased: Double = progress < 0.5
            ? 2 * progress * progress
            : 1 - pow(-2 * progress + 2, 2) / 2
        separatorItem.length = animationStartLength + (animationTargetLength - animationStartLength) * CGFloat(eased)
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

    /// ⌃⌥⌘K で折りたたみ／展開トグル（詳細は ARCHITECTURE.md）。
    private func setupHotKey() {
        hotKeyManager = HotKeyManager(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(controlKey | optionKey | cmdKey)
        ) { [weak self] in
            self?.toggleFold(nil)
        }
    }

    /// 非同期 scan。折りたたみ中は AX position が画面外で意味がないのでスキップ。
    /// 折りたたみコミット待ち中も新規 scan を抑止して競合を防ぐ。
    /// 完了時に lastScanResult を更新し、ポップオーバーが開いていれば反映する。
    /// 蔵の座標が取れない場合は scan を kick せず、再試行可能な状態を保持する
    /// （フォールバック値で kick すると filter が無効になり、cache を空で上書きしてしまうため）。
    private func startScan() {
        guard !isFolded, !isCommittingFold else { return }
        guard let window = statusItem.button?.window else { return }
        let kuraX = window.frame.minX
        // 蔵が乗っているスクリーンを特定。マルチディスプレイで「別画面の正常な要素」を
        // 誤って蔵対象にしてしまわないよう、scan 側のフィルタで使う。
        let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let kuraScreenFrame = screen?.frame else { return }
        // NSScreen.frame は AppKit 左下原点、kAXPositionAttribute は主画面左上原点 (Y 下向き) なので
        // scan で contains 判定するために AX 座標系へ変換する。
        let mainHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? screen!).frame.height
        let kuraScreenFrameInAX = CGRect(
            x: kuraScreenFrame.origin.x,
            y: mainHeight - kuraScreenFrame.origin.y - kuraScreenFrame.height,
            width: kuraScreenFrame.width,
            height: kuraScreenFrame.height
        )
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = MenuBarLayoutScanner.scanLeftOfKura(kuraX: kuraX, kuraScreenFrameInAX: kuraScreenFrameInAX)
            await self?.applyScanResult(result, generation: generation)
        }
    }

    private func applyScanResult(_ result: ScanLayoutResult, generation: Int) {
        // 古い scan 完了は無視。Task.cancel() は signal だけで中身は走り切るため、
        // 完了タイミングが入れ替わって新しい結果を上書きするのを防ぐ。
        guard generation == scanGeneration else { return }
        scanTask = nil
        lastLayoutScanResult = result
        let summary: String
        switch result {
        case .unauthorized:
            // 権限なし: 前回キャッシュを保護（空で上書きしない）
            summary = "unauthorized"
        case .cancelled:
            // 途中キャンセル: 結果は信用できないので何もしない
            summary = "cancelled"
        case .items(let apps, let failedBundleIds):
            // 部分成功を許容するマージ戦略:
            //   - 一時失敗 (failedBundleIds) の bundle は前回キャッシュから保持
            //   - ただし同じ bundleId が今回 apps にも入っているケース（同 bundleId 複数プロセス等）は
            //     重複を避けるため成功分を優先し、preserved 側で除外する
            let successBundles = Set(apps.map { $0.bundleIdentifier })
            let preservedFromCache = lastScanResult.filter {
                failedBundleIds.contains($0.bundleIdentifier) && !successBundles.contains($0.bundleIdentifier)
            }
            lastScanResult = (apps + preservedFromCache).sorted { $0.leftmostX < $1.leftmostX }
            // 一時失敗が残っている間は warmup を停止しない（起動直後の AX 不安定状態で
            // キャッシュ未確立のまま打ち切るのを防ぐ）。
            if failedBundleIds.isEmpty {
                didCompleteAuthorizedScan = true
            }
            summary = "items(\(apps.count) failed=\(failedBundleIds.count) preserved=\(preservedFromCache.count))"
        }
        NSLog("[Kura] applyScanResult result=%@ lastScanResult=%d", summary, lastScanResult.count)
        // popover が開いていなくても VC に反映。
        // 次回ポップオーバー表示時に最新 cache が表示され、各 AppNode のメニュー詳細も
        // setTargets 内で事前 scan される（折りたたみ後の AX 制限を避ける目的）。
        if !isFolded, let vc = popover.contentViewController as? KuraViewController {
            vc.setTargets(lastScanResult)
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
                // startScan 内部で座標未取得時の guard があるため、ここでは無条件呼び出しでよい。
                if !isFolded {
                    startScan()
                }
            }
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        // メニュー操作（数百 ms ある）の裏で scan を kick。
        // 「ポップオーバーを開かずに折りたたみ」の場合でも、cache 最新化を間に合わせる狙い。
        startScan()

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
            animateSeparatorLength(to: Self.expandedSeparatorLength)
            return
        }
        guard isSeparatorOnLeftOfMain else { return }
        guard !isCommittingFold else { return }  // 二重起動防止
        // 初回起動直後・権限直後でまだ一度も scan が走っていなければ、ここで kick してから待つ。
        // （warmup scan を待たずに「折りたたむ」を選んだケースで alert を回避する）
        if scanTask == nil, lastLayoutScanResult == nil {
            startScan()
        }
        // 折りたたみ前に scan を全て完了させる:
        // 1. AppDelegate.scanTask（位置情報スキャン）
        // 2. KuraViewController の各 AppNode のメニュー詳細 scan
        //    Claude のような「メニューが画面外だと AX children を返さない」アプリの cache を
        //    折りたたみ前に確定させる必要がある（折りたたみ後だと AXPress も画面外で空振り）。
        // isCommittingFold = true で新規 scan kick を抑止し、scan task が差し替わる競合を防ぐ。
        isCommittingFold = true
        Task { @MainActor [weak self] in
            if let task = self?.scanTask {
                _ = await task.value
            }
            var detailScansOk = true
            if let vc = self?.popover.contentViewController as? KuraViewController {
                detailScansOk = await vc.waitForAllScansAndCheckSuccess()
            }
            guard let self = self else { return }
            self.isCommittingFold = false
            // 最新の layout scan が .items かつ failedBundleIds が空（= 全アプリで scan 成功）の場合のみ
            // folded を許可。部分失敗 (failedBundleIds に bundleId が積まれている) では、その bundle が
            // 初回 scan なら cache 未確立で folded 後に操作不能になるため、ブロック。
            let layoutOk: Bool
            if case .items(_, let failedBundleIds) = self.lastLayoutScanResult {
                layoutOk = failedBundleIds.isEmpty
            } else {
                layoutOk = false
            }
            guard layoutOk, detailScansOk else {
                self.showFoldUnavailableAlert(layoutOk: layoutOk, detailOk: detailScansOk)
                return
            }
            self.commitFold()
        }
    }

    private func showFoldUnavailableAlert(layoutOk: Bool, detailOk: Bool) {
        let reason: String
        if !layoutOk {
            reason = "アクセシビリティ権限を許可して、メニューバー走査が成功してから再度お試しください。"
        } else if !detailOk {
            reason = "対象アプリのメニュー走査に失敗しました。少し時間を置いて再度お試しください。"
        } else {
            reason = "折りたたみ前の確認に失敗しました。"
        }
        let alert = NSAlert()
        alert.messageText = "折りたためません"
        alert.informativeText = reason
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if !layoutOk {
            alert.addButton(withTitle: "システム設定を開く")
        }
        let response = alert.runModal()
        if !layoutOk, response == .alertSecondButtonReturn {
            AccessibilityPermission.openSystemSettings()
        }
    }

    private func commitFold() {
        let target = Self.collapsedSeparatorLength
        animateSeparatorLength(to: target)
        NSLog("[Kura] commitFold target=%.0f lastScanResult=%d", target, lastScanResult.count)
    }

    @objc private func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
