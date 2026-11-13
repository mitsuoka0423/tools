import SwiftUI
import Observation

/// 自動コピーの設定。UserDefaults に保存する。
@MainActor
@Observable
final class AutoCopySettings {
    enum WaitMode: String { case auto, manual }

    /// クリックの続きを待つ時間を、自動で決めるか、自分で決めるか
    var waitMode: WaitMode { didSet { defaults.set(waitMode.rawValue, forKey: Keys.waitMode) } }
    /// 自分で決めるときの待つ時間（ミリ秒）
    var manualWaitMs: Int { didSet { defaults.set(manualWaitMs, forKey: Keys.manualWaitMs) } }
    /// ⇧＋移動キー・⌘A で選んだ範囲もコピーするか
    var keyboardSelection: Bool { didSet { defaults.set(keyboardSelection, forKey: Keys.keyboardSelection) } }
    var showPopup: Bool { didSet { defaults.set(showPopup, forKey: Keys.showPopup) } }
    var popupSeconds: Double { didSet { defaults.set(popupSeconds, forKey: Keys.popupSeconds) } }
    /// 自動コピーした範囲を選んだまま ⌘V したら、その前にコピーしていた内容を貼り付ける
    var protectPaste: Bool { didSet { defaults.set(protectPaste, forKey: Keys.protectPaste) } }
    /// 自動コピーだけをしないアプリ（一般の「機密情報を扱うアプリ」に加えて）
    var excludedBundleIDs: [String] { didSet { defaults.set(excludedBundleIDs, forKey: Keys.excluded) } }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let waitMode = "autocopy.waitMode"
        static let manualWaitMs = "autocopy.manualWaitMs"
        static let keyboardSelection = "autocopy.keyboardSelection"
        static let showPopup = "autocopy.showPopup"
        static let popupSeconds = "autocopy.popupSeconds"
        static let protectPaste = "autocopy.protectPaste"
        static let excluded = "autocopy.excludedBundleIDs"
    }

    static let popupChoices: [Double] = [0.8, 1.2, 2.0, 3.0]

    init() {
        defaults.register(defaults: [
            Keys.waitMode: WaitMode.auto.rawValue,
            Keys.manualWaitMs: 300,
            Keys.keyboardSelection: false,
            Keys.showPopup: true,
            Keys.popupSeconds: 1.2,
            Keys.protectPaste: true,
        ])
        waitMode = WaitMode(rawValue: defaults.string(forKey: Keys.waitMode) ?? "") ?? .auto
        manualWaitMs = defaults.integer(forKey: Keys.manualWaitMs)
        keyboardSelection = defaults.bool(forKey: Keys.keyboardSelection)
        showPopup = defaults.bool(forKey: Keys.showPopup)
        popupSeconds = defaults.double(forKey: Keys.popupSeconds)
        protectPaste = defaults.bool(forKey: Keys.protectPaste)
        excludedBundleIDs = defaults.stringArray(forKey: Keys.excluded) ?? []
    }
}

/// 選択範囲の自動コピー。選び終えた範囲を、そのままクリップボードに入れる。
@MainActor
final class AutoCopyModule: ToolModule {
    let id = "autocopy"
    let title = "自動コピー"
    let systemImage = "text.cursor"
    let actions: [ShortcutAction] = []
    var needsAccessibility: Bool { true }
    var showsMenuItemsWhenDisabled: Bool { true }

    let settings = AutoCopySettings()
    let learner = ClickGapLearner()
    private lazy var engine = AutoCopyEngine(settings: settings, learner: learner)

    func start() { engine.start() }
    func stop() { engine.stop() }

    func menuItems() -> AnyView { AnyView(AutoCopyMenuItems(module: self)) }
    func settingsView() -> AnyView { AnyView(AutoCopySettingsView(module: self)) }

    func exportConfig() -> [(key: String, value: TOMLValue)] {
        [
            ("wait_mode", .string(settings.waitMode.rawValue)),
            ("wait_ms", .int(settings.manualWaitMs)),
            ("keyboard_selection", .bool(settings.keyboardSelection)),
            ("show_popup", .bool(settings.showPopup)),
            ("popup_seconds", .double(settings.popupSeconds)),
            ("protect_paste", .bool(settings.protectPaste)),
            ("excluded_apps", .array(settings.excludedBundleIDs.map { .string($0) })),
        ]
    }

    func importConfig(_ table: TOMLTable) {
        let s = settings
        if let v = table["wait_mode"]?.string.flatMap(AutoCopySettings.WaitMode.init(rawValue:)), v != s.waitMode { s.waitMode = v }
        if let v = table["wait_ms"]?.int, v > 0, v != s.manualWaitMs { s.manualWaitMs = v }
        if let v = table["keyboard_selection"]?.bool, v != s.keyboardSelection { s.keyboardSelection = v }
        if let v = table["show_popup"]?.bool, v != s.showPopup { s.showPopup = v }
        if let v = table["popup_seconds"]?.double, v > 0, v != s.popupSeconds { s.popupSeconds = v }
        if let v = table["protect_paste"]?.bool, v != s.protectPaste { s.protectPaste = v }
        if let v = table["excluded_apps"]?.stringArray, v != s.excludedBundleIDs { s.excludedBundleIDs = v }
    }
}

