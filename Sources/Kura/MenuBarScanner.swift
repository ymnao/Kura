import AppKit
import ApplicationServices

enum MenuBarScanner {
    private static let messagingTimeout: Float = 1.0

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

        var childrenRef: CFTypeRef?
        let childErr = AXUIElementCopyAttributeValue(extrasElement, kAXChildrenAttribute as CFString, &childrenRef)
        if childErr != .success {
            NSLog("[Kura] scan: %@ AXChildren err=%d", bundleId, childErr.rawValue)
            return .failed("AXChildren err=\(childErr.rawValue)")
        }
        guard let array = childrenRef as? [AnyObject] else {
            NSLog("[Kura] scan: %@ AXChildren wrong array type", bundleId)
            return .failed("AXChildren wrong array type")
        }
        let typeID = AXUIElementGetTypeID()
        var children: [AXUIElement] = []
        children.reserveCapacity(array.count)
        for value in array {
            guard CFGetTypeID(value) == typeID else {
                NSLog("[Kura] scan: %@ AXChildren wrong element type", bundleId)
                return .failed("AXChildren wrong element type")
            }
            children.append(value as! AXUIElement)
        }
        children.forEach { AXUIElementSetMessagingTimeout($0, messagingTimeout) }

        var items: [MenuBarItem] = []
        items.reserveCapacity(children.count)
        for child in children {
            if Task.isCancelled {
                NSLog("[Kura] scan: %@ cancelled", bundleId)
                return .failed("cancelled")
            }
            items.append(MenuBarItem(title: itemTitle(child), element: child))
        }
        NSLog("[Kura] scan: %@ children=%d", bundleId, children.count)
        return .items(items)
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
