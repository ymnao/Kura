import Foundation

/// 蔵対象から除外するアプリ (bundleIdentifier) を UserDefaults に永続化する。
/// 「位置で見つかった蔵対象 (= 蔵より左の NSStatusItem 保有アプリ)」のうち、
/// ユーザーが明示的に蔵に格納したくないと指定したアプリを除外する。
/// AppOrderStore と同じく static methods で 1 箇所に集約する設計。
/// 値変更時に `.kuraPreferencesDidChange` を post し、購読側 (AppDelegate) が
/// 現在の scan 結果に再フィルタを適用して popover を更新する (scan 再走は不要)。
enum AppExclusionStore {
    private static let key = "kura.appExclusion"

    /// 除外済み bundleId の Set。未設定なら空集合。
    /// UserDefaults には Array で保存し、読み出し時に Set 化する。
    static func load() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
    }

    /// 除外集合をまるごと保存する。
    /// 同値なら post を skip し、無駄な再 filter / 通知を抑止する。
    /// 同値判定は Set で行い (要素順非依存)、UserDefaults への書き込み時のみ sorted Array に
    /// 変換することで plist diff も安定させる。
    static func save(_ excluded: Set<String>) {
        let current = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard excluded != current else { return }
        UserDefaults.standard.set(excluded.sorted(), forKey: key)
        NotificationCenter.default.post(name: .kuraPreferencesDidChange, object: nil)
    }

    /// 除外済み bundleId を除いて返す。順序は保持する。
    /// 空集合のケースを早期 return することで scan 結果の Array をそのまま返す
    /// (大半のユーザーは除外なしで使う想定のため、ホットパスを軽くする)。
    static func filtered(_ apps: [StatusBarApp]) -> [StatusBarApp] {
        let excluded = load()
        guard !excluded.isEmpty else { return apps }
        return apps.filter { !excluded.contains($0.bundleIdentifier) }
    }

    /// 単一アプリの除外フラグを切り替える。
    /// `excluded: true` で除外リストに追加、`false` で外す。
    /// 同値の場合は save 側の早期 return で何もしない。
    static func setExcluded(_ bundleId: String, excluded: Bool) {
        var set = load()
        if excluded {
            set.insert(bundleId)
        } else {
            set.remove(bundleId)
        }
        save(set)
    }
}
