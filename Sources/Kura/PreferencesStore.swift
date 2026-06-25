import Foundation
import ServiceManagement

/// 蔵のメニューバーアイコンに使う SF Symbol。
/// 各値は `xxx`（展開中）と `xxx.fill`（折りたたみ中）の 2 つにマップされる前提のため、
/// `.fill` バリアントを持つ symbol のみを追加する。
enum KuraSymbol: String, CaseIterable {
    case archivebox
    case tray
    case shippingbox
    case squareStack = "square.stack"

    var expandedSymbolName: String { rawValue }
    var foldedSymbolName: String { "\(rawValue).fill" }

    var displayName: String {
        switch self {
        case .archivebox:  return "蔵 (archivebox)"
        case .tray:        return "トレイ (tray)"
        case .shippingbox: return "ボックス (shippingbox)"
        case .squareStack: return "スタック (square.stack)"
        }
    }
}

extension Notification.Name {
    /// 環境設定値が変わったことを通知する。AppDelegate がアイコン再描画等で購読する。
    static let kuraPreferencesDidChange = Notification.Name("kura.preferences.didChange")
}

/// 環境設定を UserDefaults / SMAppService に永続化する単一エントリ。
/// 値変更時に `.kuraPreferencesDidChange` を post し、購読側が UI を追従する。
/// AppOrderStore と同じく static methods で 1 箇所に集約する設計。
enum PreferencesStore {
    private enum Keys {
        static let symbolName   = "kura.symbol.name"
        static let foldOnLaunch = "kura.foldOnLaunch"
    }

    /// 蔵アイコンの symbol。未設定時は archivebox。
    static var symbol: KuraSymbol {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.symbolName) ?? KuraSymbol.archivebox.rawValue
            return KuraSymbol(rawValue: raw) ?? .archivebox
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.symbolName)
            NotificationCenter.default.post(name: .kuraPreferencesDidChange, object: nil)
        }
    }

    /// アプリ起動時に自動で折りたたんでおくか。default false。
    static var foldOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.foldOnLaunch) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.foldOnLaunch)
            NotificationCenter.default.post(name: .kuraPreferencesDidChange, object: nil)
        }
    }

    /// Mac 起動時に Kura を自動起動するか。
    /// 真の source of truth は SMAppService 側の登録状態なので UserDefaults には保存しない。
    /// register/unregister が throw した場合はログに出して値変更を無視（UI 側で再描画して整合）。
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("[Kura] PreferencesStore.launchAtLogin set(%@) failed: %@",
                      newValue ? "true" : "false",
                      String(describing: error))
            }
            NotificationCenter.default.post(name: .kuraPreferencesDidChange, object: nil)
        }
    }
}
