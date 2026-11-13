import AppKit

/// VS Code など、EditContext を使う入力欄のアプリ向けの案内。
///
/// VS Code 1.95 以降は文字の入力欄に EditContext という新しい Web API を既定で使う。
/// macOS では Chromium が EditContext の中身をアクセシビリティへ公開しないため、
/// 選んだ文字がどの経路からも読めない（Chromium の制限で、こちらでは直せない）。
/// アプリの設定で editor.editContext を false にすると従来の入力欄に戻り、自動コピーが動く。
/// 同じアプリに対して、アプリを起動している間 1 回だけ知らせる。
@MainActor
enum EditContextGuide {
    private static var alreadyShown = Set<String>()

    /// 設定に書き足す内容（コピーして settings.json に貼れる）。
    static let settingSnippet = "{ \"editor.editContext\": false }"

    static func showOnce(for app: NSRunningApplication) {
        let key = app.bundleIdentifier ?? app.localizedName ?? ""
        guard !key.isEmpty, !alreadyShown.contains(key) else { return }
        alreadyShown.insert(key)

        let name = app.localizedName ?? "このアプリ"
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "\(name) では選んだ文字を読み取れません"
        alert.informativeText = """
        \(name) は文字の入力欄に EditContext という新しい方式を使っていて、選んだ文字が macOS のアクセシビリティに出てきません（作り手の側の制限で、自動コピーでは読みようがありません）。

        アプリの設定で editor.editContext を false にすると自動コピーが動くようになります。「設定の内容をコピー」を押すと、settings.json に貼り込む内容がコピーできます。
        """
        alert.addButton(withTitle: "設定の内容をコピー")
        alert.addButton(withTitle: "あとで")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(settingSnippet, forType: .string)
        }
    }
}
