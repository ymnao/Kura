import AppKit
import ApplicationServices

enum MenuBarScanner {
    private static let messagingTimeout: Float = 1.0

    static func scan(_ app: RegisteredApp) -> ScanResult {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier).first else {
            NSLog("[Kura] scan: not running: \(app.bundleIdentifier)")
            return .notRunning
        }
        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, messagingTimeout)

        let extrasResult = copyElement(axApp, attribute: "AXExtrasMenuBar", label: app.bundleIdentifier)
        let extrasElement: AXUIElement
        switch extrasResult {
        case .failure(let reason):
            return .failed("AXExtrasMenuBar \(reason)")
        case .success(let element):
            extrasElement = element
        }
        AXUIElementSetMessagingTimeout(extrasElement, messagingTimeout)

        var childrenRef: CFTypeRef?
        let childErr = AXUIElementCopyAttributeValue(extrasElement, kAXChildrenAttribute as CFString, &childrenRef)
        if childErr != .success {
            NSLog("[Kura] scan: \(app.bundleIdentifier) AXChildren err=\(childErr.rawValue)")
            return .failed("AXChildren err=\(childErr.rawValue)")
        }
        guard let array = childrenRef as? [AnyObject] else {
            return .items([])
        }
        let typeID = AXUIElementGetTypeID()
        let children: [AXUIElement] = array.compactMap {
            CFGetTypeID($0) == typeID ? ($0 as! AXUIElement) : nil
        }
        children.forEach { AXUIElementSetMessagingTimeout($0, messagingTimeout) }
        NSLog("[Kura] scan: \(app.bundleIdentifier) children=\(children.count)")
        return .items(children.map { MenuBarItem(title: itemTitle($0), element: $0) })
    }

    private enum CopyFailure: CustomStringConvertible {
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
            NSLog("[Kura] scan: \(label) \(attribute) err=\(err.rawValue)")
            return .failure(.axError(err))
        }
        guard let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            NSLog("[Kura] scan: \(label) \(attribute) wrong type")
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
