import SwiftUI
import Observation

/// Hosts モジュールの設定。選択中のプロファイル名などは設定ファイル（config.toml）に書かれる。
@MainActor
@Observable
final class HostsSettings {
    /// 選択中のプロファイル名
    var selectedProfileName: String = "" { didSet { ConfigFile.shared.scheduleSave() } }
    /// 切り替えるときに DNS のキャッシュを消すか
    var flushDNS: Bool = true { didSet { ConfigFile.shared.scheduleSave() } }
    /// 今 /etc/hosts に入っているプロファイル名（読むだけ）
    var appliedProfileName: String?
    /// 管理区間があるか（読むだけ）
    var hasManagedBlock: Bool = false
}

/// /etc/hosts のプロファイルを切り替える。
///
/// プロファイルは「名前＋行の並び」で、JSON ファイル（~/.config/mitsutools/hosts.json）に保存する。
/// 適用すると /etc/hosts の管理区間（マーカーで挟んだ部分）だけが入れ替わり、
/// システムの既定の行はそのまま残す。書き換えには管理者権限（OS 標準のパスワードダイアログ）が必要。
@MainActor
final class HostsModule: ToolModule {
    let id = "hosts"
    let title = "Hosts"
    let systemImage = "network"
    let actions: [ShortcutAction] = []
    var showsMenuItemsWhenDisabled: Bool { true }

    let store = HostsStore.shared
    let settings = HostsSettings()

    func start() {
        store.load()
        refreshState()
    }

    func stop() {}

    /// /etc/hosts を読んだ直後の状態を反映する
    func refreshState() {
        let state = HostsFile.read().state
        settings.appliedProfileName = state.appliedProfileName
        settings.hasManagedBlock = state.hasManagedBlock
    }

    // MARK: 適用

    /// プロファイルを適用する。nil なら管理区間を削除する（解除）。
    func apply(_ profile: HostsProfile?) {
        NSApp.activate()
        let content: String
        if let profile {
            content = HostsFile.content(applying: profile)
        } else {
            content = HostsFile.contentWithoutManagedBlock()
        }
        do {
            try HostsFile.write(content: content, flushDNS: settings.flushDNS)
            settings.selectedProfileName = profile?.name ?? ""
            ConfigFile.shared.scheduleSave()
            refreshState()
        } catch {
            report(error)
        }
    }

    /// 直前の内容（バックアップ）から戻す
    func restoreBackup() {
        NSApp.activate()
        do {
            try HostsFile.restoreBackup()
            refreshState()
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "hosts を書き換えられませんでした"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "了解")
        alert.runModal()
    }

    // MARK: ToolModule

    func menuItems() -> AnyView { AnyView(HostsMenuItems(module: self)) }
    func settingsView() -> AnyView { AnyView(HostsSettingsView(module: self)) }

    func exportConfig() -> [(key: String, value: TOMLValue)] {
        [
            ("selected", .string(settings.selectedProfileName)),
            ("flush_dns", .bool(settings.flushDNS)),
        ]
    }

    func importConfig(_ table: TOMLTable) {
        if let v = table["selected"]?.string, v != settings.selectedProfileName { settings.selectedProfileName = v }
        if let v = table["flush_dns"]?.bool, v != settings.flushDNS { settings.flushDNS = v }
    }
}

// MARK: メニュー

private struct HostsMenuItems: View {
    let module: HostsModule

