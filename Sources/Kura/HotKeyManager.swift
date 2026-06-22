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
@MainActor
final class HotKeyManager {
    /// 登録済み HotKey ID と対応するハンドラ。MainActor 隔離下のみ読み書きする。
    /// closure 型を `@MainActor () -> Void` にすることで、callback 側でも MainActor
    /// コンテキストでないと呼び出せないことを型レベルで強制する。
    private static var registry: [UInt32: @MainActor () -> Void] = [:]
    private static var idCounter: UInt32 = 0
    /// Carbon の InstallEventHandler は 1 度だけ呼べばすべての HotKey を受けられるので共有。
    private static var sharedHandlerRef: EventHandlerRef?

    private let hotKeyID: UInt32
    private var hotKeyRef: EventHotKeyRef?

    /// ホットキーを登録。`keyCode` は Carbon の VK 定数（例: `kVK_ANSI_K`）、
    /// `modifiers` は `cmdKey | optionKey | controlKey` 等の bitwise OR。
    /// 登録に失敗した場合は NSLog 警告を残して何もしない。
    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping @MainActor () -> Void) {
        Self.idCounter &+= 1
        let id = Self.idCounter
        self.hotKeyID = id

        Self.installSharedHandlerIfNeeded()

        let signature: OSType = 0x4B555241 // 'KURA'
        let eventID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, eventID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref = ref else {
            NSLog("[Kura] HotKey register failed status=\(status) keyCode=\(keyCode) modifiers=\(modifiers)")
            return
        }
        self.hotKeyRef = ref
        Self.registry[id] = handler
        NSLog("[Kura] HotKey registered id=\(id) keyCode=\(keyCode) modifiers=\(modifiers)")
    }

    /// nonisolated deinit から MainActor 隔離 state を触るため Task で main に戻す。
    deinit {
        let ref = hotKeyRef
        let id = hotKeyID
        Task { @MainActor in
            if let ref = ref {
                UnregisterEventHotKey(ref)
            }
            HotKeyManager.registry.removeValue(forKey: id)
        }
    }

    private static func installSharedHandlerIfNeeded() {
        guard sharedHandlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
            { _, eventRef, _ in
                HotKeyManager.dispatchHotKeyEvent(eventRef)
                return noErr
            },
            1, &spec, nil, &sharedHandlerRef)
        if status != noErr {
            NSLog("[Kura] HotKey InstallEventHandler failed status=\(status)")
        }
    }

    /// Carbon callback は MainActor 外で呼ばれる可能性があるため nonisolated にして、
    /// DispatchQueue.main.async で MainActor に戻してから registry を引く。
    nonisolated static func dispatchHotKeyEvent(_ eventRef: EventRef?) {
        guard let eventRef = eventRef else { return }
        var eventID = EventHotKeyID()
        let status = GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &eventID)
        guard status == noErr else { return }
        let id = eventID.id
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                HotKeyManager.registry[id]?()
            }
        }
    }
}
