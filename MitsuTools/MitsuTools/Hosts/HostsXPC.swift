import Foundation

/// アプリ ⇄ 特権ヘルパー（MitsuToolsHelper）の XPC 契約。
/// NSXPC は Objective-C 互換の契約が必要なため、ここで共有する。
/// （アプリとヘルパーの両方にコンパイルされる）
@objc(HostsXPCProtocol)
protocol HostsXPCProtocol {
    /// base64（UTF-8）で渡した内容を /etc/hosts に書き込む。
    /// 書く前の内容は /etc/hosts.mitsutools.bak に残す。flushDNS は DNS のキャッシュを消すかどうか。
    func writeHosts(_ contentBase64: String, flushDNS: Bool, reply: @escaping (Bool, String?) -> Void)
}
