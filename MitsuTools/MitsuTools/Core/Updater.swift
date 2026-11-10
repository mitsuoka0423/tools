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

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { updater, _ in
            let value = updater.canCheckForUpdates
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
        controller.checkForUpdates(nil)
    }
}
