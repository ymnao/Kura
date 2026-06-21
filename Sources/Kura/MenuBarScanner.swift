import AppKit
import ApplicationServices

enum MenuBarScanner {
    static func scan(_ app: RegisteredApp) -> [MenuBarItem] {
        let items = scanRaw(app)
        if items.isEmpty {
            return [MenuBarItem(title: "(メニュー項目なし)", element: nil)]
        }
        return items
    }

    private static func scanRaw(_ app: RegisteredApp) -> [MenuBarItem] {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first else {
            NSLog("[Kura] scan: not running: \(app.bundleIdentifier)")
            return []
        }
        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0)

        var extrasRef: CFTypeRef?
        let extrasErr = AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasRef)
        guard extrasErr == .success, let extras = extrasRef else {
            NSLog("[Kura] scan: \(app.bundleIdentifier) AXExtrasMenuBar err=\(extrasErr.rawValue)")
            return []
        }
        let extrasElement = extras as! AXUIElement

        var childrenRef: CFTypeRef?
        let childErr = AXUIElementCopyAttributeValue(extrasElement, kAXChildrenAttribute as CFString, &childrenRef)
        guard childErr == .success, let children = childrenRef as? [AXUIElement] else {
            NSLog("[Kura] scan: \(app.bundleIdentifier) AXChildren err=\(childErr.rawValue)")
            return []
        }
        NSLog("[Kura] scan: \(app.bundleIdentifier) children=\(children.count)")
        return children.map { child in
            MenuBarItem(title: itemTitle(child), element: child)
        }
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref
    }

    private static func itemTitle(_ element: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXRoleDescriptionAttribute] {
            if let value = copyAttribute(element, attr as String) as? String, !value.isEmpty {
                return value
            }
        }
        return "(無題)"
    }
}
