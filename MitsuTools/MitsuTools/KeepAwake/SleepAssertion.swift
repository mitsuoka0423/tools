import IOKit.pwr_mgt

/// macOS に「スリープさせないで」と伝える（電源アサーション）。
/// 解放するか、アプリが終了すると、効力はなくなる。ファイルや設定には何も残らない。
nonisolated final class SleepAssertion {
    enum Level {
        /// Mac 本体がスリープしない。ディスプレイは、設定の時間で消えてよい。
        case system
        /// Mac 本体もディスプレイもスリープしない。
        case display
    }

    private var id: IOPMAssertionID = 0
    private(set) var isHeld = false

    /// すでに保持していれば、いったん解放して取り直す。成功したら true。
    @discardableResult
    func hold(_ level: Level, reason: String) -> Bool {
        release()
        let type: CFString = level == .display
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
            : kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        isHeld = result == kIOReturnSuccess
        return isHeld
    }

    func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(id)
        id = 0
        isHeld = false
    }

    deinit { release() }
}
