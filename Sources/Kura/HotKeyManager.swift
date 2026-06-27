import AppKit
import Carbon.HIToolbox

/// Carbon `RegisterEventHotKey` をラップする薄いマネージャ。
/// グローバルホットキー（例: ⌃⌥⌘K）で MainActor アクションを発火させる。
///
/// Carbon の event handler は MainActor 隔離されていない C コールバック経由で呼ばれるため、
/// callback 内では `DispatchQueue.main.async` + `MainActor.assumeIsolated` で MainActor に
/// 戻してから登録済みハンドラを呼ぶ。
///
/// Carbon を選んだ理由: `NSEvent.addGlobalMonitorForEvents` だとアクセシビリティ権限が
/// 別途必要（Kura は既に取得済みだが、ホットキー単独の手段としては重い）。
/// Carbon `RegisterEventHotKey` は権限不要で、deprecated でもない。
///
/// 単一ホットキー前提の設計（Kura は折りたたみトグルのみ使用）。複数ホットキーが必要になった時点で
/// registry/ID 払い出しを足すのは trivial なので、現状は最小構成にしておく。
///
/// ライフサイクル: HotKeyManager は AppDelegate のライフタイム = アプリ寿命と同じ。
/// プロセス終了時に OS が Carbon ホットキーを自動解除するため、明示的な
/// `UnregisterEventHotKey` は通常呼ばない。ただし環境設定からホットキーを差し替える場合は
/// `update(keyCode:modifiers:)` 内で旧 ref を unregister してから新 ref を登録する
/// (旧キーが OS 側に残ったままになるのを防ぐ)。
/// Swift 6 では `@MainActor` class の nonisolated deinit から non-Sendable な
/// `EventHotKeyRef` に触れないため、解放経路は deinit ではなく MainActor 上の `update` 経由のみ。
@MainActor
final class HotKeyManager {
    /// 同プロセス内に別の Carbon ホットキー利用者がいた場合の誤発火防止用シグネチャ。
    /// `nonisolated` にするのは Swift 6 で nonisolated callback (`dispatchHotKeyEvent`) から
    /// 参照するため。`let` だが `@MainActor` class 内のプロパティはデフォルトで MainActor 隔離されるので明示する。
    nonisolated private static let signature: OSType = 0x4B555241 // 'KURA'
    nonisolated private static let hotKeyID: UInt32 = 1

    private static var handler: (@MainActor () -> Void)?
    private static var sharedHandlerRef: EventHandlerRef?

    /// 現在登録中のホットキー ref。`update` で旧 ref を unregister するために instance で保持する。
    /// 登録失敗時は nil のまま（次回 update で再試行可能）。
    private var hotKeyRef: EventHotKeyRef?
    /// 現在 (もしくは直近に試みた) (keyCode, modifiers)。`update` 内の差分判定に使う。
    /// 登録失敗時も新値で更新するので、同じ値で繰り返し失敗を試行しない（別キーに変えれば再試行可能）。
    /// `.kuraPreferencesDidChange` は symbol / foldOnLaunch / appExclusion などホットキー以外でも飛んでくるため、
    /// 「無関係な通知で毎回 RegisterEventHotKey を叩く」コストを HotKeyManager 自身が吸収する責務を持つ。
    /// keyCode と modifiers は常に揃って更新するので tuple optional として 1 つの状態にまとめる
    /// （片方だけ nil / 片方だけ最新値、のような中間状態を型で排除する）。
    private var current: (keyCode: UInt32, modifiers: UInt32)?

