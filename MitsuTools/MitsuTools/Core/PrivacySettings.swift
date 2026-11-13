import AppKit
import Observation

/// 全機能に共通のプライバシーの設定。
/// 「機密情報を扱うアプリ」は 1 か所に登録すれば、クリップボード履歴にも自動コピーにも効く。
/// 機能ごとに登録し忘れて、機密が漏れることがないようにするため。
@MainActor
@Observable
final class PrivacySettings {
    static let shared = PrivacySettings()

    /// 機密情報を扱うアプリの Bundle ID。クリップボード履歴に記録せず、自動コピーもしない。
    var sensitiveBundleIDs: [String] {
        didSet { UserDefaults.standard.set(sensitiveBundleIDs, forKey: Self.key) }
    }

    private static let key = "privacy.sensitiveApps"
    /// 以前はクリップボード履歴だけの設定だった。その値があれば引き継ぐ。
    private static let legacyKey = "clipboard.excludedBundleIDs"
    static let defaultSensitiveBundleIDs = [
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    private init() {
        let d = UserDefaults.standard
        sensitiveBundleIDs = d.stringArray(forKey: Self.key)
            ?? d.stringArray(forKey: Self.legacyKey)
            ?? Self.defaultSensitiveBundleIDs
    }

    func isSensitive(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return sensitiveBundleIDs.contains(bundleID)
    }
}
