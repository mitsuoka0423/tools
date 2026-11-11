import SwiftUI

@main
struct MitsuToolsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: $model.showsMenuBarIcon) {
            MenuContent()
        } label: {
            // 機能（モジュール）が増えても変わらない、固定のアイコン。
            // テンプレート画像として扱われ、メニューバーの明暗に合わせて色が付く。
            Image(systemName: "square.grid.2x2")
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Updater.shared
        AppModel.shared.startEnabledModules()
        ConfigFile.shared.start()
        if AppModel.shared.needsAccessibility && !AccessibilityPermission.shared.isTrusted {
            SettingsWindowController.shared.show(pane: "general")
        }
    }

    /// メニューバーのアイコンを隠しているときでも、アプリをもう一度開けば設定を出す。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return false
    }
}

/// メニューバーのアイコンをクリックしたときのメニュー。
struct MenuContent: View {
    private let model = AppModel.shared

    var body: some View {
        ForEach(model.modules, id: \.id) { module in
            if model.isEnabled(module) || module.showsMenuItemsWhenDisabled {
                module.menuItems()
            }
        }
        Divider()
        Button {
            Updater.shared.checkForUpdates()
        } label: {
            Label("アップデートを確認…", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!Updater.shared.canCheckForUpdates)
        Button {
            SettingsWindowController.shared.show()
        } label: {
            Label("設定…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)
        Divider()
        Button {
            NSApp.terminate(nil)
        } label: {
            Label("MitsuTools を終了", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