    /// ホットキーを登録。`keyCode` は Carbon の VK 定数（例: `kVK_ANSI_K`）、
    /// `modifiers` は `cmdKey | optionKey | controlKey` 等の bitwise OR。
    /// `handler` は static slot に格納し、後続の `update` でも継続使用する
    /// （Kura は toggleFold のみ対象なので handler は不変）。
    /// EventHandler 登録 or HotKey 登録が失敗しても `handler` は代入する：
    /// 次回 `update` で install を再試行し成功すれば、この handler が以降の callback に使われる。
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) {
        // 単一 instance 前提（複数作ると Self.handler が上書きで誤発火源になる）。
        // production では AppDelegate に 1 個のみ。複数 init はテスト or 設計事故。
        assert(Self.handler == nil, "HotKeyManager は単一 instance 前提（Self.handler を上書きする運用は未サポート）")
        Self.handler = handler
        registerHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    /// 環境設定でホットキーが変更されたときに呼ぶ再登録経路。
    /// 同値なら no-op（呼び出し側で差分判定不要）、変化があったら旧 ref を `UnregisterEventHotKey` で解除してから新 ref を登録する。
    /// handler 自体は init 時のものを継続使用する。
    /// 旧 ref の解放に失敗しても新規登録は試みる（OS 側で残った場合でも、新規登録さえ成功すれば
    /// 自プロセスは新キーで反応する。Carbon は非排他登録なので旧キーが残っていても他害は限定的）。
    func update(keyCode: UInt32, modifiers: UInt32) {
        guard current?.keyCode != keyCode || current?.modifiers != modifiers else { return }
        unregisterHotKey()
        registerHotKey(keyCode: keyCode, modifiers: modifiers)
    }

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32) {
        // 共有 EventHandler が無いと RegisterEventHotKey はキーを予約するだけで自プロセスに届かない。
        // install は idempotent（sharedHandlerRef != nil なら即 true）なので毎回呼んでも安全。
        // 失敗時は current を更新せず、同値で再 update が来た時に再試行する経路を確保する。
        guard Self.installSharedHandlerIfNeeded() else {
            NSLog("[Kura] HotKey register skipped: shared handler not installed (retry on next update)")
            return
        }
        let eventID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, eventID,
                                         GetApplicationEventTarget(), 0, &ref)
        // RegisterEventHotKey 自体の失敗時は current を更新する（同値での無限再試行を回避、
        // 別キーに変更された時には差分判定で必ず再登録が走る）。
        current = (keyCode, modifiers)
        guard status == noErr, let ref = ref else {
            NSLog("[Kura] HotKey register failed status=\(status) keyCode=\(keyCode) modifiers=\(modifiers)")
            return
        }
        hotKeyRef = ref
        NSLog("[Kura] HotKey registered keyCode=\(keyCode) modifiers=\(modifiers)")
    }

    private func unregisterHotKey() {
        guard let ref = hotKeyRef else { return }
        let status = UnregisterEventHotKey(ref)
        if status != noErr {
            NSLog("[Kura] HotKey unregister failed status=\(status)")
        }
        hotKeyRef = nil
    }

    /// 共有ハンドラの登録を一度だけ試す。既に登録済み or 今回成功なら true、
    /// 失敗時のみ false を返す。呼び出し側はこの戻り値で「RegisterEventHotKey に進んで良いか」を判断する。
    private static func installSharedHandlerIfNeeded() -> Bool {
        if sharedHandlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
            { _, eventRef, _ in
                return HotKeyManager.dispatchHotKeyEvent(eventRef)
            },
            1, &spec, nil, &sharedHandlerRef)
        if status != noErr {
            NSLog("[Kura] HotKey InstallEventHandler failed status=\(status)")
            return false
        }
        return true
    }

    /// Carbon callback は MainActor 外で呼ばれる可能性があるため nonisolated。
    /// 同プロセス内に別の `RegisterEventHotKey` 利用者がいても Kura のトグルが
    /// 誤発火しないよう、signature と id で照合してから dispatch する。
    /// 戻り値: Kura のホットキーとして処理した場合は `noErr`、それ以外（ID 不一致 or
    /// パラメータ取得失敗）は `eventNotHandledErr` を返して、Carbon が後続ハンドラに
    /// イベントを伝播できるようにする。
    nonisolated static func dispatchHotKeyEvent(_ eventRef: EventRef?) -> OSStatus {
        guard let eventRef = eventRef else { return OSStatus(eventNotHandledErr) }
        var eventID = EventHotKeyID()
        let status = GetEventParameter(eventRef,
                                       EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID),
                                       nil,
                                       MemoryLayout<EventHotKeyID>.size,
                                       nil,
                                       &eventID)
        guard status == noErr,
              eventID.signature == signature,
              eventID.id == hotKeyID else { return OSStatus(eventNotHandledErr) }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                HotKeyManager.handler?()
            }
        }
        return noErr
    }
}
