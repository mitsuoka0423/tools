import SwiftUI
import Carbon.HIToolbox

/// ブックマークマネージャー。選んだブラウザのブックマークを検索し、デフォルトのブラウザで開く。
@MainActor
final class BookmarksModule: ToolModule {
    let id = "bookmarks"
    let title = "ブックマーク"
    let systemImage = "bookmark"

    let store = BookmarkStore()
    private lazy var panel = BookmarkPanelController(store: store)

    static let showActionID = "bookmarks.show"

    var actions: [ShortcutAction] {
        [ShortcutAction(id: Self.showActionID, title: "ブックマークを検索",
                        defaultShortcut: Shortcut(keyCode: kVK_ANSI_B, modifiers: [.control, .option]),
                        handler: { [weak self] in self?.panel.toggle() })]
    }

    func start() { store.start() }

    func stop() {
        panel.close()
        store.stop()
    }

    func menuItems() -> AnyView {
        AnyView(
            Button {
                self.panel.show()
            } label: {
                Label("ブックマークを検索", systemImage: "bookmark")
            }
            // 設定や終了と同じく、ショートカットをメニューの右側に出す
            .keyboardShortcut(HotKeyCenter.shared.shortcut(for: Self.showActionID)?.menuShortcut)
        )
    }

    func settingsView() -> AnyView { AnyView(BookmarksSettingsView(store: store)) }

    func exportConfig() -> [(key: String, value: TOMLValue)] {
        [("sources", .array(store.enabledSourceIDs.sorted().map { .string($0) }))]
    }

    func importConfig(_ table: TOMLTable) {
        if let ids = table["sources"]?.stringArray, Set(ids) != store.enabledSourceIDs {
            store.enabledSourceIDs = Set(ids)
        }
    }
}

struct BookmarksSettingsView: View {
    @Bindable var store: BookmarkStore

    var body: some View {
        Form {
            Section {
                LabeledContent("ブックマークを検索") { ShortcutRecorder(actionID: BookmarksModule.showActionID) }
            }

            Section {
                if store.sources.isEmpty {
                    Text("対応しているブラウザが見つかりません。").foregroundStyle(.secondary)
                }
                ForEach(store.sources) { source in
                    Toggle(isOn: Binding(
                        get: { store.enabledSourceIDs.contains(source.id) },
                        set: { on in
                            var ids = store.enabledSourceIDs
                            if on { ids.insert(source.id) } else { ids.remove(source.id) }
                            store.enabledSourceIDs = ids
                        }
                    )) {
                        HStack(spacing: 8) {
                            appIcon(source)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.name)
                                status(source)
                            }
                        }
                    }
                }
            } header: {
                Text("読み込むブラウザ")
            } footer: {
                HStack {
                    Text("ブックマークはメモリ上だけに読み込みます。検索パネルを開くたびに、変わったブラウザだけ読み直します。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("今すぐ読み直す") { store.reload(force: true) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    @ViewBuilder
    private func status(_ source: BrowserSource) -> some View {
        switch store.statuses[source.id] ?? .notLoaded {
        case .notLoaded:
            EmptyView()
        case let .loaded(count):
            Text("\(count) 件").font(.caption).foregroundStyle(.secondary)
        case let .failed(message):
            HStack(spacing: 6) {
                Text(message).font(.caption).foregroundStyle(.orange)
                grantButton(source)
            }
        case .permissionDenied:
            HStack(spacing: 6) {
                Text("読み込みが許可されていません").font(.caption).foregroundStyle(.orange)
                grantButton(source)
            }
        }
    }

    /// macOS が保護しているデータフォルダを、ユーザーに選んでもらって読めるようにする。
    /// フルディスクアクセスと違い、許可するのはそのフォルダだけ。
    private func grantButton(_ source: BrowserSource) -> some View {
        Button("フォルダを選んで許可…") { store.requestFolderAccess(source) }
            .buttonStyle(.link)
            .font(.caption)
            .help("\(source.name) のデータフォルダだけを読めるようにします")
    }

    @ViewBuilder
    private func appIcon(_ source: BrowserSource) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "globe").frame(width: 20, height: 20)
        }
    }
}
