import AppKit
import ApplicationServices

enum MenuBarScanner {
    /// AXMenu と AXMenuItem の両方で depth が +1 されるため、ユーザーから見たメニュー階層 N つを
    /// 確実に拾うには `maxDepth = 2N` 必要。3〜4 階層のサブメニューまでカバーするため 8 に設定。
    private static let maxDepth = 8

    static func scan(_ app: StatusBarApp) -> ScanResult {
        let bundleId = app.bundleIdentifier
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, AXHelpers.messagingTimeout)

        guard let extrasElement = AXHelpers.copyElement(axApp, attribute: "AXExtrasMenuBar") else {
            NSLog("[Kura] scan: %@ AXExtrasMenuBar fail", bundleId)
            return .failed("AXExtrasMenuBar fail")
        }
        AXUIElementSetMessagingTimeout(extrasElement, AXHelpers.messagingTimeout)

        guard let children = AXHelpers.copyChildren(extrasElement) else {
            NSLog("[Kura] scan: %@ extras children fail", bundleId)
            return .failed("AXChildren fail")
        }
        // 折りたたみ中にアプリが NSStatusItem を追加/削除した場合、保存済み index が
        // 別項目を指してしまう。children 数の一致で layout drift を検出して失敗扱いにする。
        guard children.count == app.menuBarItemCount else {
            NSLog("[Kura] scan: %@ layout drift expected=%d actual=%d", bundleId, app.menuBarItemCount, children.count)
            return .failed("status item layout changed")
        }

        var items: [MenuBarItem] = []
        items.reserveCapacity(app.menuBarIndices.count)
        // 位置でフィルタすると折りたたみ中（対象アイコンが画面外で x<=0）に弾かれてしまうため、
        // MenuBarLayoutScanner が記録した「対象 NSStatusItem の index」で識別する。
        // 同 count での入れ替え/並び替えは AX レイヤーでは安定した識別ができないため検出できない。
        // 「複数 NSStatusItem を持ち一部だけ対象」のアプリでは並び替えで別項目を発火するリスクが
        // あるため、fail-safe として isExecutable = false にして AXPress を抑止する。
        let canExecute = !app.isPartialTarget
        for (index, child) in children.enumerated() {
            if Task.isCancelled {
                return .failed("cancelled")
            }
            guard app.menuBarIndices.contains(index) else { continue }
            let item = MenuBarItem(title: itemTitle(child), element: child)
            item.isMenuItem = false  // AXMenuBarItem (NSStatusItem アイコン)
            let rawChildren = extractMenuItems(from: child, depth: 0)
            let collapsed = collapseSingleChainAtRoot(rawChildren)
            // partial target のアプリだけ isExecutable=false で全階層を抑止する。
            // それ以外は MenuBarItem.isExecutable のデフォルト (true) に任せる（冗長な再帰を避ける）。
            if !canExecute {
                item.isExecutable = false
                propagateDisabled(collapsed)
            }
            item.children = collapsed
            items.append(item)
        }
        // AppNode 直下も同じく単項目チェーン collapse を適用。
        // 1 アプリが NSStatusItem を 1 個だけ持つ場合、その AXMenuBarItem 自体（例:
        // 「状況メニュー」）をスキップして、その配下のメニュー項目を AppNode 直下に昇格。
        let topLevel = collapseSingleChainAtRoot(items)
        // cache 不完全判定: collapse 後の root が「単一かつ children 空」なら、AX で menu 詳細が
        // 取れていない疑い。AXMenuItem (例: Alfred の状況メニュー的なもの) でも、AXMenuBarItem
        // (例: Claude のように AX に何も公開しないアプリ) でも、どちらも対象。
        // 折りたたみ中の AXPress では本物メニューが画面外に開くので、一時展開が必要。
        // AXPress 対象は親 AXMenuBarItem (アイコン本体) を使い、アプリの本物 NSMenu を確実に開く。
        if topLevel.count == 1, topLevel[0].children.isEmpty {
            topLevel[0].needsExpandToFire = true
            topLevel[0].statusItemElement = items.first?.element
        }
        NSLog("[Kura] scan: %@ statusItems=%d topLevel=%d", bundleId, items.count, topLevel.count)
        return .items(topLevel)
    }

    /// 全 children に再帰的に isExecutable=false を伝播する。partial target アプリで
    /// サブメニューを含めて発火不可にする目的。MenuBarItem.isExecutable のデフォルトは true なので
    /// 「無効化」方向のみ実装すれば足りる。
    private static func propagateDisabled(_ items: [MenuBarItem]) {
        for item in items {
            item.isExecutable = false
            propagateDisabled(item.children)
        }
    }

    /// root レベルが単一項目のチェーンを短絡する。複数項目が現れた時点で停止。
    /// 例: [状況メニュー] → [サブ] → [a, b, c] なら、結果は [a, b, c]。
    /// 一旦複数項目が現れた以降の階層（途中で 1 項目だけになっても）は構造を保つ。
    private static func collapseSingleChainAtRoot(_ items: [MenuBarItem]) -> [MenuBarItem] {
        var current = items
        while current.count == 1, !current[0].children.isEmpty {
            current = current[0].children
        }
        return current
    }

    /// AXMenuBarItem の配下から AXMenu → AXMenuItem を再帰的に抜き出す。
    /// AXMenuItem を直接 AXPress すればアイコン展開なしでアクション発火できるはず。
    private static func extractMenuItems(from element: AXUIElement, depth: Int) -> [MenuBarItem] {
        guard depth < maxDepth else { return [] }
        guard let children = AXHelpers.copyChildren(element) else { return [] }

        var result: [MenuBarItem] = []
        for child in children {
            if Task.isCancelled { return result }
            let role = (AXHelpers.copyAttribute(child, kAXRoleAttribute as String) as? String) ?? ""
            if role == (kAXMenuRole as String) {
                // AXMenu: その中の AXMenuItem を再帰で取り出して flat に追加
                result.append(contentsOf: extractMenuItems(from: child, depth: depth + 1))
            } else if role == (kAXMenuItemRole as String) {
                // AXTitle が無い項目はセパレータや無名項目なので除外する。
                // AXRoleDescription（「メニュー項目」など）でフォールバックすると
                // セパレータがノイズとして表示されるため使わない。
                guard let title = realTitle(child) else { continue }
                let item = MenuBarItem(title: title, element: child)
                item.isMenuItem = true
                item.children = extractMenuItems(from: child, depth: depth + 1)
                result.append(item)
            }
        }
        return result
    }

    /// AXTitle / AXDescription のいずれかでタイトルを取得。
    /// AXRoleDescription はセパレータでも値を返すため使用しない（ノイズ排除）。
    private static func realTitle(_ element: AXUIElement) -> String? {
        if let v = AXHelpers.copyAttribute(element, kAXTitleAttribute as String) as? String, !v.isEmpty {
            return v
        }
        if let v = AXHelpers.copyAttribute(element, kAXDescriptionAttribute as String) as? String, !v.isEmpty {
            return v
        }
        return nil
    }

    /// 表示用フォールバック付きタイトル（AXMenuBarItem の表示名など、無題でも何か返す必要がある）。
    private static func itemTitle(_ element: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXRoleDescriptionAttribute] {
            if let value = AXHelpers.copyAttribute(element, attr as String) as? String, !value.isEmpty {
                return value
            }
        }
        return "(無題)"
    }

}
