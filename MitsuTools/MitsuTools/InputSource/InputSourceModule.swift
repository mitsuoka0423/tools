import SwiftUI
import Observation
import UniformTypeIdentifiers
import ApplicationServices

/// 入力方式の自動切り替え。アプリを前面に出したとき、そのアプリに決めておいた入力方式へ切り替える。
/// 例: Spotlight を開いたら半角英字（ABC）にする。
@MainActor
@Observable
final class InputSourceModule: ToolModule {
    let id = "inputsource"
    let title = "入力方式"
    let systemImage = "keyboard"
    /// Spotlight のように、アプリとして前面に出ない画面を見つけるのに使う。
    let needsAccessibility = true

    /// アプリの Bundle ID → 切り替える入力方式の ID
    private(set) var rules: [String: String] {
        didSet { UserDefaults.standard.set(rules, forKey: Self.rulesKey) }
    }
    /// いま使える入力方式
    private(set) var sources: [InputSource] = []

    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pollTimer: Timer?
    /// 前面に出ないアプリ（Spotlight など）のうち、いまキー入力を受けているもの
    @ObservationIgnored private var lastOverlayBundleID: String?
    @ObservationIgnored private var missingTicks = 0
    /// 最後に前面に出た（入力方式のアプリを除く）アプリ
    @ObservationIgnored private var lastActivatedBundleID: String?
    private static let rulesKey = "inputsource.rules"

    /// 追加の候補に出す Spotlight。この Mac では、⌘Space の検索画面は「Siri AI」（com.apple.campo）として現れる。
    /// どちらも、見つかったものを両方追加する。
    static let spotlightBundleIDs = ["com.apple.campo", "com.apple.Spotlight"]
    private static let displayNames = ["com.apple.campo": "Spotlight（Siri AI）"]

    init() {
        rules = (UserDefaults.standard.dictionary(forKey: Self.rulesKey) as? [String: String]) ?? [:]
    }

    var actions: [ShortcutAction] { [] }

