import AppKit
import ApplicationServices

enum MenuBarScanner {
    private static let messagingTimeout: Float = 1.0
    private static let maxDepth = 4

    static func scan(_ app: StatusBarApp) -> ScanResult {
        let bundleId = app.bundleIdentifier
        let axApp = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

        let extrasResult = copyElement(axApp, attribute: "AXExtrasMenuBar", label: bundleId)
        let extrasElement: AXUIElement
        switch extrasResult {
        case .failure(let reason):
            return .failed("AXExtrasMenuBar \(reason)")
        case .success(let element):
            extrasElement = element
        }
        AXUIElementSetMessagingTimeout(extrasElement, messagingTimeout)

        guard let children = copyChildren(extrasElement) else {
            NSLog("[Kura] scan: %@ extras children fail", bundleId)
            return .failed("AXChildren fail")
        }

        var items: [MenuBarItem] = []
        items.reserveCapacity(children.count)
        for child in children {
            if Task.isCancelled {
                return .failed("cancelled")
            }
            let item = MenuBarItem(title: itemTitle(child), element: child)
            item.isMenuItem = false  // AXMenuBarItem (NSStatusItem アイコン)
            let rawChildren = extractMenuItems(from: child, depth: 0)
            item.children = collapseSingleChainAtRoot(rawChildren)
            items.append(item)
        }
        // AppNode 直下も同じく単項目チェーン collapse を適用。
        // 1 アプリが NSStatusItem を 1 個だけ持つ場合、その AXMenuBarItem 自体（例:
        // 「状況メニュー」）をスキップして、その配下のメニュー項目を AppNode 直下に昇格。
        let topLevel = collapseSingleChainAtRoot(items)
        NSLog("[Kura] scan: %@ statusItems=%d topLevel=%d", bundleId, items.count, topLevel.count)
        return .items(topLevel)
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
        guard let children = copyChildren(element) else { return [] }

        var result: [MenuBarItem] = []
        for child in children {
            if Task.isCancelled { return result }
            let role = (copyAttribute(child, kAXRoleAttribute as String) as? String) ?? ""
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
        if let v = copyAttribute(element, kAXTitleAttribute as String) as? String, !v.isEmpty {
            return v
        }
        if let v = copyAttribute(element, kAXDescriptionAttribute as String) as? String, !v.isEmpty {
            return v
        }
        return nil
    }

    private static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)
        if err != .success { return nil }
        guard let array = ref as? [AnyObject] else { return nil }
        let typeID = AXUIElementGetTypeID()
        var result: [AXUIElement] = []
        result.reserveCapacity(array.count)
        for value in array {
            guard CFGetTypeID(value) == typeID else { continue }
            let element = value as! AXUIElement
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            result.append(element)
        }
        return result
    }

    private enum CopyFailure: Error, CustomStringConvertible {
        case axError(AXError)
        case wrongType

        var description: String {
            switch self {
            case .axError(let err): return "err=\(err.rawValue)"
            case .wrongType: return "wrong type"
            }
        }
    }

    private static func copyElement(_ element: AXUIElement, attribute: String, label: String) -> Result<AXUIElement, CopyFailure> {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        if err != .success {
            NSLog("[Kura] scan: %@ %@ err=%d", label, attribute, err.rawValue)
            return .failure(.axError(err))
        }
        guard let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            NSLog("[Kura] scan: %@ %@ wrong type", label, attribute)
            return .failure(.wrongType)
        }
        return .success(value as! AXUIElement)
    }

    private static func itemTitle(_ element: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXRoleDescriptionAttribute] {
            if let value = copyAttribute(element, attr as String) as? String, !value.isEmpty {
                return value
            }
        }
        return "(無題)"
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref
    }
}
