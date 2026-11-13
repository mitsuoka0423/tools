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
            ShortcutAction(id: "window.full", title: "画面全体に広げる", defaultShortcut: .ctrlOpt(kVK_Return),
                           handler: { [weak self] in self?.manager.snapToCell(.full, 0) }),
            ShortcutAction(id: "window.top", title: "上半分へ", defaultShortcut: .ctrlOpt(kVK_UpArrow),
                           handler: { [weak self] in self?.manager.snapToCell(.stacked, 0) }),
            ShortcutAction(id: "window.bottom", title: "下半分へ", defaultShortcut: .ctrlOpt(kVK_DownArrow),
                           handler: { [weak self] in self?.manager.snapToCell(.stacked, 1) }),
            ShortcutAction(id: "window.left", title: "左へ（1/2 → 1/3 → 2/3）", defaultShortcut: .ctrlOpt(kVK_LeftArrow),
                           handler: { [weak self] in self?.manager.snapToSide(left: true) }),
            ShortcutAction(id: "window.right", title: "右へ（1/2 → 1/3 → 2/3）", defaultShortcut: .ctrlOpt(kVK_RightArrow),
                           handler: { [weak self] in self?.manager.snapToSide(left: false) }),
        ]
        for i in 0..<GridLayout.quad.cellCount {
            list.append(ShortcutAction(id: "window.quad.\(i + 1)", title: "2×2 の\(GridLayout.quad.positionName(i))",
                                       defaultShortcut: .ctrlOpt(Shortcut.digitKeyCodes[i]),
                                       handler: { [weak self] in self?.manager.snapToCell(.quad, i) }))
        }
        for i in 0..<GridLayout.six.cellCount {
            list.append(ShortcutAction(id: "window.six.\(i + 1)", title: "2×3 の\(GridLayout.six.positionName(i))",
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

    /// ショートカットはグループごとに切り替えて出す（全部並べると縦に長くなるため）
    private enum Group: String, CaseIterable, Identifiable {
        case basic, quad, six, display
        var id: String { rawValue }
        var label: String {
            switch self {
            case .basic: "配置"
            case .quad: "2×2"
            case .six: "2×3"
            case .display: "ディスプレイ"
            }
        }
    }

    /// 最後に見たグループを次も出す
    @AppStorage("settings.window.group") private var group: Group = .basic

    var body: some View {
        Form {
            PermissionBanner(reason: "ウィンドウを動かすのに使います。")
            Section {
                IconRow(icon: .gap, title: "ウィンドウ間のギャップ") { slider($manager.gap) }
                IconRow(icon: .margin, title: "画面端の余白") { slider($manager.margin) }
            }
            Section {
                switch group {
                case .basic:
                    row(.overlay, "マスを選んで配置", "window.overlay")
                    row(.cell(.full, 0), "画面全体に広げる", "window.full")
                    row(.cell(.stacked, 0), "上半分へ", "window.top")
                    row(.cell(.stacked, 1), "下半分へ", "window.bottom")
                    row(.side(left: true), "左へ（1/2 → 1/3 → 2/3）", "window.left")
                    row(.side(left: false), "右へ（1/2 → 1/3 → 2/3）", "window.right")
                case .quad:
                    ForEach(0..<GridLayout.quad.cellCount, id: \.self) { i in
                        row(.cell(.quad, i), GridLayout.quad.positionName(i), "window.quad.\(i + 1)")
                    }
                case .six:
                    ForEach(0..<GridLayout.six.cellCount, id: \.self) { i in
                        row(.cell(.six, i), GridLayout.six.positionName(i), "window.six.\(i + 1)")
                    }
                case .display:
                    row(.display(next: false), "前のディスプレイへ", "window.display.prev")
                    row(.display(next: true), "次のディスプレイへ", "window.display.next")
                }
            } header: {
                HStack {
                    Text("ショートカット")
                    Spacer()
                    Picker("ショートカットのグループ", selection: $group) {
                        ForEach(Group.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }

    private func row(_ icon: LayoutIcon.Kind, _ title: String, _ actionID: String) -> some View {
        IconRow(icon: icon, title: title) { ShortcutRecorder(actionID: actionID) }
    }

    private func slider(_ value: Binding<Double>) -> some View {
        HStack {
            Slider(value: value, in: 0...40, step: 1).frame(width: 160)
            Text("\(Int(value.wrappedValue)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}
