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

/// /etc/hosts のプロファイルを切り替える（ラジオ式）。
///
/// 画面の設計は docs/hosts-ui-proposal.html の案v2どおり：
/// - 行の先頭のラジオが「今 hosts に効いているもの」（=/etc/hosts の真実）。常に1つだけ
///   （「なし」も1つの選択肢として並べ、実態の n+1 状態をそのまま見せる）
/// - 行をタップすると「変わる行」の確認画面が出る。承認して初めて管理者パスワード→hosts 書き込み。
///   取り消しなら radio も hosts も動くだけは何も起きない
/// - プロファイルの行数も中身も設定画面には出さない。中身は行の「見る」ボタンで
///   ほかのアプリに開く（編集も hosts.json を直接開いてもらう）
/// - メニューバーは選ばれているものの表示だけ（操作は設定画面で行う）
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

    /// 適用中だけど、プロファイルの方が編集で変わってしまっているか（＝適用待ち）
    func isStale(_ profile: HostsProfile) -> Bool {
        isApplied(profile) && profile.contentLines != settings.appliedEntries
    }

    // MARK: 適用（確認 → パスワードの順）

    /// プロファイル適用の確認を出す。nil なら「なし」への切り替え（適用をやめる）の確認。
    func confirmAndApply(_ profile: HostsProfile?) {
        NSApp.activate()
        let target = profile?.contentLines ?? []
        let change = HostsFile.changes(current: settings.appliedEntries, target: target)

        // 同じ内容がすでに適用されている（＝変わることがない）ときパスワードを聞かない
        if change.isEmpty && (profile == nil && !settings.hasManagedBlock || profile.map { isApplied($0) } == true) {
            let info = NSAlert()
            info.messageText = profile == nil ? "もう適用されていません" : "この内容はすでに適用されています"
            info.informativeText = "hosts は変わりません（何も起きません）。"
            info.addButton(withTitle: "了解")
            info.runModal()
            return
        }

        let alert = NSAlert()
        if let profile {
            alert.messageText = "「\(profile.displayName)」を /etc/hosts に適用しますか？"
        } else {
            alert.messageText = "「なし」に切り替えますか？"
        }
        alert.informativeText = HostsFile.changesText(change)
            + "\n\nこのあと macOS に管理者のパスワードを聞かれます。"
            + (profile == nil ? "MitsuTools の行だけが hosts から無くなります。"
                              : "localhost など MitsuTools の行でないものはそのまま残ります。")
        alert.addButton(withTitle: profile == nil ? "切り替える" : "適用")
        alert.addButton(withTitle: "取り消し")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apply(profile)
    }

    /// 「直前の内容に戻す」の確認。中身は画面に出さない（ファイルの場所だけ示す）
    func confirmRestoreBackup() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "直前の内容に戻しますか？"
        alert.informativeText = """
        最後に hosts を書き換える直前の内容を、\(HostsFile.backupPath) から戻します。
        いま hosts に入っている MitsuTools の行は失われます。

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

    /// 実際に hosts を書く（確認のあとにしか呼ばない）
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

    // MARK: 中身をほかのアプリに開く

    /// そのプロファイルの行を一時テキストにして、既定のアプリで開く（表示の委譲）
    func openContents(_ profile: HostsProfile) {
        let safeName = profile.displayName.replacingOccurrences(of: "/", with: "_")
        let url = FileManager.default.temporaryDirectory.appending(path: "mitsutools-hosts-\(safeName).txt")
        let text = profile.contentLines.isEmpty ? "（このプロファイルには行がありません）" : profile.contentLines.joined(separator: "\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(url)
    }

    /// プロファイル本体（hosts.json）を既定のアプリで開く（編集もここで）
    func openProfileFile() {
        NSWorkspace.shared.open(store.url.resolvingSymlinksInPath())
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

// MARK: メニュー（選ばれているものの表示だけ。操作は設定画面で行う）

private struct HostsMenuItems: View {
    let module: HostsModule

    var body: some View {
        if module.settings.hasManagedBlock {
            Text("Hosts：適用中「\(module.settings.appliedProfileName ?? "?")」")
        } else {
            Text("Hosts：未適用")
        }
        Divider()
        Button("Hosts の設定…") { SettingsWindowController.shared.show(pane: "hosts") }
    }
}

// MARK: 設定画面（ラジオ式）

struct HostsSettingsView: View {
    let module: HostsModule

    var body: some View {
        Form {
            Section {
                ForEach(module.store.profiles) { profile in
                    HStack(spacing: 8) {
                        Image(systemName: module.isApplied(profile) ? "smallcircle.filled.circle" : "circle")
                            .foregroundStyle(module.isApplied(profile) ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        Button {
                            module.confirmAndApply(profile)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(profile.displayName)
                                if let sub = subtext(for: profile) {
                                    Text(sub).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button("見る") { module.openContents(profile) }
                            .help("このプロファイルの中身を、ほかのアプリで開きます")
                        Button {
                            rename(profile)
                        } label: {
                            Image(systemName: "pencil").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("名前を変える")
                        Button {
                            remove(profile)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("消す")
                    }
                }
                // n+1 番目の選択肢「なし」
                HStack(spacing: 8) {
                    Image(systemName: module.settings.hasManagedBlock ? "circle" : "smallcircle.filled.circle")
                        .foregroundStyle(!module.settings.hasManagedBlock ? Color.accentColor : Color.secondary)
                        .frame(width: 16)
                    Button {
                        module.confirmAndApply(nil)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("なし")
                            Text("hosts に MitsuTools の行を入れない").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                HStack {
                    Button("追加…") { addProfile() }
                    Spacer()
                    Button("ファイルを編集…") { module.openProfileFile() }
                }
            } header: {
                Text("プロファイル")
            } footer: {
                Text("丸の1つが、今 /etc/hosts に効いているものです。他の行を選ぶと「変わる行」を確認する画面が出ます（承認するまで hosts は変わりません）。中身の確認や編集は、ほかのアプリで行ってください（ファイルは \(module.store.url.path)）。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("切り替えるときに DNS のキャッシュを消す", isOn: Binding(
                    get: { module.settings.flushDNS },
                    set: { module.settings.flushDNS = $0 }
                ))
                HStack {
                    Spacer()
                    Button("直前の内容に戻す…") { module.confirmRestoreBackup() }
                }
            } header: {
                Text("オプション")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            module.store.load()
            module.refreshState()
        }
    }

    /// 行の説明。行数は出さない（長いと読めないため）
    private func subtext(for profile: HostsProfile) -> String? {
        if module.isApplied(profile) {
            return module.isStale(profile) ? "適用中（編集した内容の適用待ち）" : "適用中"
        }
        return nil
    }

    private func addProfile() {
        let alert = NSAlert()
        alert.messageText = "プロファイルを追加"
        alert.informativeText = "名前を入力してください（中身の行は、あとで「ファイルを編集…」から足します）"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "例: 開発"
        alert.accessoryView = field
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = module.store.add(name: field.stringValue.trimmingCharacters(in: .whitespaces))
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
        let wasApplied = module.isApplied(profile)
        var updated = profile
        updated.name = field.stringValue.trimmingCharacters(in: .whitespaces)
        module.store.update(updated)
        // 適用中だったものの名前を変えると、hosts の中の名前とずれる。確認して再適用させる
        if wasApplied { module.confirmAndApply(updated) }
    }

    /// 適用中のプロファイルを消すときは、hosts からも外す（確認つき）
    private func remove(_ profile: HostsProfile) {
        if module.isApplied(profile) {
            let alert = NSAlert()
            alert.messageText = "「\(profile.displayName)」は適用中です。hosts から外してから消しますか？"
            alert.informativeText = "取り消すと、プロファイルは消えません。"
            alert.addButton(withTitle: "外して消す")
            alert.addButton(withTitle: "取り消し")
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            module.confirmAndApply(nil)
            // 「なし」への切り替えが取り消されたときは、消さない
            if module.settings.appliedProfileName == profile.name { return }
        }
        module.store.remove(profile)
    }
}
