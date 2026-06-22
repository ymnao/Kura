import ApplicationServices

/// AX (Accessibility) API の小さなラッパ群。MenuBarScanner / MenuBarLayoutScanner で共有。
enum AXHelpers {
    /// 他アプリの AX 呼び出しのタイムアウト。1.0 秒で問題ないことが実機で確認済み。
    static let messagingTimeout: Float = 1.0

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