private struct AutoCopyMenuItems: View {
    let module: AutoCopyModule

    var body: some View {
        Toggle(isOn: Binding(get: { AppModel.shared.isEnabled(module) },
                             set: { AppModel.shared.setEnabled($0, for: module) })) {
            Label("選択を自動でコピー", systemImage: "text.cursor")
        }
    }
}

struct AutoCopySettingsView: View {
    let module: AutoCopyModule

    var body: some View {
        @Bindable var settings = module.settings
        let learner = module.learner
        let systemMax = ClickGapLearner.systemMaxMs
        Form {
            PermissionBanner(reason: "選んだ文字を読み取るのと、⌘V を見分けるのに使います。")

            Section {
                Picker("クリックの続きを待つ時間", selection: $settings.waitMode) {
                    Text("自動").tag(AutoCopySettings.WaitMode.auto)
                    Text("手動").tag(AutoCopySettings.WaitMode.manual)
                }
                .pickerStyle(.segmented)
                if settings.waitMode == .auto {
                    LabeledContent("いまの待つ時間") {
                        Text("\(learner.currentMs) ms").monospacedDigit()
                    }
                    if learner.learnedMs == nil {
                        // 測定中：何をすればよいかを示す
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("測定中").font(.body.weight(.medium))
                                Spacer()
                                Text("あと \(max(0, ClickGapLearner.minimumSamples - learner.samples.count)) 回")
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            ProgressView(value: Double(min(learner.samples.count, ClickGapLearner.minimumSamples)),
                                         total: Double(ClickGapLearner.minimumSamples))
                            Text("ほかのアプリで、ふだんどおりにダブルクリックやトリプルクリックをしてください。クリックの間隔を測り、待つ時間を決めます。決まるまでは \(systemMax) ms 待ちます。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        LabeledContent("測った間隔") {
                            Text(gapSummary(learner)).monospacedDigit()
                        }
                    }
                    LabeledContent {
                        Button("測り直す") { learner.reset() }
                            .disabled(learner.samples.isEmpty)
                    } label: {
                        Text("測り直す")
                        Text("今までの測定を捨てて、最初から測ります。")
                    }
                } else {
                    LabeledContent("待つ時間") {
                        HStack {
                            Slider(value: Binding(get: { Double(min(settings.manualWaitMs, systemMax)) },
                                                  set: { settings.manualWaitMs = Int(($0 / 10).rounded()) * 10 }),
                                   in: 100...Double(max(systemMax, 110)))
                                .frame(width: 180)
                            Text("\(min(settings.manualWaitMs, systemMax)) ms").monospacedDigit().frame(width: 60, alignment: .trailing)
                        }
                    }
                }
            } footer: {
                Text("ダブルクリックのあと、3 回目のクリックが来るかを待つ時間です。自動では、ふだんのクリックの速さから決め、使い続けるうちに少しずつ合わせます。測った値は保存しないので、アプリを起動し直すと測り直します。上限はシステム設定の「ダブルクリックの間隔」（\(systemMax) ms）です。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.keyboardSelection) {
                    Text("キーボードで選んだ範囲もコピーする")
                    Text("⇧＋矢印キーなど、⌘A で選んだ範囲もコピーします。")
                }
                Toggle(isOn: $settings.protectPaste) {
                    Text("選んだ範囲への貼り付けを守る")
                    Text("選んだまま ⌘V すると、自動コピーの前にコピーしていた内容で置き換えます。")
                }
            }

            Section {
                Toggle("「コピーしました」を表示", isOn: $settings.showPopup)
                if settings.showPopup {
                    Picker("表示する時間", selection: $settings.popupSeconds) {
                        ForEach(AutoCopySettings.popupChoices, id: \.self) { Text("\($0.formatted()) 秒").tag($0) }
                    }
                }
            }

            Section {
                AppListEditor(title: "自動コピーしないアプリ", subtitle: "一般の「機密情報を扱うアプリ」に加えて、自動コピーだけをしません",
                              bundleIDs: $settings.excludedBundleIDs)
            } footer: {
                Text("パスワードの欄で選んだ文字はコピーしません。自動コピーした内容は、ほかの Apple 製デバイスには送りません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func gapSummary(_ learner: ClickGapLearner) -> String {
        func median(_ a: [Double]) -> String {
            guard !a.isEmpty else { return "—" }
            return "\(Int(a.sorted()[a.count / 2].rounded())) ms"
        }
        return "1→2 回目 \(median(learner.firstGaps)) ・ 2→3 回目 \(median(learner.secondGaps))（中央値、\(learner.samples.count) 回）"
    }
}
