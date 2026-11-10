import SwiftUI
import UniformTypeIdentifiers
import Carbon.HIToolbox

/// クリップボードマネージャー。
@MainActor
final class ClipboardModule: ToolModule {
    let id = "clipboard"
    let title = "クリップボード"
    let systemImage = "list.clipboard"
    let needsAccessibility = true // 自動貼り付けに使う

    let store = ClipboardStore()
    private lazy var panel = ClipboardPanelController(store: store)

    static let showActionID = "clipboard.show"

    var actions: [ShortcutAction] {
        [ShortcutAction(id: Self.showActionID, title: "クリップボード履歴を表示",
                        defaultShortcut: Shortcut(keyCode: kVK_ANSI_V, modifiers: [.shift, .command]),
                        handler: { [weak self] in self?.panel.toggle() })]
    }

    func start() { store.start() }

    func stop() {
        panel.close()
        store.stop()
    }

    func menuItems() -> AnyView {
        AnyView(ClipboardMenuItems(module: self))
    }

    func settingsView() -> AnyView {
        AnyView(ClipboardSettingsView(store: store))
    }

    func showPanel() { panel.show() }

    func exportConfig() -> [(key: String, value: TOMLValue)] {
        [
            ("max_count", .int(store.maxCount)),
            ("auto_paste", .bool(store.autoPaste)),
            ("skip_concealed", .bool(store.skipConcealed)),
            ("excluded_apps", .array(store.excludedBundleIDs.map { .string($0) })),
        ]
    }

    func importConfig(_ table: TOMLTable) {
        if let v = table["max_count"]?.int, v > 0, v != store.maxCount { store.maxCount = v }
        if let v = table["auto_paste"]?.bool, v != store.autoPaste { store.autoPaste = v }
        if let v = table["skip_concealed"]?.bool, v != store.skipConcealed { store.skipConcealed = v }
        if let v = table["excluded_apps"]?.stringArray, v != store.excludedBundleIDs { store.excludedBundleIDs = v }
    }
}

private struct ClipboardMenuItems: View {
    let module: ClipboardModule

    var body: some View {
        Button {
            module.showPanel()
        } label: {
            Label("クリップボード履歴を表示", systemImage: "list.clipboard")
            if let s = HotKeyCenter.shared.shortcut(for: ClipboardModule.showActionID) {
                Text(s.displayString)
            }
        }
        Toggle(isOn: Binding(get: { module.store.isPaused }, set: { module.store.isPaused = $0 })) {
            Label("記録を一時停止", systemImage: "pause.circle")
        }
    }
}

/// 保持する件数の入力欄。
/// 入力途中の値（例: 1000 を打つ途中の「1」）で履歴が消えないよう、
/// return を押すかフォーカスが外れたときにだけ反映する。
private struct MaxCountField: View {
    @Bindable var store: ClipboardStore
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("件数", text: $text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 80)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
            Text("件")
        }
        .help("1〜\(ClipboardStore.maxCountLimit) 件。return で確定します。")
        .onAppear { text = String(store.maxCount) }
        .onChange(of: store.maxCount) { text = String(store.maxCount) }
    }

    private func commit() {
        let digits = text.filter(\.isNumber)
        if let value = Int(digits), value > 0 {
            store.maxCount = value
        }
        text = String(store.maxCount)
    }
}

struct ClipboardSettingsView: View {
    @Bindable var store: ClipboardStore

    var body: some View {
        Form {
            Section {
                LabeledContent("履歴を表示") { ShortcutRecorder(actionID: ClipboardModule.showActionID) }
                LabeledContent("保持する件数") { MaxCountField(store: store) }
                Toggle("選んだ項目をすぐ貼り付ける", isOn: $store.autoPaste)
            } footer: {
                Text("履歴はメモリ上だけに保持し、終了すると消えます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("プライバシー") {
                Toggle("パスワードなどの機密データを記録しない", isOn: $store.skipConcealed)
                LabeledContent("記録しないアプリ") {
                    Button("追加…", action: addExcludedApp)
                }
                ForEach(store.excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        appLabel(bundleID)
                        Spacer()
                        Button {
                            store.excludedBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("リストから外す")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    @ViewBuilder
    private func appLabel(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Label {
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
            }
        } else {
            Text(bundleID).foregroundStyle(.secondary)
        }
    }

    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !store.excludedBundleIDs.contains(id) {
                store.excludedBundleIDs.append(id)
            }
        }
    }
}
