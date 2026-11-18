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
    /// 今 /etc/hosts の管理区間に入っているプロファイル名（読むだけ）
    var appliedProfileName: String?
    /// 今 /etc/hosts の管理区間に入っている行（読むだけ）
    var appliedEntries: [String] = []
    /// 管理区間があるか（読むだけ）
    var hasManagedBlock: Bool = false
}

/// /etc/hosts のプロファイルを切り替える。
///
/// 画面の説明は docs/hosts-ui-proposal.html の案Aどおり：
/// - 状態を先頭に出す（「適用中：〇〇」／未適用）。真実は /etc/hosts にある
/// - プロファイルを選ぶ（行タップ）だけでは hosts は変わらない。編集は hosts.json に自動保存されるだけ
/// - hosts を書き換える操作（適用・適用をやめる・直前の内容に戻す）は、
///   いつも「変わる行の確認 → 管理者パスワード」の順に進む（確認なしの暴発を作らない）
/// - パスワードの取り消しは「何もなかったこと」にし、失敗だけ警告する
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

    /// /etc/hosts を読んで、今の適用状態を反映する
    func refreshState() {
        let state = HostsFile.read().state
        settings.appliedProfileName = state.appliedProfileName
        settings.appliedEntries = state.appliedEntries
        settings.hasManagedBlock = state.hasManagedBlock
    }

    /// そのプロファイルが hosts に効いているか
    func isApplied(_ profile: HostsProfile) -> Bool {
        settings.appliedProfileName == profile.name
    }

    /// 適用中だけど、プロファイルの方が編集で変わってしまっているか（＝未反映）
    func isStale(_ profile: HostsProfile) -> Bool {
        isApplied(profile) && profile.contentLines != settings.appliedEntries
    }

    // MARK: 適用（確認 → パスワードの順）

    /// プロファイル適用の確認を出す。nil なら「適用をやめる」の確認。
    func confirmAndApply(_ profile: HostsProfile?) {
        NSApp.activate()
        let change = HostsFile.changes(current: settings.appliedEntries, target: profile?.contentLines ?? [])
        let alert = NSAlert()
        if let profile {
            alert.messageText = "「\(profile.displayName)」を /etc/hosts に適用しますか？"
        } else {
            alert.messageText = "適用をやめますか？"
        }
        alert.informativeText = HostsFile.changesText(change)
            + "\n\nこのあと macOS に管理者のパスワードを聞かれます。localhost など MitsuTools が管理していない行はそのまま残ります。"
        alert.addButton(withTitle: profile == nil ? "やめる" : "適用")
        alert.addButton(withTitle: "取り消し")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apply(profile)
    }

    /// 「直前の内容に戻す」の確認（ hosts を直接触った人向けのリカバリ）
    func confirmRestoreBackup() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "直前の内容に戻しますか？"
        alert.informativeText = """
        最後に hosts を書き換える直前の内容を、\(HostsFile.backupPath) から戻します。
        いま hosts に入っている行は失われます。

        このあと macOS に管理者のパスワードを聞かれます。
        """
        alert.addButton(withTitle: "戻す")
        alert.addButton(withTitle: "取り消し")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try HostsFile.restoreBackup()
        } catch {
            reportUnlessCancelled(error)
        }
        refreshState()
    }

    /// 実際に hosts を書く（確認済みのあとにしか呼ばない）
    private func apply(_ profile: HostsProfile?) {
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
        } catch {
            reportUnlessCancelled(error)
        }
        refreshState()
    }

    /// パスワードの取り消しはエラーとして怒らない（何もなかったことにする）
    private func reportUnlessCancelled(_ error: Error) {
        let message = error.localizedDescription
        if message.contains("-128") || message.localizedCaseInsensitiveContains("cancel") || message.contains("キャンセル") {
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "hosts を書き換えられませんでした"
        alert.informativeText = message
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
                    module.confirmAndApply(profile)
                } label: {
                    Label(profile.displayName, systemImage: module.isApplied(profile) ? "checkmark.circle.fill" : "circle")
                }
            }
        }
        Divider()
        Button("適用をやめる") { module.confirmAndApply(nil) }
            .disabled(!module.settings.hasManagedBlock)
        Divider()
        Button("Hosts の設定…") { SettingsWindowController.shared.show(pane: "hosts") }
    }
}

// MARK: 設定画面（案A：状態カード＋プレビュー適用）

struct HostsSettingsView: View {
    let module: HostsModule
    @State private var selectedID: HostsProfile.ID?
    @State private var note: String?

    private var selectedProfile: HostsProfile? {
        module.store.profiles.first { $0.id == selectedID }
    }

