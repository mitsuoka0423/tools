import Foundation

/// /etc/hosts に書くプロファイル。名前と、行の並び。
struct HostsProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// "127.0.0.1 dev.local" のような行
    var entries: [String]

    var displayName: String { name.isEmpty ? "無題" : name }

    /// /etc/hosts に書く形に整えた行（空行・コメント行を落とし、余白を詰める）
    var contentLines: [String] {
        entries.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
