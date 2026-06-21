import AppKit
import ApplicationServices

enum MenuBarScanner {
    static func scan(_ app: RegisteredApp) -> [MenuBarItem] {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first else {
            return []
        }
        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0)

        guard let extras = copyAttribute(axApp, "AXExtrasMenuBar") else { return [] }
        let extrasElement = extras as! AXUIElement

        guard let raw = copyAttribute(extrasElement, kAXChildrenAttribute as String),
              let children = raw as? [AXUIElement] else { return [] }

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
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let value = copyAttribute(element, attr as String) as? String, !value.isEmpty {
                return value
            }
        }
        return "(無題)"
    }
}
