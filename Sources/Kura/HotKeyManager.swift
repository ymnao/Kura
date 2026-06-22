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
/// 単一ホットキー前提の設計（Kura は ⌃⌥⌘K のみ使用）。複数ホットキーが必要になった時点で
/// registry/ID 払い出しを足すのは trivial なので、現状は最小構成にしておく。
///
/// ライフサイクル: HotKeyManager は AppDelegate のライフタイム = アプリ寿命と同じ。
/// プロセス終了時に OS が Carbon ホットキーを自動解除するため、明示的な
/// `UnregisterEventHotKey` は行わない。Swift 6 では `@MainActor` class の nonisolated
/// deinit から non-Sendable な `EventHotKeyRef` に触れないので、deinit 自体を持たない設計。
@MainActor
final class HotKeyManager {
    /// 同プロセス内に別の Carbon ホットキー利用者がいた場合の誤発火防止用シグネチャ。
    /// `nonisolated` にするのは Swift 6 で nonisolated callback (`dispatchHotKeyEvent`) から
    /// 参照するため。`let` だが `@MainActor` class 内のプロパティはデフォルトで MainActor 隔離されるので明示する。
    nonisolated private static let signature: OSType = 0x4B555241 // 'KURA'
    nonisolated private static let hotKeyID: UInt32 = 1

    private static var handler: (@MainActor () -> Void)?
    private static var sharedHandlerRef: EventHandlerRef?

    /// ホットキーを登録。`keyCode` は Carbon の VK 定数（例: `kVK_ANSI_K`）、
    /// `modifiers` は `cmdKey | optionKey | controlKey` 等の bitwise OR。
    /// EventHandler 登録 or HotKey 登録のどちらかが失敗した場合は NSLog 警告を残して何もしない。
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) {
        // EventHandler が無い状態で RegisterEventHotKey を呼ぶと、キーは OS に予約される
        // ものの自プロセスでは処理されない状態になる（Carbon は非排他登録なので他アプリには
        // 引き続き届くが、Kura 自身が反応しないのは無意味）。ハンドラ登録に失敗した時点で諦める。
        guard Self.installSharedHandlerIfNeeded() else { return }

        let eventID = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, eventID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else {
            NSLog("[Kura] HotKey register failed status=\(status) keyCode=\(keyCode) modifiers=\(modifiers)")
            return
        }
        Self.handler = handler
        NSLog("[Kura] HotKey registered keyCode=\(keyCode) modifiers=\(modifiers)")
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
