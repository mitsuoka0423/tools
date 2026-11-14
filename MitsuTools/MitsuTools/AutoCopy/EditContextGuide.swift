import AppKit

/// VS Code など、EditContext を使う入力欄のアプリ向けの案内。
///
/// VS Code 1.95 以降は文字の入力欄に EditContext という新しい Web API を既定で使う。
/// macOS では Chromium が EditContext の中身をアクセシビリティへ公開しないため、
/// 選んだ文字がどの経路からも読めない（Chromium の制限で、こちらでは直せない）。
/// 直すにはアプリ側の設定が 2 つ要る（editor.editContext: false と
/// editor.accessibilitySupport: "on"。2026-11 実測。片方では読めない）。
/// 「設定をかける」で settings.json に書き込み、ウィンドウ開き直しを案内する。
/// 同じアプリに対して、アプリを起動している間 1 回だけ知らせる。
@MainActor
enum EditContextGuide {
    private static var alreadyShown = Set<String>()

    /// 設定に書き足す内容（書き込みがうまくいかないときの案内用）
    static let settingSnippet = "{ \"editor.editContext\": false, \"editor.accessibilitySupport\": \"on\" }"

    static func showOnce(for app: NSRunningApplication) {
        let key = app.bundleIdentifier ?? app.localizedName ?? ""
        guard !key.isEmpty, !alreadyShown.contains(key) else { return }
        alreadyShown.insert(key)

        let name = app.localizedName ?? "このアプリ"
        switch ask(name: name, bundleID: app.bundleIdentifier) {
        case .configure:
            guard let fix = EditContextApps.configure(bundleID: app.bundleIdentifier, appName: app.localizedName) else {
                reportFailure(name: name, file: nil)
                return
            }
            switch fix.result {
            case .configured, .alreadyConfigured:
                reportSuccess(name: name, file: fix.file)
            case .unparseable, .failed:
                reportFailure(name: name, file: fix.file)
            }
        case .copy:
            copySnippet()
        case .later:
            break
        }
    }

    private enum Choice { case configure, copy, later }

    private static func ask(name: String, bundleID: String?) -> Choice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(name) では選んだ文字を読み取れません"
        alert.informativeText = """
        \(name) は入力欄の新しい方式（EditContext）では選んだ文字を macOS のアクセシビリティに出さず、また支援技術の設定が auto のままだと選択を外部に見せません。

        設定 editor.editContext: false と editor.accessibilitySupport: "on" をかけると自動コピーが動くようになります。「設定をかける」を押すと、アプリの設定ファイル（settings.json）に書き足します。
        """
        alert.addButton(withTitle: "設定をかける")
        alert.addButton(withTitle: "設定の内容をコピー")
        alert.addButton(withTitle: "あとで")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .configure
        case .alertSecondButtonReturn: return .copy
        default: return .later
        }
    }

    private static func reportSuccess(name: String, file: URL) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(name) の設定に書き込みました"
        alert.informativeText = """
        \(file.path)

        ウィンドウを開き直すと効きます（メニューの「ウィンドウ再読み込み」でも可）。もう一度選択し直して、コピーされるか確かめてください。
        """
        alert.addButton(withTitle: "了解")
        alert.runModal()
    }

    private static func reportFailure(name: String, file: URL?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(name) の設定に書き込めませんでした"
        alert.informativeText = """
        \(file.map { "対象: \($0.path)\n\n" } ?? "")設定の内容をコピーしておいたので、アプリの設定ファイル（settings.json）に手で貼り込むこともできます。
        """
        alert.addButton(withTitle: "設定の内容をコピー")
        alert.addButton(withTitle: "あとで")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { copySnippet() }
    }

    private static func copySnippet() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(settingSnippet, forType: .string)
    }
}
