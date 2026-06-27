import Foundation
import Carbon.HIToolbox
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

/// 折りたたみ／展開トグルのグローバルホットキー設定。
/// keyCode/modifiers は Carbon `RegisterEventHotKey` に直接渡せる形式で保持し、
/// display は UI 再表示用に「⌃⌥⌘K」のような文字列を予め組み立てて保存する
/// （keyboard layout 変更時の再計算を避け、保存時点で確定させる方針）。
struct KuraHotKey: Equatable {
    let keyCode: UInt32
    /// Carbon の bitwise flag (`cmdKey | optionKey | controlKey | shiftKey`)。
    let modifiers: UInt32
    let display: String

    /// v0.5 から続く既定値: ⌃⌥⌘K。
    /// 環境設定でカスタマイズされていない時 / 破損値で復帰するときの fallback でもある。
    static let `default` = KuraHotKey(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        display: "⌃⌥⌘K"
    )
}

/// 環境設定を UserDefaults / SMAppService に永続化する単一エントリ。
/// 値変更時に `.kuraPreferencesDidChange` を post し、購読側が UI を追従する。
/// AppOrderStore と同じく static methods で 1 箇所に集約する設計。
/// @MainActor 隔離: 購読側 (AppDelegate.handlePreferencesDidChange) が main thread で UI を触るため、
/// post も main thread で行う不変条件を型レベルで保証する。
@MainActor
enum PreferencesStore {
    private enum Keys {
        static let symbolName       = "kura.symbol.name"
        static let foldOnLaunch     = "kura.foldOnLaunch"
        static let hotKeyKeyCode    = "kura.hotKey.keyCode"
        static let hotKeyModifiers  = "kura.hotKey.modifiers"
        static let hotKeyDisplay    = "kura.hotKey.display"
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

    /// 折りたたみ／展開トグルのグローバルホットキー。
    /// getter: 3 つの key が揃って読めた場合のみその値、いずれかが欠けていたら `.default` (⌃⌥⌘K)。
    ///         keyCode == 0 (= 未設定や破損) も `.default` に倒す
    ///         (kVK_ANSI_A=0 とは別物。Carbon RegisterEventHotKey に 0 を渡すと未定義動作)。
    ///         UserDefaults は Int で保存しているため、64bit プラットフォームでは UInt32 範囲外の値も
    ///         入りうる。`UInt32(exactly:)` で truncation を防ぎ、範囲外なら `.default` に倒す。
    ///         display は空文字でも `.default` に倒さない (setter 経路の `displayString` は
    ///         最低 1 文字を保証するため空が来るのは外部 `defaults write` で値を "" にした場合のみ。
    ///         空 → button 表示が空になる UI 劣化はあるが、ユーザーの keyCode/modifiers 設定を
    ///         silent に上書きするより hotkey 機能を維持する方を優先する)。
    ///         display キー自体の欠落 (= 一度も保存されていない状態) は他フィールドと同じく
    ///         `.default` に倒す。
    /// setter: 既存値と Equatable 比較し同値なら post を skip (foldOnLaunch / symbol と同じ流儀)。
    ///         3 つの key を atomic に書き換える保証はないが、UserDefaults は最終的に flush されるので
    ///         次回読み込み時には揃って入っている前提でよい。
    static var hotKey: KuraHotKey {
        get {
            let defaults = UserDefaults.standard
            let rawKeyCode = defaults.object(forKey: Keys.hotKeyKeyCode) as? Int
            let rawModifiers = defaults.object(forKey: Keys.hotKeyModifiers) as? Int
            let display = defaults.string(forKey: Keys.hotKeyDisplay)
            guard let rawKeyCode = rawKeyCode,
                  let rawModifiers = rawModifiers,
                  let display = display,
                  let keyCode = UInt32(exactly: rawKeyCode), keyCode > 0,
                  let modifiers = UInt32(exactly: rawModifiers) else {
                return .default
            }
            return KuraHotKey(
                keyCode: keyCode,
                modifiers: modifiers,
                display: display
            )
        }
        set {
            guard newValue != hotKey else { return }
            let defaults = UserDefaults.standard
            defaults.set(Int(newValue.keyCode), forKey: Keys.hotKeyKeyCode)
            defaults.set(Int(newValue.modifiers), forKey: Keys.hotKeyModifiers)
            defaults.set(newValue.display, forKey: Keys.hotKeyDisplay)
            NotificationCenter.default.post(name: .kuraPreferencesDidChange, object: nil)
        }
    }
}
