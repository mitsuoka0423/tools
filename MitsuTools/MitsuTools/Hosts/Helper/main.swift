import Foundation

/// MitsuTools の特権ヘルパー（root で動く LaunchDaemon）。
/// /etc/hosts を書く処理だけを担う。アプリとは Mach サービス経由の XPC でやり取りする。
///
/// セキュリティ上のnote: この Mach サービスはログイン中のセッションから誰でも接続できる。
/// できることは「/etc/hosts を置き換える」だけ（root で任意コマンドは実行しない）。
/// 接続元アプリの署名検証は試験段階では行っていない（必要なら SecCode で追加する）。
///
/// 自己テスト（launchd 不要）: `MitsuToolsHelper --selftest <path>` はそのファイルに "selftest" と書く。

private enum HelperError: LocalizedError {
    case notBase64
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .notBase64: return "中身を復号できませんでした"
        case .cannotWrite(let m): return m
        }
    }
}

private final class Handler: NSObject, HostsXPCProtocol {
    func writeHosts(_ contentBase64: String, flushDNS: Bool, reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try Self.perform(contentBase64: contentBase64, flushDNS: flushDNS)
                reply(true, nil)
            } catch {
                reply(false, error.localizedDescription)
            }
        }
    }

    static func perform(contentBase64: String, flushDNS: Bool) throws {
        guard let content = Data(base64Encoded: contentBase64) else { throw HelperError.notBase64 }
        let hosts = URL(fileURLWithPath: "/etc/hosts")
        let backup = URL(fileURLWithPath: "/etc/hosts.mitsutools.bak")
        // 今あるものをバックアップ（失敗しても書き込みは続ける：空ファイル状態からでも直せるように）
        if let current = try? Data(contentsOf: hosts) {
            try? current.write(to: backup, options: .atomic)
        }
        do {
            try content.write(to: hosts, options: .atomic)
        } catch {
            throw HelperError.cannotWrite(error.localizedDescription)
        }
        if flushDNS {
            run("/usr/bin/dscacheutil", ["-flushcache"])
            run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        }
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// 接続を受けても、このアプリ由来の操作にだけ応じる（試験段階：同一セッションなら受け入れる）
private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HostsXPCProtocol.self)
        newConnection.exportedObject = Handler()
        newConnection.resume()
        return true
    }
}

// MARK: 入口

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--selftest"), i + 1 < arguments.count {
    // 管理者でなくても通る自己テスト（launchd 経由でない確認用）
    do {
        try Data("selftest\n".utf8).write(to: URL(fileURLWithPath: arguments[i + 1]), options: .atomic)
        print("selftest ok")
        exit(0)
    } catch {
        print("selftest failed: \(error)")
        exit(1)
    }
}

let listener = NSXPCListener(machServiceName: "com.mitsuoka0423.MitsuTools.helper")
private let delegate = ListenerDelegate()
listener.delegate = delegate
listener.resume()
// delegate を解放しないよう保持する
withExtendedLifetime(delegate) {
    dispatchMain()
}
