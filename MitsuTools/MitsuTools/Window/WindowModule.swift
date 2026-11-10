import SwiftUI
import Carbon.HIToolbox

/// ウィンドウマネージャー。1 回の操作で動かすのはアクティブウィンドウ 1 つだけ。
@MainActor
final class WindowModule: ToolModule {
    let id = "window"
    let title = "ウィンドウ"
    let systemImage = "macwindow"
    let needsAccessibility = true

    let manager = WindowManager()
    private lazy var overlay = GridOverlayController(manager: manager)

    var actions: [ShortcutAction] {
        var list: [ShortcutAction] = [
            ShortcutAction(id: "window.overlay", title: "マスを選んで配置", defaultShortcut: .ctrlOpt(kVK_ANSI_G),
                           handler: { [weak self] in self?.overlay.toggle() }),
            ShortcutAction(id: "window.left", title: "左へ（1/2 → 1/3 → 2/3）", defaultShortcut: .ctrlOpt(kVK_LeftArrow),
                           handler: { [weak self] in self?.manager.snapToSide(left: true) }),
            ShortcutAction(id: "window.right", title: "右へ（1/2 → 1/3 → 2/3）", defaultShortcut: .ctrlOpt(kVK_RightArrow),
                           handler: { [weak self] in self?.manager.snapToSide(left: false) }),
        ]
        for i in 0..<GridLayout.quad.cellCount {
            list.append(ShortcutAction(id: "window.quad.\(i + 1)", title: "2×2 のマス \(i + 1)",
                                       defaultShortcut: .ctrlOpt(Shortcut.digitKeyCodes[i]),
                                       handler: { [weak self] in self?.manager.snapToCell(.quad, i) }))
        }
        for i in 0..<GridLayout.six.cellCount {
            list.append(ShortcutAction(id: "window.six.\(i + 1)", title: "2×3 のマス \(i + 1)",
                                       defaultShortcut: .ctrlOptShift(Shortcut.digitKeyCodes[i]),
                                       handler: { [weak self] in self?.manager.snapToCell(.six, i) }))
        }
        list += [
            ShortcutAction(id: "window.display.prev", title: "前のディスプレイへ", defaultShortcut: .ctrlOptCmd(kVK_LeftArrow),
                           handler: { [weak self] in self?.manager.moveToDisplay(next: false) }),
            ShortcutAction(id: "window.display.next", title: "次のディスプレイへ", defaultShortcut: .ctrlOptCmd(kVK_RightArrow),
                           handler: { [weak self] in self?.manager.moveToDisplay(next: true) }),
        ]
        return list
    }

    func start() {}
    func stop() { overlay.close() }

    // HIG に合わせ、ウィンドウ操作はメニューに出さずショートカットだけで行う。
    func settingsView() -> AnyView { AnyView(WindowSettingsView(manager: manager)) }

    func exportConfig() -> [(key: String, value: TOMLValue)] {
        [("gap", .double(manager.gap)), ("margin", .double(manager.margin))]
    }

    func importConfig(_ table: TOMLTable) {
        if let v = table["gap"]?.double, v >= 0, v != manager.gap { manager.gap = v }
        if let v = table["margin"]?.double, v >= 0, v != manager.margin { manager.margin = v }
    }
}

struct WindowSettingsView: View {
    @Bindable var manager: WindowManager

    private let groups: [(String, [String])] = [
        ("ショートカット", ["window.overlay", "window.left", "window.right"]),
        ("2×2 のマス", (1...4).map { "window.quad.\($0)" }),
        ("2×3 のマス", (1...6).map { "window.six.\($0)" }),
        ("ディスプレイ", ["window.display.prev", "window.display.next"]),
    ]

    var body: some View {
        Form {
            Section {
                slider("ウィンドウ間のギャップ", value: $manager.gap)
                slider("画面端の余白", value: $manager.margin)
            }
            ForEach(groups, id: \.0) { title, ids in
                Section(title) {
                    ForEach(ids, id: \.self) { id in
                        LabeledContent(HotKeyCenter.shared.actions[id]?.title ?? id) {
                            ShortcutRecorder(actionID: id)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: 0...40, step: 1).frame(width: 160)
                Text("\(Int(value.wrappedValue)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
    }
}
