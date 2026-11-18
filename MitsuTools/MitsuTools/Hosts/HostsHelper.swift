import AppKit
import Foundation
import ServiceManagement

/// 特権ヘルパー（MitsuToolsHelper）の管理とやり取り。
///
/// ヘルパーは SMAppService で登録する LaunchDaemon（root で動く小さなプログラム）。
/// 一度ユーザーが許可すれば、その後の hosts の書き換えに管理者パスワードは要らない。
/// 入っていない・許可が下りていないときは、アプリ側が osascript（パスワード）方式に
/// 自動で戻る。
@MainActor
enum HostsHelper {
    static let serviceName = "com.mitsuoka0423.MitsuTools.helper"
    static let plistName = "com.mitsuoka0423.MitsuTools.helper.plist"

    enum State: Equatable {
        case notInstalled
        /// 登録は済んだ。システム設定（一般 › ログイン項目と拡張機能）の許可待ち
        case requiresApproval
        /// 入っていて使える
        case active
    }

    enum HostsHelperError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let m) = self { m } else { nil } }
    }

    private static var service: SMAppService { .daemon(plistName: plistName) }

    static func state() -> State {
        switch service.status {
        case .enabled: return .active
        case .requiresApproval: return .requiresApproval
        default: return .notInstalled
        }
    }

    /// ヘルパーを登録する。OS の同意を求める画面が出るか、システム設定での承認待ちになる。
    /// （アプリを更新したあとも、たいていはそのまま効き続ける）
    @discardableResult
    static func install() -> State {
        do {
            try service.register()
        } catch {
            // 同意待ち（requiresApproval）も例外で返ることがあるので、状態をそのまま返す
            NSLog("MitsuTools: ヘルパーの登録に失敗: \(error)")
        }
        return state()
    }

    static func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSApp.activate()
            NSWorkspace.shared.open(url)
        }
    }

    /// ヘルパー経由で /etc/hosts を書く。うまくいかなければエラー（呼び出し側がパスワード方式に戻る）。
    nonisolated static func write(content: String, flushDNS: Bool) async throws {
        let base64 = Data(content.utf8).base64EncodedString()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let connection = NSXPCConnection(serviceName: serviceName)
            connection.remoteObjectInterface = NSXPCInterface(with: HostsXPCProtocol.self)
            var finished = false
            // 完了は必ずメインで一度だけ（割り込み・無効化・応答が競合するため）
            func complete(_ result: Result<Void, Error>) {
                DispatchQueue.main.async {
                    guard !finished else { return }
                    finished = true
                    connection.invalidate()
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            }
            connection.interruptionHandler = { complete(.failure(HostsHelperError.failed("ヘルパーとの接続が切れました"))) }
            connection.invalidationHandler = connection.interruptionHandler
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                complete(.failure(HostsHelperError.failed(error.localizedDescription)))
            }) as? HostsXPCProtocol else {
                complete(.failure(HostsHelperError.failed("ヘルパーの取り決めを取り出せませんでした")))
                return
            }
            proxy.writeHosts(base64, flushDNS: flushDNS) { ok, message in
                complete(ok ? .success(()) : .failure(HostsHelperError.failed(message ?? "書き込めませんでした")))
            }
            // ヘルパーが起動しないなどで応答がないときの上限
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                complete(.failure(HostsHelperError.failed("ヘルパーが応答しませんでした")))
            }
        }
    }
}
