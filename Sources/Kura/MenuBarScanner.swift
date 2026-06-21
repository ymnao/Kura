import AppKit
import ApplicationServices

enum MenuBarScanner {
    static func scan(_ app: RegisteredApp) -> [MenuBarItem] {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first else {
            NSLog("[Kura] scan: not running: \(app.bundleIdentifier)")
            return []
        }
        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0)

        guard let extras = copyAttributeLogging(axApp, "AXExtrasMenuBar", label: app.bundleIdentifier) else { return [] }
        let extrasElement = extras as! AXUIElement

        guard let raw = copyAttributeLogging(extrasElement, kAXChildrenAttribute as String, label: app.bundleIdentifier),
              let children = raw as? [AXUIElement] else { return [] }

        NSLog("[Kura] scan: \(app.bundleIdentifier) children=\(children.count)")
        return children.map { MenuBarItem(title: itemTitle($0), element: $0) }
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        guard err == .success else { return nil }
        return ref
    }

    private static func copyAttributeLogging(_ element: AXUIElement, _ attribute: String, label: String) -> AnyObject? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
        if err != .success {
            NSLog("[Kura] scan: \(label) \(attribute) err=\(err.rawValue)")
            return nil
        }
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
