import ApplicationServices

/// AX (Accessibility) API の小さなラッパ群。MenuBarScanner / MenuBarLayoutScanner で共有。
enum AXHelpers {
    /// 他アプリの AX 呼び出しのタイムアウト。
    /// 折りたたみコミット前に位置 scan + 全 AppNode メニュー詳細 scan の完了を await するため、
    /// 1 つのアプリが timeout 限界まで粘ると fold レイテンシに直結する。実機では応答時間が
    /// ms オーダーなので 0.5 秒で十分。
    /// timeout 短縮の副作用: top-level (`AXExtrasMenuBar` / `AXChildren`) が `cannotComplete`
    /// を返した場合は `MenuBarLayoutScanner` 側で `.noStatusItems` に倒すため、対象アプリから
    /// silent に外れる (fold はブロックされない)。一方 per-item の `kAXPositionAttribute` で
    /// `cannotComplete` が出ると `.transientFailure` → `failedBundleIds` 入りで fold をブロックする。
    /// 0.5-1.0s 帯のアプリで両者が起きうるため、実機計測 (foldTiming NSLog) で支障が出たら戻す。
    static let messagingTimeout: Float = 0.5

    /// 属性値を取り出す（生 CFTypeRef）。
    static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref
    }

    /// 属性値を AXUIElement として取り出す。
    static func copyElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// AXChildren を取り出す。各 child に messagingTimeout も設定する。
    static func copyChildren(_ element: AXUIElement) -> [AXUIElement]? {
        guard let array = copyAttribute(element, kAXChildrenAttribute as String) as? [AnyObject] else {
            return nil
        }
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
}