    var body: some View {
        if module.store.profiles.isEmpty {
            Text("プロファイルがありません").foregroundStyle(.secondary)
        } else {
            ForEach(module.store.profiles) { profile in
                Button {
                    module.apply(profile)
                } label: {
                    Label(profile.displayName,
                          systemImage: module.settings.appliedProfileName == profile.name ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Divider()
        Button("管理区間を解除") { module.apply(nil) }
            .disabled(!module.settings.hasManagedBlock)
    }
}

// MARK: 設定画面

struct HostsSettingsView: View {
    let module: HostsModule
    @State private var selectedID: HostsProfile.ID?
    @State private var entriesText: String = ""
    @State private var note: String?
    @State private var saveWork: DispatchWorkItem?

    private var selectedProfile: HostsProfile? {
        module.store.profiles.first { $0.id == selectedID }
    }

    var body: some View {
        Form {
            Section("プロファイル") {
                if module.store.profiles.isEmpty {
                    Text("まだプロファイルがありません").foregroundStyle(.secondary)
                }
                ForEach(module.store.profiles) { profile in
                    HStack {
                        Button {
                            select(profile)
                        } label: {
                            HStack {
                                Image(systemName: selectedID == profile.id ? "largecircle.fill.circle" : "circle")
                                Text(profile.displayName)
                                Text("\(profile.entries.count) 行").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if module.settings.appliedProfileName == profile.name {
                            Text("適用中").font(.caption).foregroundStyle(.green)
                        }
                        Button {
                            rename(profile)
                        } label: {
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("名前を変える")
                        Button {
                            module.store.remove(profile)
                            if selectedID == profile.id { selectedID = nil }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("消す")
                    }
                }
                HStack {
                    Button("追加…") { addProfile() }
                    Spacer()
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if let profile = selectedProfile {
                    TextEditor(text: $entriesText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 110)
                        .onChange(of: entriesText) { _, _ in scheduleSave() }
                    Text("1 行につき 1 つ（例: 127.0.0.1 dev.local）。空行とコメント行（# で始まる）は無視されます。")
                        .font(.caption).foregroundStyle(.secondary)                } else {
                    Text("プロファイルを選ぶと、ここで行を編集できます").foregroundStyle(.secondary)
                }
            } header: {
                Text("内容")
            }

            Section {
                LabeledContent {
                    Text(module.settings.appliedProfileName ?? "なし").foregroundStyle(.secondary)
                } label: {
                    Text("今適用されているもの")
                }
                Toggle("切り替えるときに DNS のキャッシュを消す", isOn: Binding(
                    get: { module.settings.flushDNS },
                    set: { module.settings.flushDNS = $0 }
                ))
                HStack {
                    Button("このプロファイルを適用") { applySelected() }
                        .disabled(selectedProfile == nil)
                    Button("解除") { module.apply(nil) }
                        .disabled(!module.settings.hasManagedBlock)
                    Spacer()
                    Button("直前に戻す") { module.restoreBackup() }
                }
            } header: {
                Text("適用")
            } footer: {
                Text("""
                適用すると /etc/hosts の「# >>> mitsutools >>>」と「# <<< mitsutools <<<」で挟んだ区間だけが入れ替わります。システムの既定の行は残ります。直前の内容は \(HostsFile.backupPath) に残ります。
                書き換えには管理者のパスワードが要ります（OS 標準のダイアログ）。プロファイルは \(module.store.url.path) に保存しています。
                """)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            module.store.load()
            module.refreshState()
            if selectedID == nil { selectedID = module.store.profiles.first?.id }
            if let profile = selectedProfile { entriesText = profile.entries.joined(separator: "\n") }
        }
    }

    // MARK: 操作

    private func select(_ profile: HostsProfile) {
        selectedID = profile.id
        entriesText = profile.entries.joined(separator: "\n")
    }

    private func save(_ profile: HostsProfile) {
        var updated = profile
        updated.entries = entriesText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        module.store.update(updated)
    }

    /// 入力のたびに書き込まない。少し待ってからまとめて保存する。
    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { self.commitEntries() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func commitEntries() {
        guard let profile = selectedProfile else { return }
        save(profile)
    }

    private func addProfile() {
        let alert = NSAlert()
        alert.messageText = "プロファイルを追加"
        alert.informativeText = "名前を入力してください（あとで変更できます）"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "例: 開発"
        alert.accessoryView = field
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        let profile = module.store.add(name: name)
        select(profile)
    }

    private func rename(_ profile: HostsProfile) {
        let alert = NSAlert()
        alert.messageText = "名前を変える"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = profile.name
        alert.accessoryView = field
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var updated = profile
        updated.name = field.stringValue.trimmingCharacters(in: .whitespaces)
        module.store.update(updated)
        note = "\(updated.displayName) に名前を変えました。適用し直すと /etc/hosts の表示も追従します。"
    }

    private func applySelected() {
        guard let profile = selectedProfile else { return }
        module.apply(profile)
    }
}
