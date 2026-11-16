import SwiftUI
import Observation

/// 「通知」の実験中の設定。UserDefaults に保存する。
@MainActor
@Observable
final class NotificationSettings {
    /// 1 件の通知を出しておく時間（秒）
    var showSeconds: Double { didSet { defaults.set(showSeconds, forKey: Keys.seconds) } }
    /// 出さないアプリ（Bundle ID）。一般の「機密情報を扱うアプリ」に加えて。
    var hiddenBundleIDs: [String] { didSet { defaults.set(hiddenBundleIDs, forKey: Keys.hidden) } }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let seconds = "notifications.showSeconds"
        static let hidden = "notifications.hiddenBundleIDs"
    }

    static let secondChoices: [Double] = [1.5, 2.5, 4.0, 6.0]

    init() {
        defaults.register(defaults: [Keys.seconds: 2.5])
        showSeconds = defaults.double(forKey: Keys.seconds)
        hiddenBundleIDs = defaults.stringArray(forKey: Keys.hidden) ?? []
    }
}

/// 通知をノッチ周りには表示（試験運用中）。
///
/// macOS が Notification Center のデータベースに保存した通知を、1.5 秒おきに読んで出す。
/// Apple に公開された仕組みではないため、OS のアップデートで読めなくなる可能性がある。
/// 元バナーを消すことはできないので、元も消したいときは集中モードを使う。
@MainActor
final class NotificationModule: ToolModule {
    let id = "notifications"
    let title = "通知"
    let systemImage = "bell.badge"
    let actions: [ShortcutAction] = []
    var isExperimental: Bool { true }
    var showsMenuItemsWhenDisabled: Bool { true }

    let settings = NotificationSettings()
    private let store = UserNotedStore()
    private let display = NotchDisplay()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        _ = store.open()
        let timer = Timer(timeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        store.close()
        display.hide()
    }

    private func tick() {
        // 許可があとから出た場合に備えて、開けていなければ毎回試みる
        if !store.isOpen && !store.open() { return }
        let hidden = Set(settings.hiddenBundleIDs)
        for note in store.newArrivals() where note.bundleID.map { !hidden.contains($0) } ?? true {
            showLatest(note)
        }
    }

    /// 短時間に複数来たときは、いちばん新しいものだけ出す（試験中の作り）
    private var pending: IncomingNotification?
    private func showLatest(_ note: IncomingNotification) {
        pending = note
        DispatchQueue.main.async { [weak self] in
            guard let self, let note = self.pending else { return }
            self.pending = nil
            self.display.show(note, seconds: self.settings.showSeconds)
        }
    }

    func menuItems() -> AnyView { AnyView(NotificationMenuItems(module: self)) }
    func settingsView() -> AnyView { AnyView(NotificationSettingsView(module: self)) }

    func exportConfig() -> [(key: String, value: TOMLValue)] {
        [
            ("show_seconds", .double(settings.showSeconds)),
            ("hidden_apps", .array(settings.hiddenBundleIDs.map { .string($0) })),
        ]
    }

    func importConfig(_ table: TOMLTable) {
        if let v = table["show_seconds"]?.double, v > 0, v != settings.showSeconds { settings.showSeconds = v }
        if let v = table["hidden_apps"]?.stringArray, v != settings.hiddenBundleIDs { settings.hiddenBundleIDs = v }
    }
}

private struct NotificationMenuItems: View {
    let module: NotificationModule

    var body: some View {
        Toggle(isOn: Binding(get: { AppModel.shared.isEnabled(module) },
                             set: { AppModel.shared.setEnabled($0, for: module) })) {
            Label("通知をノッチ周りには表示", systemImage: "bell.badge")
        }
    }
}

struct NotificationSettingsView: View {
    let module: NotificationModule

    var body: some View {
        @Bindable var settings = module.settings
        Form {
            DiskAccessBanner(reason: "Notification Center に保存された通知を読むために使います。")

            Section {
                Picker("表示する時間", selection: $settings.showSeconds) {
                    ForEach(NotificationSettings.secondChoices, id: \.self) { Text("\($0.formatted()) 秒").tag($0) }
                }
            } footer: {
                Text("短時間に複数来たときは、いちばん新しいものだけ出します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent {
                    Button("集中モードの設定を開く…") { Self.openFocusSettings() }
                } label: {
                    Text("ノッチだけにするには")
                    Text("集中モード（通知オフ）にすると OS のバナーは消え、通知は Notification Center には残り続けるので、このノッチ表示だけが出ます。")
                }
            }

            Section {
                AppListEditor(title: "出さないアプリ", subtitle: "一般の「機密情報を扱うアプリ」に加えて、通知を出しません",
                              bundleIDs: $settings.hiddenBundleIDs)
            } footer: {
                Text("macOS が Notification Center に溜めたものを読む方式で、Apple に公開された仕組みではありません。OS のアップデートで読めなくなる可能性があります。元のバナーを消してノッチ周りだけにしたいときは、集中モード（通知オフ）を使うと、そちらに届いたぶんだけこの表示に出ます。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// 集中モードの設定ペイン（OS の世代で URL が違うため順に試す）
    private static func openFocusSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension?Focus",
            "x-apple.systempreferences:com.apple.preference.notifications?Focus",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }
}
