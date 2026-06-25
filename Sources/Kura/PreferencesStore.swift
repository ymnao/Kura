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
    /// カグラバチ（神薙）モチーフ。SF Symbols 5 (macOS 14+) で導入。
    case bubbles = "bubbles.and.sparkles"

    var expandedSymbolName: String { rawValue }
    var foldedSymbolName: String { "\(rawValue).fill" }

    var displayName: String {
        switch self {
        case .archivebox:  return "蔵 (archivebox)"
        case .tray:        return "トレイ (tray)"
        case .shippingbox: return "ボックス (shippingbox)"
        case .squareStack: return "スタック (square.stack)"
        case .bubbles:     return "泡 (bubbles)"
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
/// @MainActor 隔離: 購読側 (AppDelegate.handlePreferencesDidChange) が main thread で UI を触るため、
/// post も main thread で行う不変条件を型レベルで保証する。
@MainActor
enum PreferencesStore {
    private enum Keys {
        static let symbolName   = "kura.symbol.name"
        static let foldOnLaunch = "kura.foldOnLaunch"
    }

    /// 蔵アイコンの symbol。
    /// getter: 未設定 / 破損 (未知 rawValue) なら .archivebox に fallback。副作用なし。
    /// setter: UserDefaults に保存されている **生の rawValue** と比較するため、
    ///         getter の fallback で隠された破損値もユーザー操作で自己修復できる。
    static var symbol: KuraSymbol {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.symbolName),
                  let symbol = KuraSymbol(rawValue: raw) else {
                return .archivebox
            }
            return symbol
        }
        set {
            let storedRaw = UserDefaults.standard.string(forKey: Keys.symbolName)
            guard storedRaw != newValue.rawValue else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.symbolName)
            NotificationCenter.default.post(name: .kuraPreferencesDidChange, object: nil)
        }
    }

    /// アプリ起動時に自動で折りたたんでおくか。default false。
    static var foldOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.foldOnLaunch) }
        set {
            guard newValue != foldOnLaunch else { return }
            UserDefaults.standard.set(newValue, forKey: Keys.foldOnLaunch)
            NotificationCenter.default.post(name: .kuraPreferencesDidChange, object: nil)
        }
    }

    /// Mac 起動時に Kura を自動起動するか。
    /// 真の source of truth は SMAppService 側の登録状態なので UserDefaults には保存しない。
    /// register/unregister が throw した場合は実際の status は変わっていないので post を skip し、
    /// 購読側に「変わった」と誤通知しない。UI 側 (PreferencesWindowController) は
    /// launchAtLoginChanged の reloadFromStore() で checkbox を真値に戻す。
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            guard newValue != launchAtLogin else { return }
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                NotificationCenter.default.post(name: .kuraPreferencesDidChange, object: nil)
            } catch {
                NSLog("[Kura] PreferencesStore.launchAtLogin set(%@) failed: %@",
                      newValue ? "true" : "false",
                      String(describing: error))
                // 失敗時は post しない（status が変わっていないため）。
            }
        }
    }
}
