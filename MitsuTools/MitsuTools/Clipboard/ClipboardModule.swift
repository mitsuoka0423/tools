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
        ]
    }

    func importConfig(_ table: TOMLTable) {
        if let v = table["max_count"]?.int, v > 0, v != store.maxCount { store.maxCount = v }
        if let v = table["auto_paste"]?.bool, v != store.autoPaste { store.autoPaste = v }
        if let v = table["skip_concealed"]?.bool, v != store.skipConcealed { store.skipConcealed = v }
    }
}

private struct ClipboardMenuItems: View {
    let module: ClipboardModule

    var body: some View {
        Button {
            module.showPanel()
        } label: {
            Label("クリップボード履歴を表示", systemImage: "list.clipboard")
        }
        // 設定や終了と同じく、ショートカットをメニューの右側に出す
        .keyboardShortcut(HotKeyCenter.shared.shortcut(for: ClipboardModule.showActionID)?.menuShortcut)
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
            // 枠付きの入力欄にして、入力できることがわかるようにする。
            // ラベルは行の左に「保持する件数」と出ているので、入力欄には付けない。
            TextField(text: $text, prompt: Text(String(ClipboardStore.defaultMaxCount))) { EmptyView() }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
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
            PermissionBanner(reason: "選んだ履歴を、元のアプリに自動で貼り付けるのに使います。")
            Section {
                LabeledContent("履歴を表示") { ShortcutRecorder(actionID: ClipboardModule.showActionID) }
                LabeledContent("保持する件数") { MaxCountField(store: store) }
                Toggle("選んだ項目をすぐ貼り付ける", isOn: $store.autoPaste)
            } footer: {
                Text("履歴はメモリ上だけに保持し、終了すると消えます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("パスワードなどの機密データを記録しない", isOn: $store.skipConcealed)
            } header: {
                Text("プライバシー")
            } footer: {
                Text("記録しないアプリは、「一般」の「機密情報を扱うアプリ」で設定します（全機能に共通）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
