import Foundation
import Observation
import Sparkle

/// Sparkle によるアップデート確認。
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// 開発用ビルドではアップデートを止める。
    /// 開発用ビルドの CFBundleVersion は常に 1 なので、配信版が必ず新しいと判断され、
    /// 開発用ビルドが配信版に置き換えられてしまうため。
    #if DEBUG
    nonisolated static let isEnabled = false
    #else
    nonisolated static let isEnabled = true
    #endif

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { updater, _ in
            let value = updater.canCheckForUpdates && Updater.isEnabled
            Task { @MainActor in Updater.shared.canCheckForUpdates = value }
        }
    }

    private var updater: SPUUpdater { controller.updater }

    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return updater.automaticallyChecksForUpdates }
        set { withMutation(keyPath: \.automaticallyChecks) { updater.automaticallyChecksForUpdates = newValue } }
    }

    var automaticallyDownloads: Bool {
        get { access(keyPath: \.automaticallyDownloads); return updater.automaticallyDownloadsUpdates }
        set { withMutation(keyPath: \.automaticallyDownloads) { updater.automaticallyDownloadsUpdates = newValue } }
    }

    var lastCheckDate: Date? { updater.lastUpdateCheckDate }

    func checkForUpdates() {
        guard Self.isEnabled else { return }
        controller.checkForUpdates(nil)
    }
}
