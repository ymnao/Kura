import AppKit
import ApplicationServices

enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        if isTrusted { return true }
        // kAXTrustedCheckOptionPrompt は Unmanaged<CFString> で Swift 6 strict-concurrency 下で扱いが
        // 不便。値は public な定数文字列 "AXTrustedCheckOptionPrompt" で安定しているので直接使う。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}
