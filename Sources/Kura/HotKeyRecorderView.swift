import AppKit
import Carbon.HIToolbox

/// System Settings 流のキー入力 UI。クリックで recording モードに入り、
/// 次のキーストロークを capture して `KuraHotKey` を生成、`onChange` で親に通知する。
///
/// 動作:
/// - 通常時: 現在の `hotKey.display` をボタン風に表示
/// - クリック (or Space / Return): recording 状態に遷移し firstResponder を取る
/// - recording 中の keyDown: modifier 1 つ以上 + 実キーが揃ったら確定、focus を手放す
/// - recording 中の Escape: キャンセル、元の hotKey 表示に戻る
/// - view 外クリック / 他フィールドへの focus 移動: recording キャンセル
///
/// 単独キー (modifier なし) や modifier のみの組み合わせは登録を拒否する
/// (システムや前面アプリのキーバインドと衝突しやすいため)。
@MainActor
final class HotKeyRecorderView: NSView {
    var hotKey: KuraHotKey {
        didSet {
            guard hotKey != oldValue else { return }
            needsDisplay = true
        }
    }

    /// recording で確定したホットキーを親に通知。recording キャンセル時は呼ばない。
    var onChange: ((KuraHotKey) -> Void)?

    private var isRecording: Bool = false {
        didSet {
            guard isRecording != oldValue else { return }
            needsDisplay = true
        }
    }

    init(hotKey: KuraHotKey) {
        self.hotKey = hotKey
        super.init(frame: .zero)
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 24)
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            isRecording = true
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    /// recording 中のキー入力を capture。
    /// - Escape: キャンセル (focus を外す → resignFirstResponder で recording 解除)
    /// - modifier + 実キー: 確定して onChange、focus を外す
    /// - modifier のみ: 無視 (実キーを待つ)
    /// - modifier なしの単独キー: 無視 (modifier 必須ルール)
    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        let keyCode = event.keyCode
        if Int(keyCode) == kVK_Escape {
            window?.makeFirstResponder(nil)
            return
        }
        let carbonMods = Self.carbonModifiers(from: event.modifierFlags)
        guard carbonMods != 0 else {
            // modifier なしの単独キー: 拒否してビープ
            NSSound.beep()
            return
        }
        let display = Self.displayString(
            keyCode: keyCode,
            modifierFlags: event.modifierFlags,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
        let newHotKey = KuraHotKey(
            keyCode: UInt32(keyCode),
            modifiers: carbonMods,
            display: display
        )
        hotKey = newHotKey
        onChange?(newHotKey)
        window?.makeFirstResponder(nil)
    }

    /// modifier の押下/離散だけの場合 keyDown ではなく flagsChanged が来るので、
    /// 「modifier 単独で確定」されないよう明示的に無視する (super を呼ばない)。
    override func flagsChanged(with event: NSEvent) {
        if !isRecording { super.flagsChanged(with: event) }
    }

    // MARK: - 描画

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                              xRadius: 5, yRadius: 5)
        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
        } else {
            NSColor.controlBackgroundColor.setFill()
        }
        bg.fill()
        if isRecording {
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        bg.lineWidth = 1
        bg.stroke()

        let label: String
        let color: NSColor
        if isRecording {
            label = "キーを押してください…"
            color = .secondaryLabelColor
        } else {
            label = hotKey.display
            color = .labelColor
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color
        ]
        let attributed = NSAttributedString(string: label, attributes: attrs)
        let textSize = attributed.size()
        let origin = NSPoint(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2
        )
        attributed.draw(at: origin)
    }

    override func drawFocusRingMask() {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5)
        path.fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: - 変換ヘルパー

    /// NSEvent.ModifierFlags を Carbon `RegisterEventHotKey` 用の bitwise OR に変換する。
    /// device-independent な `.command/.option/.control/.shift` だけを採用する
    /// (function key flag や capsLock は Carbon 側に対応する flag がない / ホットキーには不適切)。
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option)  { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift)   { result |= UInt32(shiftKey) }
        return result
    }

    /// 表示用文字列を組み立てる。macOS 標準の表記順 (⌃⌥⇧⌘) に合わせる。
    /// キー本体は VK 定数ごとの特殊キー名 → なければ NSEvent の charactersIgnoringModifiers (大文字化)。
    static func displayString(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> String {
        var result = ""
        if modifierFlags.contains(.control) { result += "⌃" }
        if modifierFlags.contains(.option)  { result += "⌥" }
        if modifierFlags.contains(.shift)   { result += "⇧" }
        if modifierFlags.contains(.command) { result += "⌘" }
        if let special = specialKeyName(forKeyCode: Int(keyCode)) {
            result += special
        } else if let chars = charactersIgnoringModifiers, !chars.isEmpty {
            result += chars.uppercased()
        } else {
            result += "?"
        }
        return result
    }

    /// 特殊キー (Function キー、矢印、Space 等) の表示名。テキスト文字を持たないキー用。
    /// 該当しないキーは nil を返し、呼び出し側で charactersIgnoringModifiers にフォールバックさせる。
    private static func specialKeyName(forKeyCode keyCode: Int) -> String? {
        switch keyCode {
        case kVK_Return:         return "↩"
        case kVK_Tab:            return "⇥"
        case kVK_Space:          return "Space"
        case kVK_Delete:         return "⌫"
        case kVK_ForwardDelete:  return "⌦"
        case kVK_LeftArrow:      return "←"
        case kVK_RightArrow:     return "→"
        case kVK_UpArrow:        return "↑"
        case kVK_DownArrow:      return "↓"
        case kVK_Home:           return "↖"
        case kVK_End:            return "↘"
        case kVK_PageUp:         return "⇞"
        case kVK_PageDown:       return "⇟"
        case kVK_F1:             return "F1"
        case kVK_F2:             return "F2"
        case kVK_F3:             return "F3"
        case kVK_F4:             return "F4"
        case kVK_F5:             return "F5"
        case kVK_F6:             return "F6"
        case kVK_F7:             return "F7"
        case kVK_F8:             return "F8"
        case kVK_F9:             return "F9"
        case kVK_F10:            return "F10"
        case kVK_F11:            return "F11"
        case kVK_F12:            return "F12"
        default:                 return nil
        }
    }
}
