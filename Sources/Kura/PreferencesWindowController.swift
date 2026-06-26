import AppKit

/// 環境設定ウィンドウ。独立 NSWindow + NSWindowController で AppDelegate から 1 インスタンスのみ保持する。
/// 値変更は即座に `PreferencesStore` / `AppExclusionStore` に書き戻し、
/// `.kuraPreferencesDidChange` 経由で他箇所が追従する。
/// macOS の System Settings 流の即時反映 UX (Apply ボタンなし)。
///
/// タブ構成:
/// - 「一般」: 蔵アイコン symbol / 起動時 fold / 自動起動
/// - 「対象アプリ」: 蔵対象アプリの除外チェックボックス一覧 (NSTableView)
/// - 「ホットキー」: 折りたたみ／展開トグルのキーカスタマイズ (HotKeyRecorderView)
@MainActor
final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private var symbolPopUp: NSPopUpButton!
    private var foldOnLaunchCheckbox: NSButton!
    private var launchAtLoginCheckbox: NSButton!
    private var appsTableView: NSTableView!
    private var displayedApps: [DisplayedApp] = []
    /// 一覧の空状態メッセージ。AX 走査前 / 蔵対象アプリがない場合に表示する。
    private var appsEmptyLabel: NSTextField!
    private var hotKeyRecorder: HotKeyRecorderView!

    convenience init() {
        // `.miniaturizable` を含めない: accessory app は Dock アイコンを持たないため、
        // 一度 minimize すると window を復帰させる経路 (Dock クリック等) がなく詰むため。
        // 「対象アプリ」タブの NSTableView が入るため、foundation 期より広く取る (480x340)。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
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
        // 除外切り替えで自分が post した通知も拾い、ウィンドウ表示中に再 reload する。
        // (チェック切り替え → AppExclusionStore.save → post → reloadAppsTable で UI が真値に追従)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePreferencesDidChange),
            name: .kuraPreferencesDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func buildContent() {
        // NSWindow(contentRect:...) で生成した window の contentView は AppKit が必ず作るため
        // force unwrap で OK。defensive な guard は IUO 未代入による後続クラッシュを隠してしまう。
        let contentView = window!.contentView!

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.tabViewType = .topTabsBezelBorder

        let generalItem = NSTabViewItem(identifier: "general")
        generalItem.label = "一般"
        generalItem.view = buildGeneralTab()
        tabView.addTabViewItem(generalItem)

        let appsItem = NSTabViewItem(identifier: "apps")
        appsItem.label = "対象アプリ"
        appsItem.view = buildAppsTab()
        tabView.addTabViewItem(appsItem)

        let hotKeyItem = NSTabViewItem(identifier: "hotkey")
        hotKeyItem.label = "ホットキー"
        hotKeyItem.view = buildHotKeyTab()
        tabView.addTabViewItem(hotKeyItem)

        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    private func buildGeneralTab() -> NSView {
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

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16)
        ])
        return container
    }

    private func buildAppsTab() -> NSView {
        let description = NSTextField(wrappingLabelWithString:
            "蔵に格納するアプリを選んでください。チェックを外したアプリは蔵に入らず、メニューバーに残ります。")
        description.font = .systemFont(ofSize: 11)
        description.textColor = .secondaryLabelColor

        let scrollView = NSScrollView()
        scrollView.borderType = .bezelBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let tableView = NSTableView()
        // 単一カラム + AppRowView を採用。複数カラム + 個別 cell view にすると view 再利用が
        // 列ごとに分散し、チェックボックスの target/action 接続を毎回張り直す必要が増えるため
        // 1 行 1 view にして「chcekbox/icon/name の関係」を AppRowView に閉じ込める。
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppRow"))
        column.title = ""
        column.resizingMask = .autoresizingMask
        column.minWidth = 200
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.style = .plain
        tableView.usesAlternatingRowBackgroundColors = true
        // チェックボックスが行内にあるので行選択ハイライトは不要 (二重に「選択」状態が見えると混乱)。
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        self.appsTableView = tableView

        scrollView.documentView = tableView

        let emptyLabel = NSTextField(wrappingLabelWithString:
            "蔵対象のアプリがまだ見つかっていません。\nメニューバー走査が完了するまで少しお待ちください。")
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        self.appsEmptyLabel = emptyLabel

        // emptyLabel を scrollView 上にオーバーレイする (NSStackView の中だとサイズが切り詰められるため
        // scrollView と兄弟関係にして同じ frame に重ねる)。
        let container = NSView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        description.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(description)
        container.addSubview(scrollView)
        container.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            description.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            description.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            description.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),

            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: scrollView.widthAnchor, constant: -32)
        ])
        return container
    }

    private func buildHotKeyTab() -> NSView {
        let description = NSTextField(wrappingLabelWithString:
            "蔵の折りたたみ／展開を切り替えるグローバルショートカット。\nフィールドをクリックしてから、Control / Option / Shift / Command と組み合わせたキーを押してください。")
        description.font = .systemFont(ofSize: 11)
        description.textColor = .secondaryLabelColor

        let label = NSTextField(labelWithString: "折りたたみ／展開:")

        let recorder = HotKeyRecorderView(hotKey: PreferencesStore.hotKey)
        recorder.onChange = { newHotKey in
            PreferencesStore.hotKey = newHotKey
        }
        self.hotKeyRecorder = recorder

        let row = NSStackView(views: [label, recorder])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let resetButton = NSButton(title: "デフォルトに戻す (⌃⌥⌘K)",
                                   target: self,
                                   action: #selector(resetHotKey(_:)))
        resetButton.bezelStyle = .rounded

        let stack = NSStackView(views: [row, resetButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        description.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(description)
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            description.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            description.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            description.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),

            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: description.bottomAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -16)
        ])
        return container
    }

    /// 「対象アプリ」タブのデータソース。AppDelegate から showPreferences 時に注入される。
    /// 表示行 = 「現在 scan で見えているアプリ」+「除外済みだが scan に出ていない bundleId」の union。
    /// 後者を含めることで、起動していない除外アプリも一覧に表示でき、除外解除が可能になる。
    func setScanResult(_ apps: [StatusBarApp]) {
        displayedApps = buildDisplayedApps(scanResult: apps)
        reloadAppsTable()
    }

    private func reloadAppsTable() {
        guard let tableView = appsTableView else { return }
        tableView.reloadData()
        appsEmptyLabel.isHidden = !displayedApps.isEmpty
    }

    private func buildDisplayedApps(scanResult: [StatusBarApp]) -> [DisplayedApp] {
        // excluded を mutable な「未消費」集合として扱い、scan で見つけたものから順に remove する。
        // - remove の戻り値 (削除された element / nil) で「除外対象だったか」を bool 化して isExcluded に詰める
        // - ループ後に残った要素 = 「除外済みだが scan に出ていない bundleId」= 末尾補完対象
        // これにより seen Set + 2 度の Set 走査 (subtracting) を避ける。
        var unseenExcluded = AppExclusionStore.load()
        var result: [DisplayedApp] = []
        result.reserveCapacity(scanResult.count + unseenExcluded.count)
        for app in scanResult {
            let wasExcluded = unseenExcluded.remove(app.bundleIdentifier) != nil
            result.append(DisplayedApp(
                bundleId: app.bundleIdentifier,
                name: app.name,
                icon: app.icon,
                isExcluded: wasExcluded
            ))
        }
        // 残った unseenExcluded = アプリが起動していない or 蔵より右にいて scan 対象外、等。
        // 並び順を安定させるため sorted する (Set の列挙順は非決定的)。
        // bundleId からの (icon, name) 逆引きは StatusBarApp.lookupInfo に集約済み。
        for bundleId in unseenExcluded.sorted() {
            let info = StatusBarApp.lookupInfo(bundleId: bundleId)
            result.append(DisplayedApp(
                bundleId: bundleId,
                name: info.name,
                icon: info.icon,
                isExcluded: true
            ))
        }
        return result
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
        // hotKey は recorder の onChange 経路では recorder 側で先に self.hotKey が更新されているが、
        // 「デフォルトに戻す」ボタン経由や外部からの変更でも UI を真値に追従させる。
        hotKeyRecorder?.hotKey = PreferencesStore.hotKey
    }

    @objc private func handlePreferencesDidChange() {
        // 設定値が変わったタイミングで table の isExcluded を真値で塗り直す。
        // (チェック切り替え → AppExclusionStore.save → post でここに戻ってくる)
        // scanResult 自体は変わっていないので bundleId/name/icon は保持したまま isExcluded だけ更新する。
        // 「除外済みだが現在 displayedApps にない bundleId」を足す処理はここではしない:
        // それは次回 setScanResult (環境設定ウィンドウを開き直し) で補完される。
        // ここで足してしまうと scan が空の瞬間に除外解除した行が消えるレースを起こす。
        let excluded = AppExclusionStore.load()
        displayedApps = displayedApps.map {
            DisplayedApp(bundleId: $0.bundleId, name: $0.name, icon: $0.icon,
                         isExcluded: excluded.contains($0.bundleId))
        }
        reloadAppsTable()
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

    @objc private func resetHotKey(_ sender: NSButton) {
        // 既定値が現在値と同じなら setter で post を skip するため、明示的に store の真値で UI も同期する。
        PreferencesStore.hotKey = .default
        reloadFromStore()
    }

    override func showWindow(_ sender: Any?) {
        reloadFromStore()
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        // accessory app は通常 inactive なので、設定ウィンドウを開くときだけ前面に出す。
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("AppRowCell")
        let view: AppRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? AppRowView {
            view = reused
        } else {
            view = AppRowView()
            view.identifier = identifier
        }
        // configure 内で bundleId / 状態を更新するため、callback も毎回張り直す
        // (cell view 再利用で違う行に流用されるため、closure 内の bundleId が古いままにならないように)。
        view.onCheckChanged = { bundleId, isChecked in
            // チェック ON = 蔵に入れる = excluded false
            // チェック OFF = 蔵に入れない = excluded true
            AppExclusionStore.setExcluded(bundleId, excluded: !isChecked)
        }
        view.configure(with: displayedApps[row])
        return view
    }
}

