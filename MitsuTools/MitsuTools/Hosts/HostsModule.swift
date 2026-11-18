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
    /// 特権ヘルパーの状況（読むだけ）
    var helperState: HostsHelper.State = .notInstalled
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
        settings.helperState = HostsHelper.state()
    }

    // MARK: 適用

    /// プロファイルを適用する。nil なら管理区間を削除する（解除）。
    /// ヘルパーが入っていればそれ経由（パスワード不要）、いなければ osascript（パスワード）で書く。
    func apply(_ profile: HostsProfile?) {
        NSApp.activate()
        let content: String
        if let profile {
            content = HostsFile.content(applying: profile)
        } else {
            content = HostsFile.contentWithoutManagedBlock()
        }
        if HostsHelper.state() == .active {
            Task { @MainActor in
                do {
                    try await HostsHelper.write(content: content, flushDNS: settings.flushDNS)
                    adopted(profile)
                } catch {
                    // ヘルパーがうまく動かないときは、パスワード方式に戻す
                    writeWithPassword(content, profile)
                }
            }
        } else {
            writeWithPassword(content, profile)
        }
    }

    private func writeWithPassword(_ content: String, _ profile: HostsProfile?) {
        do {
            try HostsFile.write(content: content, flushDNS: settings.flushDNS)
            adopted(profile)
        } catch {
            report(error)
        }
    }

    private func adopted(_ profile: HostsProfile?) {
        settings.selectedProfileName = profile?.name ?? ""
        ConfigFile.shared.scheduleSave()
        refreshState()
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
    /// 編集中かどうか。既定は読み取り専用（手で当てて誤って変えないように）
    @State private var isEditing = false
    @State private var note: String?

    private var selectedProfile: HostsProfile? {
        module.store.profiles.first { $0.id == selectedID }
    }

    var body: some View {
        Form {
            Section {
                if module.store.profiles.isEmpty {
                    Text("まだプロファイルがありません").foregroundStyle(.secondary)
                }
                ForEach(module.store.profiles) { profile in
                    HStack(spacing: 10) {
                        Toggle("", isOn: appliedSwitch(for: profile))
                            .labelsHidden()
                            .help("オンにすると、このプロファイルを適用します（管理者のパスワードが要ります）")
                        Button {
                            select(profile)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
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
            } header: {
                Text("プロファイル")
            } footer: {
                Text("スイッチをオンにすると、そのプロファイルが /etc/hosts に入ります（管理者のパスワードが要ります）。オフにすると、管理していた区間だけが取り除かれます。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if let profile = selectedProfile {
                    if isEditing {
                        TextEditor(text: $entriesText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 110)
                        HStack {
                            Button("完了") { finishEditing(profile) }
                            Button("やめる") { cancelEditing() }
                            Spacer()
                        }
                    } else {
                        Text(profile.entries.isEmpty ? "（空です）" : profile.entries.joined(separator: "\n"))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 110, alignment: .top)
                        HStack {
                            Button("編集") { startEditing(profile) }
                            Spacer()
                        }
                    }
                    Text("1 行につき 1 つ（例: 127.0.0.1 dev.local）。空行とコメント行（# で始まる）は無視されます。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("プロファイルを選ぶと、中身が表示されます").foregroundStyle(.secondary)
                }
            } header: {
                Text("中身")
            }

            Section {
                LabeledContent {
                    switch module.settings.helperState {
                    case .active:
                        Label("入っています", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .requiresApproval:
                        Button("システム設定を開く") { HostsHelper.openLoginItemsSettings() }
                    case .notInstalled:
                        Button("ヘルパーを入れる…") { installHelper() }
                    }
                } label: {
                    Text("ヘルパー（パスワード不要で切り替える）")
                    Text("入れて許可すると、切り替えのたびに管理者のパスワードを聞かれなくなります。")
                }
                if module.settings.helperState == .requiresApproval {
                    Text("システム設定 › 一般 › 「ログイン項目と拡張機能」で MitsuTools をオンにすると効きます。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                Toggle("切り替えるときに DNS のキャッシュを消す", isOn: Binding(
                    get: { module.settings.flushDNS },
                    set: { module.settings.flushDNS = $0 }
                ))
                HStack {
                    Button("直前に戻す") { module.restoreBackup() }
                    Spacer()
                }
            } header: {
                Text("オプション")
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
        }
    }

    // MARK: 操作

    /// スイッチ：オンなら適用、オフなら解除。別のプロファイルが有効になると、自動的にこのスイッチはオフになる
    private func appliedSwitch(for profile: HostsProfile) -> Binding<Bool> {
        Binding(
            get: { module.settings.appliedProfileName == profile.name },
            set: { isOn in
                if isOn {
                    module.apply(profile)
                } else if module.settings.appliedProfileName == profile.name {
                    module.apply(nil)
                }
            }
        )
    }

    private func select(_ profile: HostsProfile) {
        selectedID = profile.id
        isEditing = false
        entriesText = profile.entries.joined(separator: "\n")
    }

    private func startEditing(_ profile: HostsProfile) {
        entriesText = profile.entries.joined(separator: "\n")
        isEditing = true
    }

    /// 編集を確定する。空行とコメント行は落とす
    private func finishEditing(_ profile: HostsProfile) {
        var updated = profile
        updated.entries = entriesText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        module.store.update(updated)
        isEditing = false
        entriesText = updated.entries.joined(separator: "\n")
        note = "\(updated.displayName) の中身を保存しました。適用し直すと /etc/hosts にも反映されます。"
    }

    /// 編集をやめて、元のままに戻す
    private func cancelEditing() {
        if let profile = selectedProfile { entriesText = profile.entries.joined(separator: "\n") }
        isEditing = false
    }

    private func installHelper() {
        _ = HostsHelper.install()
        module.refreshState()
        note = "ヘルパーを登録しました。システム設定で許可すると、次回からパスワードなしで切り替わります。"
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
}