    var body: some View {
        Form {
            // 1. 状態を先頭に（真実は /etc/hosts にある）
            Section {
                LabeledContent {
                    Button("適用をやめる") { module.confirmAndApply(nil) }
                        .disabled(!module.settings.hasManagedBlock)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: module.settings.hasManagedBlock ? "circle.fill" : "circle")
                            .foregroundStyle(module.settings.hasManagedBlock ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(module.settings.appliedProfileName.map { "適用中：「\($0)」" } ?? "未適用（hosts は空です）")
                                .fontWeight(.semibold)
                            Text(module.settings.hasManagedBlock
                                 ? "hosts に行が \(module.settings.appliedEntries.count) 行入っています"
                                 : "MitsuTools の行は /etc/hosts に入っていません")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("「適用」を押すまで、/etc/hosts は変わりません。変更の確認画面で「変わる行」を先に見せます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 2. プロファイル一覧（タップ＝選ぶだけ）
            Section {
                if module.store.profiles.isEmpty {
                    Text("まだプロファイルがありません").foregroundStyle(.secondary)
                }
                ForEach(module.store.profiles) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: profile.id == selectedID ? "checkmark" : "")
                            .frame(width: 14).foregroundStyle(.tint)
                        Button {
                            select(profile)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.displayName)
                                Text(subtext(for: profile)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        statusPill(for: profile)
                        Button {
                            rename(profile)
                        } label: {
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("名前を変える")
                        Button {
                            module.store.remove(profile)
                            if selectedID == profile.id { selectedID = module.store.profiles.first?.id }
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("消す")
                    }
                }
                HStack {
                    Button("＋ プロファイルを追加…") { addProfile() }
                    Spacer()
                }
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("プロファイル")
            } footer: {
                Text("行をタップすると、そのプロファイルが下の欄に開かれます（hosts はまだ変わりません）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 3. 選んだプロファイルの中身（編集は hosts.json に自動保存され、hosts には効かない）
            Section {
                if let profile = selectedProfile {
                    if profile.contentLines.isEmpty {
                        Text("まだ行がありません。「＋ 行を追加」から足してください").foregroundStyle(.secondary)
                    }
                    ForEach(Array(profile.contentLines.enumerated()), id: \.offset) { index, line in
                        HStack(spacing: 8) {
                            TextField("127.0.0.1 dev.local", text: lineBinding(profile: profile, index: index))
                                .font(.system(size: 12, design: .monospaced))
                            Button {
                                removeLine(profile: profile, index: index)
                            } label: {
                                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("この行を消す")
                        }
                    }
                    HStack {
                        Button("＋ 行を追加") { addLine(profile: profile) }
                        Spacer()
                        Button("この中身を適用") { module.confirmAndApply(profile) }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    Text("上の一覧からプロファイルを選ぶと、ここに行を編集できます").foregroundStyle(.secondary)
                }
            } header: {
                Text("選んだプロファイル\(selectedProfile.map { "：「\($0.displayName)」" } ?? "")")
            } footer: {
                Text("編集はすぐにファイルへ保存されますが、/etc/hosts には効きません。「この中身を適用」を押すと、変わる行を確認してから書き換えます。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 4. オプション
            Section {
                Toggle("切り替えるときに DNS のキャッシュを消す", isOn: Binding(
                    get: { module.settings.flushDNS },
                    set: { module.settings.flushDNS = $0 }
                ))
                LabeledContent {
                    Button("直前の内容に戻す…") { module.confirmRestoreBackup() }
                } label: {
                    Text("hosts のバックアップ")
                    Text("最後に書き換える直前の内容是 \(HostsFile.backupPath) に残っています")
                }
            } header: {
                Text("オプション")
            } footer: {
                Text("プロファイルは \(module.store.url.path) に保存しています。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            module.store.load()
            module.refreshState()
            if selectedID == nil {
                // 適用中のプロファイルがあればそれを、無ければ先頭を選ぶ
                selectedID = (module.store.profiles.first { module.isApplied($0) } ?? module.store.profiles.first)?.id
            }
        }
    }

        // MARK: 行の表示ヘルパー

        private func subtext(for profile: HostsProfile) -> String {
            var text = "\(profile.contentLines.count) 行"
            if module.isStale(profile) { text += " ・ hosts へ適用待ち（編集済み）" }
            return text
        }

        @ViewBuilder
        private func statusPill(for profile: HostsProfile) -> some View {
            if module.isApplied(profile) {
                if module.isStale(profile) {
                    Text("● 未反映").font(.caption).foregroundStyle(.orange)
                        .help("編集した内容が hosts にまだ入っていません")
                } else {
                    Text("適用中").font(.caption).foregroundStyle(.green)
                }
            }
        }

        // MARK: 行の編集（自動保存）

        private func lineBinding(profile: HostsProfile, index: Int) -> Binding<String> {
            Binding(
                get: { profile.contentLines.indices.contains(index) ? profile.contentLines[index] : "" },
                set: { newValue in
                    guard let current = module.store.profiles.first(where: { $0.id == profile.id }) else { return }
                    var lines = current.contentLines
                    guard lines.indices.contains(index) else { return }
                    lines[index] = newValue
                    var updated = current
                    updated.entries = lines
                    module.store.update(updated)
                }
            )
        }

        private func addLine(profile: HostsProfile) {
            guard let current = module.store.profiles.first(where: { $0.id == profile.id }) else { return }
            var updated = current
            updated.entries = updated.contentLines + ["127.0.0.1 "]
            module.store.update(updated)
        }

        private func removeLine(profile: HostsProfile, index: Int) {
            guard let current = module.store.profiles.first(where: { $0.id == profile.id }) else { return }
            var lines = current.contentLines
            guard lines.indices.contains(index) else { return }
            lines.remove(at: index)
            var updated = current
            updated.entries = lines
            module.store.update(updated)
        }

        // MARK: プロファイル操作

        private func select(_ profile: HostsProfile) {
            selectedID = profile.id
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
            let profile = module.store.add(name: field.stringValue.trimmingCharacters(in: .whitespaces))
            selectedID = profile.id
            note = "プロファイル「\(profile.displayName)」を作りました。行を足して「この中身を適用」を押すと hosts に入ります。"
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
        }
}
