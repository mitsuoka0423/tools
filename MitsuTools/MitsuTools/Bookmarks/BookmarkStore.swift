import AppKit
import Observation

/// 選んだブラウザのブックマークを読み込み、検索する。読み込んだ内容はメモリ上だけに持つ。
@MainActor
@Observable
final class BookmarkStore {
    enum SourceStatus: Equatable {
        case notLoaded
        case loaded(count: Int)
        case failed(String)
        case permissionDenied
    }

    /// この Mac で見つかったブラウザ
    private(set) var sources: [BrowserSource] = []
    private(set) var statuses: [String: SourceStatus] = [:]
    private(set) var bookmarks: [Bookmark] = []

    /// 読み込むブラウザの ID。初期状態では空で、利用者が選んだブラウザだけを読み込む。
    var enabledSourceIDs: Set<String> {
        get {
            access(keyPath: \.enabledSourceIDs)
            return Set(UserDefaults.standard.stringArray(forKey: Self.enabledKey) ?? [])
        }
        set {
            withMutation(keyPath: \.enabledSourceIDs) {
                UserDefaults.standard.set(newValue.sorted(), forKey: Self.enabledKey)
            }
            reload(force: true)
        }
    }

    @ObservationIgnored private var loaded: [String: (date: Date?, items: [Bookmark])] = [:]
    private static let enabledKey = "bookmarks.sources"

    func start() {
        sources = BrowserSource.all.filter(\.isInstalled)
        reload(force: false)
    }

    func stop() {
        loaded.removeAll()
        bookmarks.removeAll()
        statuses.removeAll()
    }

    /// ファイルが変わったブラウザだけ読み直す。force なら全部読み直す。
    func reload(force: Bool) {
        let enabled = enabledSourceIDs
        for source in sources {
            guard enabled.contains(source.id) else {
                loaded[source.id] = nil
                statuses[source.id] = .notLoaded
                continue
            }
            let date = BookmarkFolderAccess.withAccess(source) { BookmarkReader.modificationDate(source) }
            if !force, let cached = loaded[source.id], cached.date == date, date != nil { continue }
            do {
                let items = try BookmarkFolderAccess.withAccess(source) { try BookmarkReader.read(source) }
                loaded[source.id] = (date, items)
                statuses[source.id] = .loaded(count: items.count)
            } catch BookmarkReadError.permissionDenied {
                loaded[source.id] = nil
                statuses[source.id] = .permissionDenied
            } catch {
                loaded[source.id] = nil
                statuses[source.id] = .failed(error.localizedDescription)
            }
        }
        // 同じ URL が複数のブラウザにあるときは、先に見つかった 1 件だけを残す
        var seen = Set<String>()
        bookmarks = sources.flatMap { loaded[$0.id]?.items ?? [] }.filter { seen.insert($0.url.absoluteString).inserted }
    }

    /// ファイル選択の画面でデータフォルダを選んでもらい、読み直す。
    func requestFolderAccess(_ source: BrowserSource) {
        guard BookmarkFolderAccess.request(source) else { return }
        if !enabledSourceIDs.contains(source.id) {
            enabledSourceIDs.insert(source.id) // 読み直しも行われる
        } else {
            reload(force: true)
        }
    }

    /// 空白で区切った語をすべて含むものを返す。タイトルが語で始まるものを先に並べる。
    func search(_ query: String, limit: Int = 300) -> [Bookmark] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Array(bookmarks.prefix(limit)) }
        let first = terms[0]
        var ranked: [(rank: Int, index: Int, item: Bookmark)] = []
        for (index, item) in bookmarks.enumerated() where terms.allSatisfy({ item.searchText.contains($0) }) {
            let title = item.title.lowercased()
            let rank = title.hasPrefix(first) ? 0 : title.contains(first) ? 1 : 2
            ranked.append((rank, index, item))
        }
        ranked.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        return ranked.prefix(limit).map(\.item)
    }
}