    func start() {
        refreshSources()
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let isInputMethod = Self.isInputMethod(app)
            MainActor.assumeIsolated { self?.appDidActivate(bundleID: bundleID, isInputMethod: isInputMethod) }
        }
        // Spotlight などは「アプリが前面に出た」通知が出ないので、キー入力を受けているアプリを見て見つける
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollOverlayApp() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        lastOverlayBundleID = nil
        lastActivatedBundleID = nil
    }

    // MARK: 前面に出ないアプリ（Spotlight など）の検出

    /// 通常のアプリは、アプリが前面に出た通知で切り替える。
    /// 前面に出ずにキー入力だけを受けるアプリ（Spotlight など）は、ここで見つけて切り替える。
    private func pollOverlayApp() {
        guard !rules.isEmpty, AXIsProcessTrusted() else {
            lastOverlayBundleID = nil
            return
        }
        guard let app = Self.keyInputApp(), let bundleID = app.bundleIdentifier, !Self.isInputMethod(app) else {
            // 画面が閉じる間などに、一瞬だけ値がなくなる。少し続いたら「いったん離れた」と見なす
            missingTicks += 1
            if missingTicks >= 2 { lastOverlayBundleID = nil }
            return
        }
        missingTicks = 0
        guard bundleID != lastOverlayBundleID else { return }
        lastOverlayBundleID = bundleID
        // 前面のアプリそのものなら、通知のほうで切り替え済み
        guard bundleID != NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        applyRule(for: bundleID)
    }

    /// いまキー入力を受けているアプリ（Accessibility で調べる）
    private static func keyInputApp() -> NSRunningApplication? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(value as! AXUIElement, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }

    /// 入力方式そのもののアプリ（azooKey など）か。
    /// 入力方式を切り替えたり変換したりするたびに前面に出入りするので、アプリの切り替えとは見なさない。
    private nonisolated static func isInputMethod(_ app: NSRunningApplication?) -> Bool {
        guard let url = app?.bundleURL else { return false }
        if url.path.contains("/Input Methods/") { return true }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "InputMethodConnectionName") != nil
    }

    func settingsView() -> AnyView { AnyView(InputSourceSettingsView(module: self)) }

    // MARK: 切り替え

    /// アプリが前面に出たとき。同じアプリのままなら（入力方式のアプリが出入りしただけなら）何もしない。
    private func appDidActivate(bundleID: String?, isInputMethod: Bool) {
        guard let bundleID, !isInputMethod, bundleID != lastActivatedBundleID else { return }
        lastActivatedBundleID = bundleID
        applyRule(for: bundleID)
    }

    private func applyRule(for bundleID: String) {
        guard let target = rules[bundleID] else { return }
        // アプリが前面に出た直後に、アプリ側の入力方式の復元と重なりやすいので、少しあとに切り替える
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if !InputSourceManager.select(id: target) {
                NSLog("MitsuTools: 入力方式 \(target) に切り替えられませんでした（\(bundleID)）")
            }
        }
    }

    // MARK: ルール

    func refreshSources() { sources = InputSourceManager.available() }

    func setSource(_ sourceID: String, for bundleID: String) { rules[bundleID] = sourceID }

    func remove(_ bundleID: String) { rules[bundleID] = nil }

    /// 新しく追加するアプリの、入力方式の初期値。半角英字（ABC）があればそれ、なければ先頭。
    private var defaultSourceID: String {
        sources.first { $0.id == "com.apple.keylayout.ABC" }?.id ?? sources.first?.id ?? ""
    }

    func add(bundleID: String) {
        guard rules[bundleID] == nil else { return }
        refreshSources()
        rules[bundleID] = defaultSourceID
    }

    /// ファイル選択の画面でアプリを選んで追加する。
    func addFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleID = Bundle(url: url)?.bundleIdentifier { add(bundleID: bundleID) }
        }
    }

    /// 追加の候補にする、起動中のアプリ（まだルールがないもの）
    var runningCandidates: [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      rules[id] == nil, let name = app.localizedName else { return nil }
                return (id, name)
            }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }

    // MARK: 設定ファイル

    /// 設定ファイルには「アプリの Bundle ID = 入力方式の ID」を並べる。
    func exportConfig() -> [(key: String, value: TOMLValue)] {
        rules.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }
    }

    func importConfig(_ table: TOMLTable) {
        let imported = table.compactMapValues(\.string)
        if imported != rules { rules = imported }
    }

    // MARK: 表示用

    static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func appName(_ bundleID: String) -> String {
        if let name = displayNames[bundleID] { return name }
        guard let url = appURL(bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

struct InputSourceSettingsView: View {
    let module: InputSourceModule

    private var bundleIDs: [String] {
        module.rules.keys.sorted {
            InputSourceModule.appName($0).localizedStandardCompare(InputSourceModule.appName($1)) == .orderedAscending
        }
    }

    var body: some View {
        Form {
            PermissionBanner(reason: "Spotlight のように前面に出ない画面を見つけるのに使います。")
            Section {
                if module.rules.isEmpty {
                    Text("アプリがありません。「アプリを追加」から登録してください。").foregroundStyle(.secondary)
                }
                ForEach(bundleIDs, id: \.self) { bundleID in
                    LabeledContent {
                        HStack(spacing: 8) {
                            sourcePicker(bundleID)
                            Button { module.remove(bundleID) } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("このアプリの設定を外す")
                        }
                    } label: {
                        HStack(spacing: 8) {
                            icon(bundleID)
                            Text(InputSourceModule.appName(bundleID))
                        }
                    }
                }
            } header: {
                HStack {
                    Text("アプリと入力方式")
                    Spacer()
                    addMenu
                }
            } footer: {
                Text("アプリを前面に出したときに、決めておいた入力方式へ切り替えます。システム設定の「キーボード」で「書類ごとに入力ソースを自動的に切り替える」がオンだと、期待どおりに切り替わらないことがあります。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .onAppear { module.refreshSources() }
    }

    private var addMenu: some View {
        Menu("アプリを追加") {
            if InputSourceModule.spotlightBundleIDs.contains(where: { module.rules[$0] == nil }) {
                Button("Spotlight（⌘Space の検索）") {
                    InputSourceModule.spotlightBundleIDs
                        .filter { InputSourceModule.appURL($0) != nil }
                        .forEach { module.add(bundleID: $0) }
                }
                Divider()
            }
            Section("起動中のアプリ") {
                ForEach(module.runningCandidates, id: \.bundleID) { candidate in
                    Button(candidate.name) { module.add(bundleID: candidate.bundleID) }
                }
            }
            Divider()
            Button("ほかのアプリを選ぶ…") { module.addFromPanel() }
        }
        .fixedSize()
    }

    private func sourcePicker(_ bundleID: String) -> some View {
        let current = module.rules[bundleID] ?? ""
        return Picker("入力方式", selection: Binding(
            get: { current },
            set: { module.setSource($0, for: bundleID) }
        )) {
            ForEach(module.sources) { Text($0.name).tag($0.id) }
            // 使えなくなった入力方式が決めてあるときも、そのまま見えるようにする
            if !module.sources.contains(where: { $0.id == current }) {
                Text("（使えません）\(current)").tag(current)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    @ViewBuilder
    private func icon(_ bundleID: String) -> some View {
        if let url = InputSourceModule.appURL(bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "questionmark.app.dashed").frame(width: 20, height: 20)
        }
    }
}
