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
    /// Chromium が EditContext を使う入力欄に付ける DOM クラス。
    /// これが見えたら、テキストはアクセシビリティツリーのどこにも存在しない。
    private static let editContextDOMClass = "native-edit-context"
    enum Result {
        case selection(Selection)
        case none
        /// Chrome・Electron が Accessibility の情報をまだ作っていない（作るのに 1〜3 秒かかる）。少し待って読み直す
        case notReady
        /// VS Code など EditContext を使う入力欄。選んだ文字がツリーのどこにも存在せず、読み直しても無駄。
        /// アプリ側の設定で直すしかない（EditContextGuide 参照。2026-11 実測）
        case blockedByEditContext
    }

    /// Chrome・Electron は、前面に来たときに Accessibility の情報を出さない。有効にしてから
    /// 情報ができるまで 1〜10 秒かかるうえ、しばらく問い合わせがないとツリーをたたんでしまう
    /// （2026-11、VS Code 1.146 で実測）。選ぶ前に、こまめに触っておく。
    static func prepare(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let url = app.bundleURL, isChromium(url) else { return }
        _ = requestAccessibility(pid: app.processIdentifier)
        // 起動したばかりだと、頼んでも無視されることがある。少し待って、効いていなければもう一度頼む
        let pid = app.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated { _ = requestAccessibility(pid: pid) }
        }
    }

    /// Chromium（Chrome・Edge・Brave など）と Electron のアプリは、
    /// 「〜 Helper (Renderer).app」を Frameworks の中か、その中のフレームワークに持つ。
    private static var chromiumCache: [URL: Bool] = [:]
    private static func isChromium(_ bundle: URL) -> Bool {
        if let cached = chromiumCache[bundle] { return cached }
        let fm = FileManager.default
        let frameworks = bundle.appending(path: "Contents/Frameworks")
        let entries = (try? fm.contentsOfDirectory(atPath: frameworks.path)) ?? []
        let isRenderer = { (name: String) in name.contains("Helper (Renderer)") }
        var result = entries.contains(where: isRenderer)
        if !result {
            result = entries.filter { $0.hasSuffix(".framework") }.contains { name in
                let helpers = frameworks.appending(path: "\(name)/Versions/Current/Helpers")
                return ((try? fm.contentsOfDirectory(atPath: helpers.path)) ?? []).contains(where: isRenderer)
            }
        }
        chromiumCache[bundle] = result
        return result
    }

    static func read(pid: pid_t) -> Result {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, timeout)
        // Chrome・Electron は、頼むまで Accessibility の情報を出さない（フォーカスのある要素すら無い）
        // システム全体からの問い合わせは、Chrome などで失敗することがあるので、アプリにも直接聞く
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, timeout)
        guard let focused = element(system, kAXFocusedUIElementAttribute) ?? element(appElement, kAXFocusedUIElementAttribute) else {
            guard NSRunningApplication(processIdentifier: pid)?.bundleURL.map(isChromium) == true else { return .none }
            _ = requestAccessibility(pid: pid)
            return .notReady
        }
        AXUIElementSetMessagingTimeout(focused, timeout)

        let role = string(focused, kAXRoleAttribute), subrole = string(focused, kAXSubroleAttribute)
        let isSecure = subrole == (kAXSecureTextFieldSubrole as String) || role == "AXSecureTextField"
        if isSecure { return .selection(Selection(text: "", rect: nil, isSecure: true)) }

        // 1. ふつうの文字の欄（テキストエディット、メモ、多くの入力欄）
        if let text = string(focused, kAXSelectedTextAttribute), !text.isEmpty {
            return .selection(Selection(text: text, rect: boundsOfSelectedRange(focused), isSecure: false))
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
                return .selection(Selection(text: text, rect: rect, isSecure: false))
            }
            current = element(el, kAXParentAttribute)
        }
        // 3. どれにも当たらなければ、EditContext の入力欄かを確かめる（VS Code など）
        if strings(focused, "AXDOMClassList")?.contains(editContextDOMClass) == true {
            return .blockedByEditContext
        }
        // 4. Chromium のアプリで、DOM 情報も選択もない = ツリーが作りかけ・たたんだ状態。
        //    頼み直して、少し待てば読める（読み直しに価値あり）
        if NSRunningApplication(processIdentifier: pid)?.bundleURL.map(isChromium) == true {
            _ = requestAccessibility(pid: pid)
            return .notReady
        }
        return .none
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

    /// 頼まないと Accessibility の情報を出さないアプリに頼む。もう有効なら何もしない。頼んだら true。
    /// - Electron：AXManualAccessibility
    /// - Chrome などの Chromium：AXEnhancedUserInterface（VoiceOver などと同じ合図）
    private static func requestAccessibility(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        if let v = value(app, "AXEnhancedUserInterface") as? Bool, v { return false }
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return true
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

    private static func strings(_ el: AXUIElement, _ attribute: String) -> [String]? {
        value(el, attribute) as? [String]
    }

    private static func parameterized(_ el: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, attribute as CFString, parameter, &v) == .success ? v : nil
    }
}
