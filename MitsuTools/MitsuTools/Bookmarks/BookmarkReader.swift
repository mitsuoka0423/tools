import AppKit
import SQLite3

/// 1 件のブックマーク。メモリ上だけに持つ。
struct Bookmark: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
    /// フォルダの階層（例: 「ブックマーク バー › 開発」）
    let folder: String
    let browser: String
    /// 検索用に小文字にした文字列
    let searchText: String
    /// ブラウザが保存しているファビコン（PNG など）。ネットワークからは取らない。
    var favicon: Data?

    init(title: String, url: URL, folder: String, browser: String) {
        let shownTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = shownTitle.isEmpty ? (url.host() ?? url.absoluteString) : shownTitle
        self.url = url
        self.folder = folder
        self.browser = browser
        self.searchText = [self.title, url.absoluteString, folder].joined(separator: " ").lowercased()
    }
}

/// ブックマークを読み込めるブラウザ。
struct BrowserSource: Identifiable, Hashable {
    enum Format { case safari, chromium, firefox }

    /// 設定ファイルにも使う、変わらない ID
    let id: String
    let name: String
    let bundleID: String
    let format: Format
    /// ブックマークのデータが入っているフォルダ（ホームからの相対パス）
    let dataPath: String

    var dataURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: dataPath, directoryHint: .isDirectory)
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
            || FileManager.default.fileExists(atPath: dataURL.path)
    }

    static let all: [BrowserSource] = [
        BrowserSource(id: "safari", name: "Safari", bundleID: "com.apple.Safari", format: .safari,
                      dataPath: "Library/Safari"),
        BrowserSource(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome", format: .chromium,
                      dataPath: "Library/Application Support/Google/Chrome"),
        BrowserSource(id: "brave", name: "Brave", bundleID: "com.brave.Browser", format: .chromium,
                      dataPath: "Library/Application Support/BraveSoftware/Brave-Browser"),
        BrowserSource(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", format: .chromium,
                      dataPath: "Library/Application Support/Microsoft Edge"),
        BrowserSource(id: "vivaldi", name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", format: .chromium,
                      dataPath: "Library/Application Support/Vivaldi"),
        BrowserSource(id: "chromium", name: "Chromium", bundleID: "org.chromium.Chromium", format: .chromium,
                      dataPath: "Library/Application Support/Chromium"),
        BrowserSource(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", format: .firefox,
                      dataPath: "Library/Application Support/Firefox/Profiles"),
    ]
}

enum BookmarkReadError: LocalizedError {
    /// macOS がほかのアプリのデータを読むのを止めている
    case permissionDenied
    case notFound
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "読み込みが許可されていません"
        case .notFound: "ブックマークが見つかりません"
        case let .unreadable(reason): "読み込めませんでした（\(reason)）"
        }
    }
}

/// ブラウザのブックマークファイルを読む。ファイルは読むだけで、書き換えない。
enum BookmarkReader {
    static func read(_ source: BrowserSource) throws -> [Bookmark] {
        switch source.format {
        case .safari: try readSafari(source)
        case .chromium: try readChromium(source)
        case .firefox: try readFirefox(source)
        }
    }

    /// 最後に変わった日時。変わっていなければ読み直さないために使う。
    static func modificationDate(_ source: BrowserSource) -> Date? {
        let files: [URL]
        switch source.format {
        case .safari: files = [source.dataURL.appending(path: "Bookmarks.plist")]
        case .chromium: files = chromiumProfiles(source).map { $0.appending(path: "Bookmarks") }
        case .firefox: files = firefoxProfiles(source).flatMap { [$0.appending(path: "places.sqlite"), $0.appending(path: "places.sqlite-wal")] }
        }
        return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
    }

    // MARK: Safari（Bookmarks.plist）

