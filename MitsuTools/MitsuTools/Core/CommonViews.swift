import SwiftUI
import UniformTypeIdentifiers

/// アクセシビリティの許可が足りないときだけ、機能のペインの先頭に出すお知らせ。
///
/// 許可の操作（許可する・システム設定・ Finder 表示）は「一般 › 権限」に一本化している
/// （Single Source of Truth）。バナーは状態の気づきだけで、操作は一般タブへ運ぶ。
struct PermissionBanner: View {
    /// その機能が、許可を何に使うか。例: 「ウィンドウを動かすのに使います。」
    let reason: String
    private let permission = AccessibilityPermission.shared

    var body: some View {
        if !permission.isTrusted {
            PermissionNudge(permission: "アクセシビリティ", reason: reason)
        }
    }
}

/// フルディスクアクセスの許可が足りないときだけ、機能のペインの先頭に出すお知らせ。
/// 操作は「一般 › 権限」に一本化（`PermissionBanner` と同じ方針）。
struct DiskAccessBanner: View {
    /// その機能が、ファイル読みを何に使うか。
    let reason: String
    private let permission = FullDiskAccessPermission.shared

    var body: some View {
        if !permission.isGranted {
            PermissionNudge(permission: "フルディスクアクセス", reason: reason)
        }
    }
}

/// 許可系バナーの共通の見た目。「許可の本体は一般タブにある」ので、操作持ちは「権限…」だけ。
private struct PermissionNudge: View {
    let permission: String
    let reason: String

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(permission)の許可が必要です").fontWeight(.semibold)
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("権限…") { SettingsWindowController.shared.show(pane: "general") }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(Color.orange.opacity(0.14))
    }
}

/// アプリの一覧を編集する欄（Bundle ID の配列）。追加はファイル選択の画面で行う。
struct AppListEditor: View {
    let title: String
    var subtitle: String? = nil
    @Binding var bundleIDs: [String]

    var body: some View {
        LabeledContent {
            Button("追加…", action: add)
        } label: {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
        ForEach(bundleIDs, id: \.self) { bundleID in
            HStack {
                appLabel(bundleID)
                Spacer()
                Button {
                    bundleIDs.removeAll { $0 == bundleID }
                } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("リストから外す")
            }
        }
    }

    @ViewBuilder
    private func appLabel(_ bundleID: String) -> some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Label {
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } icon: {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 16, height: 16)
            }
        } else {
            Text(bundleID).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !bundleIDs.contains(id) { bundleIDs.append(id) }
        }
    }
}
