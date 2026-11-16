import AppKit
import Observation

/// フルディスクアクセス（Full Disk Access）許可の状態を監視する。
///
/// アクセシビリティと違い、アプリから確認ダイアログを出す決まった手段がない。
/// 保護されたファイルに実際に触って判定し、許可はシステム設定でってもらう。
/// 許可の後にはアプリのやり直しが必要なことがほとんどなので、その案内もセットにする。
@MainActor
@Observable
final class FullDiskAccessPermission {
    static let shared = FullDiskAccessPermission()

    private(set) var isGranted = UserNotedStore.canOpen()
    @ObservationIgnored private var timer: Timer?

    private init() {
        // 許可されたかどうかはシステムから通知されないので、未許可の間だけ確認し続ける。
        // （許可が反映されるには MitsuTools のやり直しが必要なことも多く、その場合は次回起動で拾う。）
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { FullDiskAccessPermission.shared.refresh() }
        }
    }

    func refresh() {
        let granted = UserNotedStore.canOpen()
        if granted != isGranted {
            isGranted = granted
        }
    }

    func openSystemSettings() {
        // プライバシーペインの開き方は OS の世代で違うため、効くものを順に試す
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.Settings.Privacy.FullDiskAccess",
            "x-apple.systempreferences:com.apple.preference.security?Privacy",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// Finder でこのアプリを選択した状態にする（一覧にないとき、そこへドラッグして追加もらう）
    func revealSelfInFinder() {
        NSApp.activate()
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
