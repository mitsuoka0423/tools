import Foundation

/// /etc/hosts に書くプロファイル。名前と、行の並び。
struct HostsProfile: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    /// "127.0.0.1 dev.local" のような行
    var entries: [String]

    var displayName: String { name.isEmpty ? "無題" : name }
}
