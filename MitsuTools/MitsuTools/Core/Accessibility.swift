import AppKit
import ApplicationServices
import Observation

/// Accessibility（アクセシビリティ）権限の状態を監視する。
@MainActor
@Observable
final class AccessibilityPermission {
    static let shared = AccessibilityPermission()

    private(set) var isTrusted = AXIsProcessTrusted()
    @ObservationIgnored private var timer: Timer?

    private init() {
        // 許可されたかどうかはシステムから通知されないので、未許可の間だけ確認し続ける。
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { AccessibilityPermission.shared.refresh() }
        }
    }

    func refresh() {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
    }

    /// システムの許可ダイアログを出す。
    func request() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
