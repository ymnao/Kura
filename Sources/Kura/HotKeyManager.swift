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
@MainActor
final class HotKeyManager {
    private static var handler: (@MainActor () -> Void)?
    private static var sharedHandlerRef: EventHandlerRef?

    private var hotKeyRef: EventHotKeyRef?

    /// ホットキーを登録。`keyCode` は Carbon の VK 定数（例: `kVK_ANSI_K`）、
    /// `modifiers` は `cmdKey | optionKey | controlKey` 等の bitwise OR。
    /// EventHandler 登録 or HotKey 登録のどちらかが失敗した場合は NSLog 警告を残して何もしない。
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) {
        // EventHandler が無い状態で RegisterEventHotKey を呼ぶと、キーは OS に予約された
        // まま誰にも処理されない「死んだホットキー」になる（他アプリにも届かなくなる）。
        // ハンドラ登録に失敗した時点で諦める。
        guard Self.installSharedHandlerIfNeeded() else { return }

        let signature: OSType = 0x4B555241 // 'KURA'
        let eventID = EventHotKeyID(signature: signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, eventID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else {
            NSLog("[Kura] HotKey register failed status=\(status) keyCode=\(keyCode) modifiers=\(modifiers)")
            return
        }
        self.hotKeyRef = ref
        Self.handler = handler
        NSLog("[Kura] HotKey registered keyCode=\(keyCode) modifiers=\(modifiers)")
    }

    deinit {
        let ref = hotKeyRef
        Task { @MainActor in
            if let ref = ref {
                UnregisterEventHotKey(ref)
            }
            HotKeyManager.handler = nil
        }
    }

    /// 共有ハンドラの登録を一度だけ試す。既に登録済みなら true、今回成功しても true、
    /// 失敗時のみ false を返す。呼び出し側はこの戻り値で「RegisterEventHotKey に進んで良いか」を判断する。
    private static func installSharedHandlerIfNeeded() -> Bool {
        if sharedHandlerRef != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
            { _, _, _ in
                HotKeyManager.dispatchHotKeyEvent()
                return noErr
            },
            1, &spec, nil, &sharedHandlerRef)
        if status != noErr {
            NSLog("[Kura] HotKey InstallEventHandler failed status=\(status)")
            return false
        }
        return true
    }

    /// Carbon callback は MainActor 外で呼ばれる可能性があるため nonisolated にして、
    /// DispatchQueue.main.async で MainActor に戻してからハンドラを呼ぶ。
    nonisolated static func dispatchHotKeyEvent() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                HotKeyManager.handler?()
            }
        }
    }
}
