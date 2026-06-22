import AppKit
import ApplicationServices

/// 蔵対象アプリ（NSStatusItem を持ち、蔵より左にアイコンを置いているアプリ）。
/// scan 時の位置で対象を選別し、対象 NSStatusItem の「AXExtrasMenuBar 内インデックス」を保存する。
/// 位置情報ではなく index で識別することで:
/// - 折りたたみ中（対象アイコンが画面外で x<=0 になる）でも、index 同一性で正しく走査できる
/// - 蔵位置を移動して kuraX が変わっても、scan 結果がそのまま意味を持つ
/// アプリが新規 NSStatusItem を追加/削除すると index がずれるが、その場合は次回の scan で更新される。
/// 蔵対象アプリ。
/// 既知の制約:
/// - **同 count での NSStatusItem 入れ替え/並び替えは検出できない**。AXTitle / AXDescription は
///   NSStatusItem の表示として正常に変化する（時刻、進捗、未読数等）ため fingerprint が
///   false positive を起こし、`AXIdentifier` のみでは多くのアプリで空のため false negative を起こす。
///   AX レイヤーには NSStatusItem の安定した identity を保証する手段がない。許容する設計上の妥協。
/// - **同 bundleId の複数プロセスは非対応**。byBundle / nodeCache が bundleId キーのため
///   2 プロセス目以降は静かに上書きされる。実用上ほぼ無いケースとして許容する。
struct StatusBarApp: Hashable, Sendable {
    let bundleIdentifier: String
    let name: String
    let pid: pid_t
    let leftmostX: CGFloat
    /// 蔵対象となった NSStatusItem の AXExtrasMenuBar.children 内インデックス。
    let menuBarIndices: Set<Int>
    /// scan 時の AXExtrasMenuBar.children 全数（追加/削除の検出用）。
    let menuBarItemCount: Int

    /// 「複数 NSStatusItem を持ち、一部だけ対象」のアプリかどうか。
    /// 同 count での入れ替えは AX レイヤーでは安定 identity が取れないので検出できない。
    /// 並び替えで別項目を発火するリスクがあるため、このフラグが true のアプリでは
    /// メニュー項目クリック (AXPress) を fail-safe で無効化する。
    var isPartialTarget: Bool {
        menuBarItemCount > 1 && menuBarIndices.count < menuBarItemCount
    }

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// アプリ再起動で pid が変われば AX 要素も別物になるため、pid も同値判定に含める。
    /// （bundleId のみで一致判定すると、再起動後も古い pid の AppNode が再利用されて AX 走査が失敗する）
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.bundleIdentifier == rhs.bundleIdentifier
            && lhs.pid == rhs.pid
            && lhs.menuBarIndices == rhs.menuBarIndices
            && lhs.menuBarItemCount == rhs.menuBarItemCount
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleIdentifier)
        hasher.combine(pid)
        hasher.combine(menuBarIndices)
        hasher.combine(menuBarItemCount)
    }
}

/// scan の結果を区別するための型。
/// - `.unauthorized`: AX 権限なし
/// - `.cancelled`: 途中で `Task.isCancelled` を検知して中断
/// - `.items(apps, failedBundleIds)`: 部分成功も含む。失敗した bundleId は呼び出し側で
///    旧キャッシュから保持し、成功分だけ置換することで「無関係なアプリの一時失敗で
///    全体停止しない」設計にする。
enum ScanLayoutResult: Sendable {
    case unauthorized
    case cancelled
    case items(apps: [StatusBarApp], failedBundleIds: Set<String>)
}

enum MenuBarLayoutScanner {
    /// 蔵より左に NSStatusItem を持つアプリを左端 x 座標順に列挙する。
    /// `kuraX` は蔵自身のメニューバーアイコンの x 座標（AppKit でも AX でも x は同じ）。
    /// `kuraScreenFrameInAX` は蔵が乗っているスクリーンのフレームを **AX 座標系** (主画面左上原点、Y 下向き正)
    /// に変換したもの。kAXPositionAttribute と同じ座標系で `contains(point)` 判定するため、
    /// 呼び出し側で AppKit (左下原点) → AX (左上原点) 変換を済ませて渡す前提。
    /// 長時間の AX 走査になりうるため、`Task.isCancelled` を loop 内で確認して早期 return する。
    static func scanLeftOfKura(kuraX: CGFloat, kuraScreenFrameInAX: CGRect) -> ScanLayoutResult {
        guard AccessibilityPermission.isTrusted else {
            return .unauthorized
        }
        let myPid = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
            .filter { $0.processIdentifier != myPid }

        var byBundle: [String: StatusBarApp] = [:]
        var failedBundleIds: Set<String> = []
        for app in runningApps {
            if Task.isCancelled { return .cancelled }
            guard let bundleId = app.bundleIdentifier else { continue }
            switch statusItemPositions(pid: app.processIdentifier) {
            case .noStatusItems:
                continue
            case .transientFailure:
                // このアプリは一時失敗。当該 bundle のみ前回キャッシュを保持する指示として
                // failedBundleIds に積む。他アプリの scan は継続。
                failedBundleIds.insert(bundleId)
                continue
            case .positions(let positions):
                // 「Kura と同じスクリーン frame (AX 座標) 内」+「蔵より左」+「(0,0) でない（hidden item 除外）」
                // で対象 index を集める。座標系不一致を避けるため kuraScreenFrameInAX で contains 判定。
                // `.zero` は Control Center 等の hidden item に頻出するので除外。
                var targetIndices: Set<Int> = []
                var minLeftX = CGFloat.greatestFiniteMagnitude
                for (i, maybePoint) in positions.enumerated() {
                    guard let p = maybePoint,
                          p != .zero,
                          kuraScreenFrameInAX.contains(p),
                          p.x < kuraX else { continue }
                    targetIndices.insert(i)
                    if p.x < minLeftX { minLeftX = p.x }
                }
                guard !targetIndices.isEmpty else { continue }
                let name = app.localizedName ?? bundleId
                byBundle[bundleId] = StatusBarApp(
                    bundleIdentifier: bundleId,
                    name: name,
                    pid: app.processIdentifier,
                    leftmostX: minLeftX,
                    menuBarIndices: targetIndices,
                    menuBarItemCount: positions.count
                )
            }
        }
        let apps = byBundle.values.sorted { $0.leftmostX < $1.leftmostX }
        return .items(apps: apps, failedBundleIds: failedBundleIds)
    }

