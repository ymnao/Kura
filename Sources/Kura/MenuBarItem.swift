import AppKit
import ApplicationServices

struct MenuBarItem {
    let title: String
    let element: AXUIElement
}

enum ScanResult {
    case notRunning
    case failed(String)
    case items([MenuBarItem])
}
