import SwiftUI
import Observation

/// インストールされているアプリ 1 つ。
struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID }
}

/// アプリ起動。インストールされているアプリを一覧にし、アプリごとにショートカットを割り当てて開く。
/// ショートカットの初期値はどれも未設定。
@MainActor
@Observable
final class LauncherModule: ToolModule {
    let id = "launcher"
    let title = "アプリ起動"
    let systemImage = "arrow.up.forward.app"

    private(set) var apps: [InstalledApp] = []

    init() {
        apps = Self.scanInstalledApps()
    }

    static func actionID(_ bundleID: String) -> String { "launcher.\(bundleID)" }

    var actions: [ShortcutAction] {
        apps.map { app in
            ShortcutAction(id: Self.actionID(app.bundleID), title: "\(app.name) を開く",
                           defaultShortcut: nil,
                           handler: { Self.launch(app.bundleID) })
        }
    }

    func start() {}
    func stop() {}

    func settingsView() -> AnyView { AnyView(LauncherSettingsView(module: self)) }

    /// アプリの追加・削除を反映する（設定ペインを開いたときに呼ぶ）
    func rescan() {
        let scanned = Self.scanInstalledApps()
        guard scanned != apps else { return }
        apps = scanned
        AppModel.shared.actionsDidChange(for: self)
    }

    // MARK: 起動

    /// アプリを開く。起動していれば前面に出す。
    static func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSSound.beep()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error { NSLog("MitsuTools: \(bundleID) を開けませんでした: \(error)") }
        }
    }

    // MARK: 一覧

    /// アプリの置き場所（その直下と、1 つ下のフォルダ。例: /Applications/Utilities）
    private static var searchFolders: [URL] {
        [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            URL(filePath: "/System/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    }

    static func scanInstalledApps() -> [InstalledApp] {
        let fm = FileManager.default
        var found: [String: InstalledApp] = [:]
        func add(_ url: URL) {
            guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                  found[bundleID] == nil else { return }
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            found[bundleID] = InstalledApp(bundleID: bundleID, name: name, url: url)
        }
        for folder in searchFolders {
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])) ?? []
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct LauncherSettingsView: View {
    let module: LauncherModule
    @State private var query = ""

    private var center: HotKeyCenter { .shared }

    /// 割り当て済みを上に、残りを名前順に並べる
    private var shownApps: [InstalledApp] {
        let filtered = query.isEmpty ? module.apps : module.apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
        let assigned = filtered.filter { center.shortcut(for: LauncherModule.actionID($0.bundleID)) != nil }
        let others = filtered.filter { center.shortcut(for: LauncherModule.actionID($0.bundleID)) == nil }
        return assigned + others
    }

    var body: some View {
        Form {
            Section {
                TextField("アプリを検索", text: $query, prompt: Text("アプリ名で絞り込む"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shownApps) { app in
                            row(app)
                            Divider()
                        }
                        if shownApps.isEmpty {
                            Text("一致するアプリはありません").foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .frame(height: 360)
            } header: {
                Text("アプリとショートカット")
            } footer: {
                Text("ショートカットを割り当てたアプリが上に並びます。押すとそのアプリを開き、開いていれば前面に出します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear { module.rescan() }
    }

    private func row(_ app: InstalledApp) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                .resizable()
                .frame(width: 20, height: 20)
            Text(app.name).lineLimit(1)
            Spacer()
            ShortcutRecorder(actionID: LauncherModule.actionID(app.bundleID))
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
    }
}
