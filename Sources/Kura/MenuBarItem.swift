import AppKit
import ApplicationServices

final class MenuBarItem {
    let title: String
    let element: AXUIElement

    init(title: String, element: AXUIElement) {
        self.title = title
        self.element = element
    }
}

enum ScanResult {
    case notRunning
    case failed(String)
    case items([MenuBarItem])
}