/// 「対象アプリ」タブの 1 行分。bundleId と表示用メタデータ + 現在の除外状態。
private struct DisplayedApp {
    let bundleId: String
    let name: String
    let icon: NSImage?
    let isExcluded: Bool
}

/// NSTableView の 1 行を構成する view。チェックボックス + アイコン + アプリ名を NSStackView で横並びに。
/// AppKit の cell-based table は deprecated 推奨なので view-based を使う。
private final class AppRowView: NSTableCellView {
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    /// 現在この cell view が紐づいている bundleId。configure() で毎回更新される。
    /// checkbox の target/action がこの value を closure 経由で読むので、再利用時に必ず上書きする。
    private var currentBundleId: String?
    /// 親 (PreferencesWindowController) が configure 後に毎回張り直す。
    var onCheckChanged: ((String, Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        checkbox.target = self
        checkbox.action = #selector(checkboxToggled(_:))
        iconView.imageScaling = .scaleProportionallyDown
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.cell?.usesSingleLineMode = true

        let stack = NSStackView(views: [checkbox, iconView, nameLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            // name label は残りを占有 (hugging を低くして拡張可能に)
        ])
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with app: DisplayedApp) {
        currentBundleId = app.bundleId
        checkbox.state = app.isExcluded ? .off : .on
        // 起動していない除外アプリ等で icon が nil の場合は placeholder を出す (空白だと違和感がある)。
        iconView.image = app.icon ?? NSImage(systemSymbolName: "questionmark.app.dashed",
                                             accessibilityDescription: "未取得")
        nameLabel.stringValue = app.name
    }

    @objc private func checkboxToggled(_ sender: NSButton) {
        guard let id = currentBundleId else { return }
        onCheckChanged?(id, sender.state == .on)
    }
}