    /// 個別アプリの NSStatusItem 取得結果。
    private enum ItemFetch {
        case noStatusItems                  // 属性なし or 子なし: 正常に「持っていない」
        case transientFailure               // cannotComplete 等の一時失敗
        case positions([CGPoint?])          // 正常結果。children と同じ index で対応、位置取得不可は nil
    }

    private static func statusItemPositions(pid: pid_t) -> ItemFetch {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, AXHelpers.messagingTimeout)

        // AXExtrasMenuBar の取得失敗を「属性なし」「応答不能（ヘルパープロセス等）」「真の一時失敗」で区別する。
        // `.cannotComplete` は WebKit/Discord/Virtualization 等のメニューバーを持たないヘルパープロセスでも
        // 頻発する（accessory activationPolicy だが NSStatusItem を持たない）。真の一時失敗と AX で区別不能なため、
        // folded をブロックしない方を優先して noStatusItems 扱いにする。
        var extrasRef: CFTypeRef?
        let extrasErr = AXUIElementCopyAttributeValue(axApp, "AXExtrasMenuBar" as CFString, &extrasRef)
        switch extrasErr {
        case .success:
            break
        case .attributeUnsupported, .noValue, .cannotComplete, .notImplemented, .invalidUIElement:
            return .noStatusItems
        default:
            return .transientFailure
        }
        guard let extrasValue = extrasRef,
              CFGetTypeID(extrasValue) == AXUIElementGetTypeID() else {
            return .noStatusItems
        }
        let extras = extrasValue as! AXUIElement
        AXUIElementSetMessagingTimeout(extras, AXHelpers.messagingTimeout)

        var childrenRef: CFTypeRef?
        let childErr = AXUIElementCopyAttributeValue(extras, kAXChildrenAttribute as CFString, &childrenRef)
        switch childErr {
        case .success:
            break
        case .attributeUnsupported, .noValue, .cannotComplete, .notImplemented, .invalidUIElement:
            return .noStatusItems
        default:
            return .transientFailure
        }
        guard let array = childrenRef as? [AnyObject] else {
            return .noStatusItems
        }

        // children のインデックスと一致した順序で位置を返す。
        // 位置取得失敗時は nil を入れて配列長を維持する。
        var positions: [CGPoint?] = []
        positions.reserveCapacity(array.count)
        let typeID = AXUIElementGetTypeID()
        for value in array {
            guard CFGetTypeID(value) == typeID else {
                positions.append(nil)
                continue
            }
            let element = value as! AXUIElement
            AXUIElementSetMessagingTimeout(element, AXHelpers.messagingTimeout)

            var posRef: CFTypeRef?
            let posErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
            switch posErr {
            case .success:
                break
            case .attributeUnsupported, .noValue, .notImplemented, .invalidUIElement:
                // 「正常に取れない」系: その child だけ nil で skip、アプリ全体としては成功扱い
                positions.append(nil)
                continue
            case .cannotComplete:
                // AX が応答不能な真の一時失敗のみ scan 全体を transient failure 扱いにする
                return .transientFailure
            default:
                // 想定外のエラーコード: 一律 transient 扱いにすると過剰反応するので個別 nil
                positions.append(nil)
                continue
            }
            guard let posValue = posRef,
                  CFGetTypeID(posValue) == AXValueGetTypeID() else {
                positions.append(nil)
                continue
            }
            let axValue = posValue as! AXValue
            guard AXValueGetType(axValue) == .cgPoint else {
                positions.append(nil)
                continue
            }
            var point = CGPoint.zero
            guard AXValueGetValue(axValue, .cgPoint, &point) else {
                positions.append(nil)
                continue
            }
            positions.append(point)
        }
        return .positions(positions)
    }
}
