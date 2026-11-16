import Foundation
import SQLite3

/// 他のアプリからの通知。macOS が Notification Center に保存したものから拾う。
struct IncomingNotification {
    let uuid: String
    let bundleID: String?
    let title: String
    let subtitle: String?
    let body: String
    /// Unix 時刻（秒）
    let date: TimeInterval
}

/// ユーザード（Notification Center）の SQLite データベースを読む。
///
/// macOS は届いた通知を ~/Library/Group Containers/group.com.apple.usernoted/db2/db
/// に溜めている。読むには「フルディスクアクセス」の許可が要る。
/// Apple の公開 API ではないので、構造が変わったら追随が必要（試験運用中とする理由）。
///
/// 2026-11（macOS 26）で実物を確認した形:
/// - record: rec_id（単調増加）/ app_id（app テーブルへの外部キー）/ uuid(BLOB16) /
///   data(BLOB) / delivered_date（リファレンス時刻 2001 基準の REAL）
/// - app:    app_id / identifier（Bundle ID）
/// - data:   binary plist。{ app, date, req: { titl, subs?, body, atta? … } }
final class UserNotedStore {
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")

    /// macOS の内部時刻（2001-01-01 基準）→ Unix 時刻
    private static let referenceDate: TimeInterval = 978_307_200

    private var db: OpaquePointer?
    /// 最後に読んだ rec_id。これより大きいものだけを出す
    private var lastRecID: Int64 = 0

    /// データベースを開けるかどうかだけ見る（許可の確認用。開いたらすぐ閉じる）。
    static func canOpen() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        return sqlite3_open_v2(fileURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
    }

    /// 起動時・許可が出たあとに呼ぶ。開けたら true。
    /// 開いた時点で入っているぶんは「過去のもの」として数えない。
    @discardableResult
    func open() -> Bool {
        close()
        guard Self.canOpen() else { return false }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(Self.fileURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            sqlite3_close(handle)
            return false
        }
        sqlite3_busy_timeout(handle, 100)
        db = handle
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT COALESCE(MAX(rec_id), 0) FROM record", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            lastRecID = sqlite3_column_int64(statement, 0)
        }
        sqlite3_finalize(statement)
        return true
    }

    func close() {
        if let db { sqlite3_close(db) }
        db = nil
    }

    var isOpen: Bool { db != nil }

    /// 最後に読んだあとに届いた通知を、古い順に。開けなければ空。
    func newArrivals(limit: Int = 5) -> [IncomingNotification] {
        guard let db else { return [] }
        var statement: OpaquePointer?
        let sql = """
            SELECT r.rec_id, a.identifier, r.uuid, r.delivered_date, r.data
            FROM record r LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ? ORDER BY r.rec_id ASC LIMIT ?
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            reopenQuietly() // 構造が変わった／ファイルが書き換えられた可能是あるので、開き直す
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, lastRecID)
        sqlite3_bind_int(statement, 2, Int32(limit))

        var out: [IncomingNotification] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let recID = sqlite3_column_int64(statement, 0)
            lastRecID = max(lastRecID, recID)
            let bytes = sqlite3_column_bytes(statement, 4)
            guard bytes > 0, let blob = sqlite3_column_blob(statement, 4) else { continue }
            let data = Data(bytes: blob, count: Int(bytes)) // step までにコピーする
            guard let item = Self.decode(data: data,
                                         uuid: Self.hex(statement, 2) ?? "rec-\(recID)",
                                         deliveredDate: sqlite3_column_double(statement, 3),
                                         appIdentifier: Self.text(statement, 1)) else { continue }
            if item.title.isEmpty, item.body.isEmpty { continue }
            out.append(item)
        }
        return out
    }

    private func reopenQuietly() {
        close()
        _ = open()
    }

    private static func text(_ s: OpaquePointer, _ col: Int32) -> String? {
        guard let c = sqlite3_column_text(s, col) else { return nil }
        // sqlite3_column_text は unsigned char 扱いで来るので、C の文字列として読み直す
        return String(cString: UnsafeRawPointer(c).assumingMemoryBound(to: CChar.self))
    }

    private static func hex(_ s: OpaquePointer, _ col: Int32) -> String? {
        let n = sqlite3_column_bytes(s, col)
        guard n > 0, let p = sqlite3_column_blob(s, col) else { return nil }
        return Data(bytes: p, count: Int(n)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: record.data の中身

    /// plist を読んで、表示に使える形にする。壊れた行や未知の形は nil（無視）。
    static func decode(data: Data, uuid: String, deliveredDate: TimeInterval, appIdentifier: String?) -> IncomingNotification? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        // 本体は "req" の中。念のため、トップに直接 titl/body がある形も見る
        let req = plist["req"] as? [String: Any] ?? plist
        func str(_ key: String) -> String? { (req[key] as? String)?.nilIfBlank }
        let bundle = (plist["app"] as? String) ?? appIdentifier
        let title = str("titl") ?? str("title") ?? str("appName")
            ?? bundle.flatMap { Bundle(identifier: $0)?.localizedInfoDictionary?["CFBundleDisplayName"] as? String }
            ?? "通知"
        var date = deliveredDate
        if date <= 0, let d = plist["date"] as? Double { date = d }
        return IncomingNotification(uuid: uuid, bundleID: bundle?.nilIfBlank, title: title,
                                    subtitle: str("subs") ?? str("subtitle"),
                                    body: str("body") ?? "",
                                    date: date > 0 ? date + referenceDate : Date().timeIntervalSince1970)
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
