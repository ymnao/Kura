import Foundation

/// 蔵対象アプリの並び順（bundleIdentifier の配列）を UserDefaults に永続化する。
/// popover 内のユーザー指定順序を保存し、`applied(to:)` で scan 結果に適用する。
/// 保存形式（bundleId 配列）と「未知 bundleId は末尾フォールバック」仕様を 1 箇所に集約する設計。
enum AppOrderStore {
    private static let key = "kura.appOrder"

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func save(_ orderedBundleIds: [String]) {
        UserDefaults.standard.set(orderedBundleIds, forKey: key)
    }

    /// 保存順を `apps` に適用する。
    /// - 保存順に登場する bundleId は順序通り前方に並ぶ
    /// - 未登録の bundleId は末尾に leftmostX 順で並ぶ（新規アプリは物理位置で末尾追加）
    /// 保存順が空（初回起動や永続化前）の場合は従来通り leftmostX 順を返す。
    static func applied(to apps: [StatusBarApp]) -> [StatusBarApp] {
        let order = load()
        guard !order.isEmpty else {
            return apps.sorted { $0.leftmostX < $1.leftmostX }
        }
        // 手動編集や将来の保存経路追加で重複 bundleId が混入しても trap せず先勝ちで採用する。
        var indexMap: [String: Int] = [:]
        for (idx, id) in order.enumerated() where indexMap[id] == nil {
            indexMap[id] = idx
        }
        return apps.sorted { lhs, rhs in
            switch (indexMap[lhs.bundleIdentifier], indexMap[rhs.bundleIdentifier]) {
            case (let a?, let b?): return a < b
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.leftmostX < rhs.leftmostX
            }
        }
    }
}
