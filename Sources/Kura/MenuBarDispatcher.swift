import AppKit
import ApplicationServices

enum MenuBarDispatcher {
    static func press(_ item: MenuBarItem) {
        let err = AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        if err != .success {
            NSLog("[Kura] press: \"%@\" err=%d", item.title, err.rawValue)
        }
    }
}
