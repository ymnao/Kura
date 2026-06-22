import AppKit
import ApplicationServices

final class MenuBarItem {
    let title: String
    let element: AXUIElement
    /// AXMenu 配下の AXMenuItem を子要素として保持。階層化されたメニューに対応。
    var children: [MenuBarItem] = []
    /// メニュー項目（AXMenuItem）か NSStatusItem アイコン（AXMenuBarItem）かを区別。
    /// AXMenuItem は直接 AXPress でアクション発火（アイコン展開なし）。
    var isMenuItem: Bool = false

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
