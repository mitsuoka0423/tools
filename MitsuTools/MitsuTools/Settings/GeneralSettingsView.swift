import SwiftUI

struct GeneralSettingsView: View {
    @State private var model = AppModel.shared
    private let permission = AccessibilityPermission.shared
    private let config = ConfigFile.shared

    var body: some View {
        Form {
            Section {
                Toggle("ログイン時に開く", isOn: $model.launchesAtLogin)
                Toggle(isOn: $model.showsMenuBarIcon) {
                    Text("メニューバーに表示")
                    Text("オフにしても、アプリをもう一度開けば設定が開きます。")
                }
            }

            Section("権限") {
                LabeledContent {
                    if permission.isTrusted {
                        Label("許可済み", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("許可する…") {
                            permission.request()
                            permission.openSystemSettings()
                        }
                    }
                } label: {
                    Text("アクセシビリティ")
                    Text("ウィンドウの移動と、選んだ履歴の自動貼り付けに必要です。")
                }
            }

            Section {
                LabeledContent {
                    Button("Finder で表示") { config.revealInFinder() }
                } label: {
                    Text(config.displayPath).textSelection(.enabled)
                    Text("dotfiles で管理する場合は、このファイルをリンクしてください。編集して保存すると、すぐ反映されます。")
                }
                if let error = config.lastError {
                    Label("読み込めませんでした（\(error)）", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("設定ファイル")
            }

            Section("機能") {
                ForEach(model.modules, id: \.id) { module in
                    Toggle(isOn: Binding(
                        get: { model.isEnabled(module) },
                        set: { model.setEnabled($0, for: module) }
                    )) {
                        Label(module.title, systemImage: module.systemImage)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

struct UpdateSettingsView: View {
    @State private var updater = Updater.shared

    var body: some View {
        Form {
            Section {
                Toggle("アップデートを自動で確認", isOn: $updater.automaticallyChecks)
                Toggle("アップデートを自動でダウンロード", isOn: $updater.automaticallyDownloads)
                    .disabled(!updater.automaticallyChecks)
            }
            Section {
                LabeledContent {
                    Button("今すぐ確認") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } label: {
                    Text("MitsuTools \(Bundle.main.shortVersion)（\(Bundle.main.buildNumber)）")
                    if let date = updater.lastCheckDate {
                        Text("最終確認：\(date.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

extension Bundle {
    var shortVersion: String { object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-" }
    var buildNumber: String { object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-" }
}
