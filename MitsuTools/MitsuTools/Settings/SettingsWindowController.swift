import AppKit
import SwiftUI

/// 設定ウィンドウ。HIG に合わせ、ツールバーのボタンでペインを切り替える。
/// - ウィンドウのタイトルは表示中のペイン名になる（NSTabViewController が自動で行う）
/// - 最小化・拡大ボタンは無効
/// - 最後に見たペインを次回も開く
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var tabController: NSTabViewController?
    private static let lastPaneKey = "settings.lastPane"

    func show(pane: String? = nil) {
        if window == nil { build() }
        if let pane { select(pane) }
        // メニューバーから開くと、メニューが閉じきる前に前面へ出そうとして負けることがあるので、一拍おく
        DispatchQueue.main.async { [weak self] in self?.bringToFront() }
    }

    /// Dock に出ないアプリは、ほかのアプリが前にいると activate だけでは前面に出られないことがある。
    /// アプリを前面に出したうえで、ウィンドウもほかのアプリより前に並べる。
    private func bringToFront() {
        guard let window else { return }
        NSApp.activate()
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func build() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        tabs.canPropagateSelectedChildViewControllerTitle = true

        tabs.addTabViewItem(item(id: "general", title: "一般", symbol: "gearshape", view: GeneralSettingsView()))
        for module in AppModel.shared.modules {
            tabs.addTabViewItem(item(id: module.id, title: module.title, symbol: module.systemImage, view: module.settingsView()))
        }
        tabs.addTabViewItem(item(id: "update", title: "アップデート", symbol: "arrow.triangle.2.circlepath", view: UpdateSettingsView()))

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        self.tabController = tabs

        if let last = UserDefaults.standard.string(forKey: Self.lastPaneKey) { select(last) }
    }

    private func item<V: View>(id: String, title: String, symbol: String, view: V) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: view.frame(width: 560).fixedSize(horizontal: false, vertical: true))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.title = title
        let item = NSTabViewItem(viewController: hosting)
        item.identifier = id
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func select(_ id: String) {
        guard let tabs = tabController,
              let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == id }) else { return }
        tabs.selectedTabViewItemIndex = index
    }

    func windowWillClose(_ notification: Notification) {
        if let tabs = tabController, let id = tabs.tabViewItems[tabs.selectedTabViewItemIndex].identifier as? String {
            UserDefaults.standard.set(id, forKey: Self.lastPaneKey)
        }
    }
}
