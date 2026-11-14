import AppKit
import Observation

/// VS Code 系のエディタ（自動コピーにアプリ側の設定が要るもの）の一覧と状態。
/// インストールされている既知のアプリを上げ、それぞれの settings.json を読む。
@MainActor
@Observable
final class EditContextApps {
    static let shared = EditContextApps()

    struct Item: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        let icon: NSImage
        let settingsFile: URL
        var status: EditContextSettings.Status
    }

    private(set) var items: [Item] = []

    /// Bundle ID → Application Support のフォルダ名（設定ファイルのある場所）
    private static let known: [(bundleID: String, folder: String)] = [
        ("com.microsoft.VSCode", "Code"),
        ("com.microsoft.VSCodeInsiders", "Code - Insiders"),
        ("com.visualstudio.code.oss", "VSCodium"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.exafunction.windsurf", "Windsurf"),
    ]

    /// アプリの設定ファイルの場所。一覧にないフォークは「アプリ名 = フォルダ名」とあたりをつける。
    static func settingsFile(bundleID: String?, appName: String?) -> URL? {
        guard let folder = known.first(where: { $0.bundleID == bundleID })?.folder ?? appName,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent(folder).appendingPathComponent("User").appendingPathComponent("settings.json")
    }

    func refresh() {
        var found: [Item] = []
        for entry in Self.known {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID),
                  let file = Self.settingsFile(bundleID: entry.bundleID, appName: nil) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            found.append(Item(bundleID: entry.bundleID, name: name,
                              icon: NSWorkspace.shared.icon(forFile: url.path),
                              settingsFile: file, status: EditContextSettings.status(at: file)))
        }
        items = found
    }

    /// そのアプリの設定を書き、状態を読み直す
    @discardableResult
    func configure(_ item: Item) -> EditContextSettings.WriteResult {
        let result = EditContextSettings.configure(item.settingsFile)
        if let i = items.firstIndex(where: { $0.bundleID == item.bundleID }) {
            items[i].status = EditContextSettings.status(at: items[i].settingsFile)
        }
        return result
    }

    /// エディタの側で検出したアプリ（一覧にないフォークも想定）を治す。設定ファイルの場所が不明なら nil。
    @discardableResult
    static func configure(bundleID: String?, appName: String?) -> (result: EditContextSettings.WriteResult, file: URL)? {
        guard let file = settingsFile(bundleID: bundleID, appName: appName) else { return nil }
        return (EditContextSettings.configure(file), file)
    }
}
