import AppKit
import ApplicationServices

enum MenuBarDispatcher {
    @discardableResult
    static func press(_ item: MenuBarItem) -> AXError {
        let err = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        if err != .success {
            NSLog("[Kura] press: \"\(item.title)\" err=\(err.rawValue)")
        }
        return err
    }
}
