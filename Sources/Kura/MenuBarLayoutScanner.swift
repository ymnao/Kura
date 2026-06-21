import AppKit
import ApplicationServices

/// 蔵対象アプリ（NSStatusItem を持ち、蔵より左にアイコンを置いているアプリ）
struct StatusBarApp: Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let pid: pid_t
    let leftmostX: CGFloat

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
    }
}

enum MenuBarLayoutScanner {
    private static let messagingTimeout: Float = 1.0

    /// 蔵より左に NSStatusItem を持つアプリを左端 x 座標順に列挙する。
    /// kuraX は蔵自身のメニューバーアイコンの x 座標（スクリーン座標）。
    /// x <= 0 は Control Center のドロップダウン hidden item や画面外の NSStatusItem を表すので除外する。
    static func scanLeftOfKura(kuraX: CGFloat) -> [StatusBarApp] {
        guard AccessibilityPermission.isTrusted else {
            return []
        }
        let myPid = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
            .filter { $0.processIdentifier != myPid }

        var byBundle: [String: StatusBarApp] = [:]
        for app in runningApps {
            guard let bundleId = app.bundleIdentifier else { continue }
            let leftXs = statusItemXs(pid: app.processIdentifier).filter { $0 < kuraX && $0 > 0 }
            guard let minX = leftXs.min() else { continue }
            let name = app.localizedName ?? bundleId
            let candidate = StatusBarApp(
                bundleIdentifier: bundleId,
                name: name,
                pid: app.processIdentifier,
                leftmostX: minX
            )
            if let existing = byBundle[bundleId], existing.leftmostX <= minX {
                continue
            }
            byBundle[bundleId] = candidate
        }
        return byBundle.values.sorted { $0.leftmostX < $1.leftmostX }
    }

    private static func statusItemXs(pid: pid_t) -> [CGFloat] {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

        var extrasRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasRef)
        guard err == .success,
              let extrasValue = extrasRef,
              CFGetTypeID(extrasValue) == AXUIElementGetTypeID() else {
            return []
        }
        let extras = extrasValue as! AXUIElement
        AXUIElementSetMessagingTimeout(extras, messagingTimeout)

        var childrenRef: CFTypeRef?
        let childErr = AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute as CFString, &childrenRef)
        guard childErr == .success,
              let array = childrenRef as? [AnyObject] else {
            return []
        }

        var result: [CGFloat] = []
        result.reserveCapacity(array.count)
        for raw in array {
            guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
            let element = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(element, messagingTimeout)

            var posRef: CFTypeRef?
            let posErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
            guard posErr == .success, let posValue = posRef else { continue }
            guard CFGetTypeID(posValue) == AXValueGetTypeID() else { continue }
            let axValue = posValue as! AXValue
            guard AXValueGetType(axValue) == .cgPoint else { continue }
            var point = CGPoint.zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else { continue }
            result.append(point.x)
        }
        return result
    }
}
