import Foundation

/// /etc/hosts を読み書きする。
///
/// MitsuTools が管理する区間（マーカーで挟んだブロック）だけを差し替える。
/// システムの既定の行（localhost など）はそのまま残す。
/// 書き換えには管理者権限が要るので、OS 標準のパスワードダイアログで認可を受ける。
enum HostsFile {
    static let path = "/etc/hosts"
    /// 直前の内容を残す場所（書き換えるたびに上書きする）
    static let backupPath = "/etc/hosts.mitsutools.bak"

    static let beginMarker = "# >>> mitsutools >>>"
    static let endMarker = "# <<< mitsutools <<<"

    struct State: Equatable {
        /// 現在適用されているプロファイル名
        var appliedProfileName: String?
        /// 適用されている行
        var appliedEntries: [String] = []
        /// 管理区間があるか
        var hasManagedBlock = false
        /// /etc/hosts を読めたか
        var readable = true

        var isApplied: Bool { hasManagedBlock }
    }

    enum HostsError: LocalizedError {
        case cannotRead(String)
        case privilegedFailed(String)

        var errorDescription: String? {
            switch self {
            case .cannotRead(let m): return "/etc/hosts を読めませんでした: \(m)"
            case .privilegedFailed(let m): return "書き込めませんでした: \(m)"
            }
        }
    }

    // MARK: 読む

    static func read() -> (content: String, state: State) {
        guard let content = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            return ("", State(appliedProfileName: nil, readable: false))
        }
        return (content, parse(content))
    }

    /// 管理区間の内容を取り出す。
    static func parse(_ content: String) -> State {
        let lines = content.components(separatedBy: "\n")
        var state = State(appliedProfileName: nil)
        var inside = false
        var name: String?
        var entries: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == beginMarker {
                inside = true
                name = nil
                entries = []
                continue
            }
            if trimmed == endMarker {
                inside = false
                state.hasManagedBlock = true
                state.appliedProfileName = name
                state.appliedEntries = entries
                continue
            }
            if inside {
                if trimmed.hasPrefix("# mitsutools profile:") {
                    name = String(trimmed.dropFirst("# mitsutools profile:".count)).trimmingCharacters(in: .whitespaces)
                } else if !trimmed.isEmpty {
                    entries.append(trimmed)
                }
            }
        }
        return state
    }

    // MARK: 組み立て

    /// プロファイルを適用した後の内容。管理区間は先頭に置く（同じホスト名なら先に書かれた ones が効くため）。
    static func content(applying profile: HostsProfile) -> String {
        let block = managedBlock(profile: profile)
        let (current, _) = read()
        let rest = removingManagedBlock(current)
        return rest.isEmpty ? block + "\n" : block + "\n" + rest
    }

    /// 管理区間を取り除いた内容。区間がなければ、元のままを返す。
    static func contentWithoutManagedBlock() -> String {
        let rest = removingManagedBlock(read().content)
        return rest.isEmpty ? "# 这里是空的（MitsuTools 的管理区间已解除）\n" : rest + "\n"
    }

    /// 管理区間を取り除いた内容
    static func removingManagedBlock(_ content: String) -> String {
        var out: [String] = []
        var inside = false
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == beginMarker { inside = true; continue }
            if trimmed == endMarker { inside = false; continue }
            if !inside { out.append(line) }
        }
        // 余計な空行を詰める
        while out.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeFirst() }
        while out.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    static func managedBlock(profile: HostsProfile) -> String {
        var lines = [beginMarker, "# mitsutools profile: \(profile.displayName)"]
        lines += profile.entries.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    // MARK: 書く（管理者権限）

    /// 内容を書き換える。直前までの内容はバックアップに残す。
    static func write(content: String, flushDNS: Bool) throws {
        var command = "cp -p \(path) \(backupPath) && printf %s '\(Data(content.utf8).base64EncodedString())' | base64 -D > \(path)"
        if flushDNS {
            command += " && dscacheutil -flushcache && (killall -HUP mDNSResponder || true)"
        }
        try runPrivileged(command)
    }

    /// 直前の内容（バックアップ）から戻す
    static func restoreBackup() throws {
        guard FileManager.default.fileExists(atPath: backupPath) else {
            throw HostsError.cannotRead("バックアップ（\(backupPath)）がありません")
        }
        try runPrivileged("cp -p \(backupPath) \(path) && (killall -HUP mDNSResponder || true)")
    }

    /// OS 標準のパスワードダイアログで認可を受けて、管理者権限でコマンドを実行する。
    static func runPrivileged(_ command: String) throws {
        // AppleScript の文字列の中に二重引用符があればエスケープする（base64 の中身は quoting しない）
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()
        try process.run()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "不明なエラー"
            throw HostsError.privilegedFailed(message)
        }
    }
}
