import AppKit

/// ブラウザのデータフォルダを、ユーザーにファイル選択の画面で選んでもらい、そのフォルダだけ読めるようにする。
///
/// macOS はほかのアプリのデータフォルダを保護しているが、ユーザーが自分で選んだ場所は読ませてくれる。
/// フルディスクアクセスより狭い範囲で済む。選んだ場所はブックマーク（URL の参照）として覚えておき、
/// 起動し直しても使えるようにする。覚えておく先はこの Mac の UserDefaults だけ（設定ファイルには書かない）。
@MainActor
enum BookmarkFolderAccess {
    private static func key(_ source: BrowserSource) -> String { "bookmarks.folderAccess.\(source.id)" }

    static func hasAccess(_ source: BrowserSource) -> Bool {
        UserDefaults.standard.data(forKey: key(source)) != nil
    }

    /// 選んだフォルダへのアクセスを有効にして body を実行する。覚えている場所がなければ、そのまま実行する。
    static func withAccess<T>(_ source: BrowserSource, _ body: () throws -> T) rethrows -> T {
        guard let url = resolve(source) else { return try body() }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    /// ファイル選択の画面を出す。選ばれたら true。
    static func request(_ source: BrowserSource) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = source.dataURL
        panel.prompt = "許可する"
        panel.message = "\(source.name) のデータフォルダ「\(displayPath(source.dataURL))」を選んで「許可する」を押してください。"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        // 別のフォルダが選ばれたら、正しい場所を伝えてやり直してもらう
        guard url.standardizedFileURL.path == source.dataURL.standardizedFileURL.path else {
            let alert = NSAlert()
            alert.messageText = "選んだフォルダが違います"
            alert.informativeText = "\(source.name) のブックマークは「\(displayPath(source.dataURL))」にあります。このフォルダを選んでください。"
            alert.runModal()
            return false
        }
        let data = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let data else { return false }
        UserDefaults.standard.set(data, forKey: key(source))
        return true
    }

    static func revoke(_ source: BrowserSource) {
        UserDefaults.standard.removeObject(forKey: key(source))
    }

    private static func resolve(_ source: BrowserSource) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key(source)) else { return nil }
        var stale = false
        let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale))
            ?? (try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale))
        if let url, stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: key(source))
        }
        return url
    }

    private static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
