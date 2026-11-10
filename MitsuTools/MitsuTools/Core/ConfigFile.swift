import AppKit
import Observation

/// 設定をテキストファイル（TOML）に書き出し・読み込みする。dotfiles で管理できるようにするため。
///
/// - 場所は XDG Base Directory に従い `$XDG_CONFIG_HOME/mitsutools/config.toml`
///   （未設定なら `~/.config/mitsutools/config.toml`）。
/// - アプリで設定を変えると、ファイルを書き換える。
/// - ファイルを編集して保存すると、すぐアプリに反映する（シンボリックリンクでも可）。
/// - 起動時にファイルがなければ、今の設定で作る。
@MainActor
@Observable
final class ConfigFile {
    static let shared = ConfigFile()

    let url: URL
    /// 読み込みに失敗したときの理由。
    private(set) var lastError: String?

    /// 最後に書いた・読んだ内容から作った文字列。同じなら書き直さない。
    @ObservationIgnored private var lastGenerated: String?
    @ObservationIgnored private var lastReadText: String?
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watchedPath: String?

    private init() {
        url = Self.configDirectory.appending(path: "mitsutools/config.toml")
    }

    static var configDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            return URL(filePath: xdg, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
    }

    /// `~` で短くした表示用のパス。
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

    // MARK: 開始

    func start() {
        if FileManager.default.fileExists(atPath: url.path) {
            load()
        } else {
            save()
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ConfigFile.shared.scheduleSave() }
        }
        watch()
    }

    // MARK: 書き出し

    func scheduleSave() {
        guard !isApplying else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { ConfigFile.shared.save() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func save() {
        let text = generate()
        guard text != lastGenerated else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // シンボリックリンク（dotfiles）ならリンク先に書く。
            let target = url.resolvingSymlinksInPath()
            try text.write(to: target, atomically: true, encoding: .utf8)
            lastGenerated = text
            lastReadText = text
            watch()
        } catch {
            NSLog("MitsuTools: 設定ファイルを書き出せませんでした: \(error)")
        }
    }

    func generate() -> String {
        let model = AppModel.shared
        var out = """
        # MitsuTools の設定ファイル
        # - アプリの設定画面で変更すると、このファイルも書き換わります（コメントは残りません）。
        # - このファイルを編集して保存すると、すぐアプリに反映されます。
        # - ショートカットは "ctrl+opt+shift+cmd+キー" の形で書きます（例: "ctrl+opt+left"）。"" で割り当てなし。

        """

        func table(_ name: String, _ entries: [(key: String, value: TOMLValue)]) {
            guard !entries.isEmpty else { return }
            out += "\n[\(TOML.key(name))]\n"
            for entry in entries { out += "\(TOML.key(entry.key)) = \(TOML.value(entry.value))\n" }
        }

        table("general", [
            ("show_menu_bar_icon", .bool(model.showsMenuBarIcon)),
            ("launch_at_login", .bool(model.launchesAtLogin)),
        ])
        table("modules", model.modules.map { ($0.id, .bool(model.isEnabled($0))) })
        for module in model.modules { table(module.id, module.exportConfig()) }
        table("update", [
            ("automatically_check", .bool(Updater.shared.automaticallyChecks)),
            ("automatically_download", .bool(Updater.shared.automaticallyDownloads)),
        ])
        table("shortcuts", model.modules.flatMap(\.actions).map { action in
            (action.id, .string(HotKeyCenter.shared.storedShortcut(for: action)?.configString ?? ""))
        })
        return out
    }

    // MARK: 読み込み

    func load() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        guard text != lastReadText else { return }
        lastReadText = text
        do {
            let tables = try TOML.parse(text)
            apply(tables)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            NSLog("MitsuTools: 設定ファイルを読み込めませんでした: \(error.localizedDescription)")
            return
        }
        // ファイルの書き方（コメントなど）は残し、内容が同じなら書き直さない。
        lastGenerated = generate()
    }

    private func apply(_ tables: [String: TOMLTable]) {
        isApplying = true
        defer { isApplying = false }
        let model = AppModel.shared

        if let general = tables["general"] {
            if let v = general["show_menu_bar_icon"]?.bool, v != model.showsMenuBarIcon { model.showsMenuBarIcon = v }
            if let v = general["launch_at_login"]?.bool, v != model.launchesAtLogin { model.launchesAtLogin = v }
        }
        if let modules = tables["modules"] {
            for module in model.modules {
                if let v = modules[module.id]?.bool, v != model.isEnabled(module) { model.setEnabled(v, for: module) }
            }
        }
        for module in model.modules {
            if let table = tables[module.id] { module.importConfig(table) }
        }
        if let update = tables["update"] {
            if let v = update["automatically_check"]?.bool, v != Updater.shared.automaticallyChecks {
                Updater.shared.automaticallyChecks = v
            }
            if let v = update["automatically_download"]?.bool, v != Updater.shared.automaticallyDownloads {
                Updater.shared.automaticallyDownloads = v
            }
        }
        if let shortcuts = tables["shortcuts"] {
            for action in model.modules.flatMap(\.actions) {
                guard let text = shortcuts[action.id]?.string else { continue }
                if text.isEmpty {
                    HotKeyCenter.shared.importShortcut(nil, for: action)
                } else if let shortcut = Shortcut(configString: text) {
                    HotKeyCenter.shared.importShortcut(shortcut, for: action)
                } else {
                    NSLog("MitsuTools: ショートカット \"\(text)\"（\(action.id)）が読めないため無視しました")
                }
            }
        }
    }

    // MARK: 監視

    /// 保存のしかたはエディタによって違う。
    /// - その場で上書き → ファイル自体を監視
    /// - 別ファイルに書いて置き換え → フォルダを監視し、ファイルの監視を張り直す
    private func watch() {
        let file = url.resolvingSymlinksInPath().path
        let directory = (file as NSString).deletingLastPathComponent
        if watchedPath != directory {
            watcher?.cancel()
            watcher = makeSource(path: directory, mask: [.write, .rename, .delete])
            watchedPath = directory
        }
        fileWatcher?.cancel()
        fileWatcher = makeSource(path: file, mask: [.write, .extend, .rename, .delete])
    }

    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?

    private func makeSource(path: String, mask: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                // 書き込みが終わるのを少し待ってから読む。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    MainActor.assumeIsolated {
                        ConfigFile.shared.load()
                        ConfigFile.shared.watch()
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