    private static func readSafari(_ source: BrowserSource) throws -> [Bookmark] {
        // macOS は保護しているファイルを「存在しない」ように見せることがあるので、
        // 先にフォルダが読めるかを確かめ、読めなければ「許可されていない」と伝える
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: source.dataURL.path)
        } catch {
            throw mapError(error)
        }
        let data = try readData(source.dataURL.appending(path: "Bookmarks.plist"))
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw BookmarkReadError.unreadable("形式が違います")
        }
        var result: [Bookmark] = []
        func walk(_ node: [String: Any], path: [String]) {
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeList":
                let title = node["Title"] as? String ?? ""
                if title == "com.apple.ReadingList" { return } // リーディングリストは対象外
                let name = ["BookmarksBar": "お気に入りバー", "BookmarksMenu": "ブックマークメニュー"][title] ?? title
                let next = name.isEmpty ? path : path + [name]
                for child in node["Children"] as? [[String: Any]] ?? [] { walk(child, path: next) }
            case "WebBookmarkTypeLeaf":
                guard let string = node["URLString"] as? String, let url = webURL(string) else { return }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
                result.append(Bookmark(title: title, url: url, folder: path.joined(separator: " › "), browser: source.name))
            default:
                for child in node["Children"] as? [[String: Any]] ?? [] { walk(child, path: path) }
            }
        }
        walk(root, path: [])
        return result
    }

    // MARK: Chrome 系（プロファイルごとの Bookmarks。JSON）

    static func chromiumProfiles(_ source: BrowserSource) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.dataURL.path)) ?? []
        return names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
            .map { source.dataURL.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "Bookmarks").path) }
    }

    private static func readChromium(_ source: BrowserSource) throws -> [Bookmark] {
        // フォルダの一覧も保護されているので、まず読めるかを確かめる
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: source.dataURL.path)
        } catch {
            throw mapError(error)
        }
        let profiles = chromiumProfiles(source)
        guard !profiles.isEmpty else { throw BookmarkReadError.notFound }
        let profileNames = chromiumProfileNames(source)
        var result: [Bookmark] = []
        for profile in profiles {
            var items: [Bookmark] = []
            let data = try readData(profile.appending(path: "Bookmarks"))
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roots = json["roots"] as? [String: Any] else { continue }
            // プロファイルが 2 つ以上あるときだけ、フォルダの先頭にプロファイル名を付ける
            let prefix = profiles.count > 1 ? [profileNames[profile.lastPathComponent] ?? profile.lastPathComponent] : []
            func walk(_ node: [String: Any], path: [String]) {
                let name = node["name"] as? String ?? ""
                switch node["type"] as? String {
                case "url":
                    guard let string = node["url"] as? String, let url = webURL(string) else { return }
                    items.append(Bookmark(title: name, url: url, folder: path.joined(separator: " › "), browser: source.name))
                case "folder":
                    for child in node["children"] as? [[String: Any]] ?? [] { walk(child, path: path + [name]) }
                default:
                    break
                }
            }
            for key in ["bookmark_bar", "other", "synced"] {
                if let root = roots[key] as? [String: Any] { walk(root, path: prefix) }
            }
            attachFavicons(&items, database: profile.appending(path: "Favicons"), sql: """
                SELECT m.page_url, b.image_data, b.width
                FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
                WHERE b.image_data IS NOT NULL
                """)
            result += items
        }
        return result
    }

    /// 「Default」→「個人」のような、ブラウザに表示されているプロファイル名
    private static func chromiumProfileNames(_ source: BrowserSource) -> [String: String] {
        guard let data = try? Data(contentsOf: source.dataURL.appending(path: "Local State")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [:] }
        var names: [String: String] = [:]
        for (dir, info) in cache {
            if let name = (info as? [String: Any])?["name"] as? String { names[dir] = name }
        }
        return names
    }

    // MARK: Firefox（プロファイルごとの places.sqlite）

    static func firefoxProfiles(_ source: BrowserSource) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: source.dataURL.path)) ?? []
        return names.sorted().map { source.dataURL.appending(path: $0, directoryHint: .isDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "places.sqlite").path) }
    }

    private static func readFirefox(_ source: BrowserSource) throws -> [Bookmark] {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: source.dataURL.path)
        } catch {
            throw mapError(error)
        }
        let profiles = firefoxProfiles(source)
        guard !profiles.isEmpty else { throw BookmarkReadError.notFound }
        var result: [Bookmark] = []
        for profile in profiles {
            // Firefox が開いている間はデータベースがロックされるので、一時フォルダへ写してから読む
            let temp = FileManager.default.temporaryDirectory.appending(path: "mitsutools-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            for suffix in ["", "-wal"] {
                let from = profile.appending(path: "places.sqlite" + suffix)
                guard FileManager.default.fileExists(atPath: from.path) else { continue }
                do {
                    try FileManager.default.copyItem(at: from, to: temp.appending(path: "places.sqlite" + suffix))
                } catch {
                    throw mapError(error)
                }
            }
            let prefix = profiles.count > 1 ? profile.lastPathComponent.split(separator: ".").last.map(String.init) ?? "" : ""
            var items = try querySQLite(temp.appending(path: "places.sqlite").path, browser: source.name, prefix: prefix)
            attachFavicons(&items, database: profile.appending(path: "favicons.sqlite"), sql: """
                SELECT p.page_url, i.data, i.width
                FROM moz_pages_w_icons p
                JOIN moz_icons_to_pages ip ON ip.page_id = p.id
                JOIN moz_icons i ON i.id = ip.icon_id
                WHERE i.data IS NOT NULL
                UNION ALL
                SELECT icon_url, data, width FROM moz_icons WHERE root = 1 AND data IS NOT NULL
                """)
            result += items
        }
        return result
    }

    private static func querySQLite(_ path: String, browser: String, prefix: String) throws -> [Bookmark] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw BookmarkReadError.unreadable("データベースを開けません")
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT b.title, p.url, COALESCE(f.title, '')
        FROM moz_bookmarks b
        JOIN moz_places p ON p.id = b.fk
        LEFT JOIN moz_bookmarks f ON f.id = b.parent
        WHERE b.type = 1
        ORDER BY b.parent, b.position
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BookmarkReadError.unreadable("データベースの形式が違います")
        }
        defer { sqlite3_finalize(statement) }
        var result: [Bookmark] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String {
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            }
            guard let url = webURL(text(1)) else { continue }
            let folder = [prefix, text(2)].filter { !$0.isEmpty }.joined(separator: " › ")
            result.append(Bookmark(title: text(0), url: url, folder: folder, browser: browser))
        }
        return result
    }

    // MARK: ファビコン（ブラウザが保存しているものだけを使い、ネットワークからは取らない）

    /// ファビコンのデータベースを一時フォルダに写して読み、ブックマークに付ける。
    /// ページの URL が一致するものを優先し、なければ同じホストのものを使う。読めなければ何もしない。
    private static func attachFavicons(_ items: inout [Bookmark], database: URL, sql: String) {
        guard !items.isEmpty, FileManager.default.fileExists(atPath: database.path) else { return }
        let urls = Set(items.map(\.url.absoluteString))
        let hosts = Set(items.compactMap { $0.url.host() })
        var byURL: [String: (data: Data, score: Int)] = [:]
        var byHost: [String: (data: Data, score: Int)] = [:]
        func keep(_ map: inout [String: (data: Data, score: Int)], _ key: String, _ data: Data, _ score: Int) {
            if let current = map[key], current.score <= score { return }
            map[key] = (data, score)
        }
        withCopiedSQLite(database) { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let pagePointer = sqlite3_column_text(statement, 0) else { continue }
                let page = String(cString: pagePointer)
                let host = URL(string: page)?.host()
                let wantsURL = urls.contains(page)
                let wantsHost = host.map { hosts.contains($0) } ?? false
                guard wantsURL || wantsHost, let blob = sqlite3_column_blob(statement, 1) else { continue }
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 1)))
                // 一覧で表示する大きさ（32px）に近いものを選ぶ
                let score = abs(Int(sqlite3_column_int(statement, 2)) - 32)
                if wantsURL { keep(&byURL, page, data, score) }
                if wantsHost, let host { keep(&byHost, host, data, score) }
            }
        }
        for index in items.indices {
            let item = items[index]
            items[index].favicon = byURL[item.url.absoluteString]?.data ?? item.url.host().flatMap { byHost[$0]?.data }
        }
    }

    /// ブラウザが開いている間はデータベースがロックされるので、一時フォルダへ写してから開く。
    private static func withCopiedSQLite(_ database: URL, _ body: (OpaquePointer) -> Void) {
        let temp = FileManager.default.temporaryDirectory.appending(path: "mitsutools-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let name = database.lastPathComponent
        for suffix in ["", "-wal", "-journal"] {
            let from = database.deletingLastPathComponent().appending(path: name + suffix)
            guard FileManager.default.fileExists(atPath: from.path) else { continue }
            guard (try? FileManager.default.copyItem(at: from, to: temp.appending(path: name + suffix))) != nil else {
                if suffix.isEmpty { return } else { continue }
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.appending(path: name).path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return
        }
        defer { sqlite3_close(db) }
        body(db)
    }

    // MARK: 共通

    /// http・https のブックマークだけを対象にする（javascript: などはブラウザの外では開けないため）
    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func readData(_ url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw mapError(error)
        }
    }

    private static func mapError(_ error: Error) -> BookmarkReadError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoPermissionError: return .permissionDenied
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError: return .notFound
            default: break
            }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) {
            return .permissionDenied
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EPERM) || nsError.code == Int(EACCES) {
            return .permissionDenied
        }
        return .unreadable(nsError.localizedDescription)
    }
}
