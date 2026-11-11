import SwiftUI
import Observation
import Carbon.HIToolbox

/// スリープ防止がいま有効かどうか。メニューバーのアイコンなど、複数の画面から見る。
@MainActor
@Observable
final class KeepAwakeState {
    static let shared = KeepAwakeState()
    fileprivate(set) var isActive = false
    /// 自動で解除する時刻。時間を決めていなければ nil。
    fileprivate(set) var endDate: Date?
}

/// スリープ防止。AI の長い処理など、Mac を動かし続けたいときに、スリープさせない。
/// 有効かどうかは保存しない。アプリを起動し直すと、いつも無効から始まる。
@MainActor
@Observable
final class KeepAwakeModule: ToolModule {
    let id = "keepawake"
    let title = "スリープ防止"
    let systemImage = "cup.and.saucer"

    let state = KeepAwakeState.shared
    static let toggleActionID = "keepawake.toggle"

    /// ディスプレイもスリープさせないか。false なら、Mac 本体だけを動かし続け、画面は消えてよい。
    var keepsDisplayOn: Bool {
        didSet { UserDefaults.standard.set(keepsDisplayOn, forKey: Keys.displayOn); reapplyIfActive() }
    }
    /// 自動で解除するまでの分数。0 なら、自分で止めるまで続ける。
    var durationMinutes: Int {
        didSet { UserDefaults.standard.set(durationMinutes, forKey: Keys.duration); reapplyIfActive() }
    }

    static let durationChoices: [(minutes: Int, label: String)] = [
        (0, "自分で止めるまで"), (30, "30 分"), (60, "1 時間"), (120, "2 時間"), (240, "4 時間"), (480, "8 時間"),
    ]

    @ObservationIgnored private let assertion = SleepAssertion()
    @ObservationIgnored private var timer: Timer?

    private enum Keys {
        static let displayOn = "keepawake.displayOn"
        static let duration = "keepawake.durationMinutes"
    }

    init() {
        UserDefaults.standard.register(defaults: [Keys.displayOn: false, Keys.duration: 0])
        keepsDisplayOn = UserDefaults.standard.bool(forKey: Keys.displayOn)
        durationMinutes = UserDefaults.standard.integer(forKey: Keys.duration)
    }

    var actions: [ShortcutAction] {
        [ShortcutAction(id: Self.toggleActionID, title: "スリープ防止を切り替える",
                        defaultShortcut: .ctrlOpt(kVK_ANSI_S),
                        handler: { [weak self] in self?.toggle() })]
    }

    /// 機能がオフでもメニューに出す。押したときは、オンにするかを確認する。
    var showsMenuItemsWhenDisabled: Bool { true }

    func start() {}

    /// 機能をオフにしたときは、スリープ防止も止める。
    func stop() { turnOff() }

    // MARK: 操作

    func toggle() { state.isActive ? turnOff() : turnOn() }

    func turnOn() {
        let level: SleepAssertion.Level = keepsDisplayOn ? .display : .system
        guard assertion.hold(level, reason: "MitsuTools: スリープ防止") else {
            NSSound.beep()
            return
        }
        scheduleEnd()
        state.isActive = true
    }

    func turnOff() {
        assertion.release()
        timer?.invalidate()
        timer = nil
        state.endDate = nil
        state.isActive = false
    }

    /// 設定を変えたときに、有効なら新しい設定で取り直す（時間は、いまから数え直す）。
    private func reapplyIfActive() {
        guard state.isActive else { return }
        turnOn()
    }

    private func scheduleEnd() {
        timer?.invalidate()
        timer = nil
        guard durationMinutes > 0 else {
            state.endDate = nil
            return
        }
        let end = Date().addingTimeInterval(TimeInterval(durationMinutes) * 60)
        state.endDate = end
        let timer = Timer(fire: end, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in self?.turnOff() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: 画面

    func menuItems() -> AnyView {
        AnyView(KeepAwakeMenuItems(module: self))
    }

    func settingsView() -> AnyView { AnyView(KeepAwakeSettingsView(module: self)) }

    func exportConfig() -> [(key: String, value: TOMLValue)] {
        [("keep_display_on", .bool(keepsDisplayOn)), ("duration_minutes", .int(durationMinutes))]
    }

    func importConfig(_ table: TOMLTable) {
        if let v = table["keep_display_on"]?.bool, v != keepsDisplayOn { keepsDisplayOn = v }
        if let v = table["duration_minutes"]?.int, v >= 0, v != durationMinutes { durationMinutes = v }
    }
}

private struct KeepAwakeMenuItems: View {
    let module: KeepAwakeModule

    var body: some View {
        // 機能がオフのときは、オンにするかを確認してから切り替える（ショートカットと同じ流れ）
        Toggle(isOn: Binding(get: { module.state.isActive }, set: { _ in
            if let action = module.actions.first { AppModel.shared.perform(action, of: module) }
        })) {
            Label("スリープを防止", systemImage: "cup.and.saucer")
        }
        .keyboardShortcut(HotKeyCenter.shared.shortcut(for: KeepAwakeModule.toggleActionID)?.menuShortcut)
        if module.state.isActive, let end = module.state.endDate {
            Text("\(end.formatted(date: .omitted, time: .shortened)) まで")
        }
    }
}

struct KeepAwakeSettingsView: View {
    @Bindable var module: KeepAwakeModule

    var body: some View {
        Form {
            Section {
                Toggle("スリープを防止する", isOn: Binding(
                    get: { module.state.isActive },
                    set: { $0 ? module.turnOn() : module.turnOff() }
                ))
                LabeledContent("切り替えるショートカット") { ShortcutRecorder(actionID: KeepAwakeModule.toggleActionID) }
            } footer: {
                Text("メニューバーのメニューからも切り替えられます。アプリを起動し直すと、無効から始まります。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $module.keepsDisplayOn) {
                    Text("ディスプレイもスリープさせない")
                    Text("オフなら、Mac は動き続け、ディスプレイだけが消えます。")
                }
                Picker("自動で解除するまで", selection: $module.durationMinutes) {
                    ForEach(KeepAwakeModule.durationChoices, id: \.minutes) { Text($0.label).tag($0.minutes) }
                }
            } footer: {
                Text("ふたを閉じたときのスリープは防げません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}
