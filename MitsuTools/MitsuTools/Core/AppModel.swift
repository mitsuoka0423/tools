import SwiftUI
import Observation
import ServiceManagement

/// アプリ全体の状態。モジュールの一覧と有効／無効を管理する。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// 機能を追加するときはここに 1 行足す。
    private static func makeModules() -> [any ToolModule] {
        [
            ClipboardModule(),
            WindowModule(),
        ]
    }

    let modules: [any ToolModule]
    private(set) var enabledIDs: Set<String> = []

    /// メニューバーにアイコンを出すかどうか（HIG: 利用者が決められるようにする）。
    var showsMenuBarIcon: Bool {
        didSet { UserDefaults.standard.set(showsMenuBarIcon, forKey: "showsMenuBarIcon") }
    }

    var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("MitsuTools: ログイン項目を変更できませんでした: \(error)")
            }
            loginItemRevision += 1
            ConfigFile.shared.scheduleSave() // UserDefaults を使わない設定なので、ここで書き出す
        }
    }
    /// launchesAtLogin の変更を View に伝えるための値。
    private var loginItemRevision = 0

    private init() {
        UserDefaults.standard.register(defaults: ["showsMenuBarIcon": true])
        showsMenuBarIcon = UserDefaults.standard.bool(forKey: "showsMenuBarIcon")
        modules = Self.makeModules()
    }

    func startEnabledModules() {
        for module in modules where Self.storedEnabled(module.id) {
            enable(module)
        }
    }

    func isEnabled(_ module: any ToolModule) -> Bool {
        _ = loginItemRevision
        return enabledIDs.contains(module.id)
    }

    func setEnabled(_ enabled: Bool, for module: any ToolModule) {
        UserDefaults.standard.set(enabled, forKey: "module.\(module.id).enabled")
        enabled ? enable(module) : disable(module)
    }

    var needsAccessibility: Bool {
        modules.contains { enabledIDs.contains($0.id) && $0.needsAccessibility }
    }

    private func enable(_ module: any ToolModule) {
        guard !enabledIDs.contains(module.id) else { return }
        enabledIDs.insert(module.id)
        module.start()
        module.actions.forEach(HotKeyCenter.shared.register)
    }

    private func disable(_ module: any ToolModule) {
        guard enabledIDs.contains(module.id) else { return }
        enabledIDs.remove(module.id)
        module.actions.forEach { HotKeyCenter.shared.unregister(actionID: $0.id) }
        module.stop()
    }

    private static func storedEnabled(_ id: String) -> Bool {
        UserDefaults.standard.object(forKey: "module.\(id).enabled") as? Bool ?? true
    }
}
