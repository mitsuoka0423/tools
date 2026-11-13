import AppKit
import ApplicationServices

/// いまキー入力を受けている要素の、選択範囲の文字と位置を Accessibility で読む。
/// クリップボードは使わない（⌘C は送らない）。
@MainActor
enum SelectionReader {
    struct Selection {
        let text: String
        /// 選択範囲の位置（Accessibility の座標＝左上原点）。取れなければ nil。
        let rect: CGRect?
        let isSecure: Bool
    }

    /// 他のアプリが応答しないときに、ここで長く止まらないための上限（秒）
    private static let timeout: Float = 0.25
    /// Electron のアプリで、Accessibility を有効にするよう一度だけ頼んだプロセス
    private static var requestedManualAccessibility = Set<pid_t>()

    static func read(pid: pid_t) -> Selection? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        guard let focused = element(system, kAXFocusedUIElementAttribute) else {
            requestManualAccessibility(pid: pid)
            return nil
        }
        AXUIElementSetMessagingTimeout(focused, timeout)

        let role = string(focused, kAXRoleAttribute), subrole = string(focused, kAXSubroleAttribute)
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
        if isSecure { return Selection(text: "", rect: nil, isSecure: true) }

        // 1. ふつうの文字の欄（テキストエディット、メモ、多くの入力欄）
        if let text = string(focused, kAXSelectedTextAttribute), !text.isEmpty {
            return Selection(text: text, rect: boundsOfSelectedRange(focused), isSecure: false)
        }
        // 2. Web の文章（Safari・Chrome など）：選択は「テキストマーカー」で表されている。親をたどって探す
        var current: AXUIElement? = focused
        for _ in 0..<12 {
            guard let el = current else { break }
            if let marker = value(el, "AXSelectedTextMarkerRange"),
               let text = parameterized(el, "AXStringForTextMarkerRange", marker) as? String, !text.isEmpty {
                var rect: CGRect?
                if let v = parameterized(el, "AXBoundsForTextMarkerRange", marker), CFGetTypeID(v) == AXValueGetTypeID() {
                    var r = CGRect.zero
                    if AXValueGetValue(v as! AXValue, .cgRect, &r) { rect = r }
                }
                return Selection(text: text, rect: rect, isSecure: false)
            }
            current = element(el, kAXParentAttribute)
        }
        requestManualAccessibility(pid: pid)
        return nil
    }

    // MARK: 内部

    private static func boundsOfSelectedRange(_ el: AXUIElement) -> CGRect? {
        guard let range = value(el, kAXSelectedTextRangeAttribute),
              let v = parameterized(el, kAXBoundsForRangeParameterizedAttribute as String, range),
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.width > 0 || r.height > 0 else { return nil }
        return r
    }

    /// Electron のアプリは、頼まないと Accessibility の情報を出さない。次の読み取りから読めるよう、一度だけ頼む。
    private static func requestManualAccessibility(pid: pid_t) {
        guard !requestedManualAccessibility.contains(pid) else { return }
        requestedManualAccessibility.insert(pid)
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func value(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attribute as CFString, &v) == .success ? v : nil
    }

    private static func element(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(el, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        value(el, attribute) as? String
    }

    private static func parameterized(_ el: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, attribute as CFString, parameter, &v) == .success ? v : nil
    }
}
