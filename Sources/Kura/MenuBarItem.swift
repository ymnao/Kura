import AppKit
import ApplicationServices

/// scan 完了時に Task.detached から MainActor へ渡される。中身は scan 完了後は変更しない
/// （AXUIElement への参照と確定済みプロパティのみ）ため `@unchecked Sendable` で適合させる。
/// 完全な型保証には AXUIElement の `@retroactive Sendable` 拡張または struct 化が必要。
final class MenuBarItem: @unchecked Sendable {
    let title: String
    let element: AXUIElement
    /// AXMenu 配下の AXMenuItem を子要素として保持。階層化されたメニューに対応。
    var children: [MenuBarItem] = []
    /// メニュー項目（AXMenuItem）か NSStatusItem アイコン（AXMenuBarItem）かを区別。
    /// AXMenuItem は直接 AXPress でアクション発火（アイコン展開なし）。
    var isMenuItem: Bool = false
    /// false なら AXPress 無効化。複数 NSStatusItem を持ち一部だけ蔵対象のアプリで
    /// 並び順入れ替えにより別項目を発火するリスクを fail-safe で防ぐ。
    var isExecutable: Bool = true
    /// AX の lazy loading でサブメニュー children が取得できなかった疑いがある項目。
    /// 折りたたみ中にこの項目を AXPress するとアプリの本物メニューが画面外（アイコン直下）に
    /// 開いてユーザーには見えない。代わりに一時的に展開してから AXPress する必要がある。
    /// 例: Claude の「状況メニュー」のように、メニューを開かないと中身が AX に出てこないアプリ。
    var needsExpandToFire: Bool = false
    /// cache 不完全項目の場合、ここに親 AXMenuBarItem（NSStatusItem アイコン本体）への参照を保存。
    /// AXPress 時はこれを優先して使い、アプリの本物 NSMenu をアイコン位置に開かせる。
    /// nil なら element を使う（通常パス）。
    var statusItemElement: AXUIElement?

    init(title: String, element: AXUIElement) {
        self.title = title
        self.element = element
    }
}

enum ScanResult: @unchecked Sendable {
    case notRunning
    case failed(String)
    case items([MenuBarItem])
}
