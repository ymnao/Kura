import AppKit
import ApplicationServices

enum MenuBarDispatcher {
    static func press(_ item: MenuBarItem) {
        // cache 不完全項目（needsExpandToFire）には親 AXMenuBarItem を保存してある。
        // それを AXPress すれば「アイコンクリック相当」になり、アプリが本物 NSMenu を表示。
        // 通常項目では nil なので element（AXMenuItem）を直接 AXPress する。
        let target = item.statusItemElement ?? item.element
        let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
        let usingStatusItem = item.statusItemElement != nil
        NSLog("[Kura] press: \"%@\" usingStatusItem=%d err=%d", item.title, usingStatusItem ? 1 : 0, err.rawValue)
    }
}
