import AppKit
import Observation

/// アクティブウィンドウ 1 つをマスへ収める・左右に寄せる・ディスプレイを移す。
@MainActor
@Observable
final class WindowManager {
    var gap: Double {
        didSet { UserDefaults.standard.set(gap, forKey: "window.gap") }
    }
    var margin: Double {
        didSet { UserDefaults.standard.set(margin, forKey: "window.margin") }
    }

    @ObservationIgnored let hud = SnapHUD()

    /// 直前の操作。左右の連続操作（1/2 → 1/3 → 2/3）の判定に使う。
    @ObservationIgnored private var last: (window: AXWindow, placement: Placement, frame: CGRect)?
    /// 各ウィンドウを最後にどこへ置いたか。ディスプレイ移動時に同じマスへ収め直すのに使う。
    @ObservationIgnored private var history: [(window: AXWindow, placement: Placement, frame: CGRect)] = []

    init() {
        UserDefaults.standard.register(defaults: ["window.gap": 12.0, "window.margin": 12.0])
        gap = UserDefaults.standard.double(forKey: "window.gap")
        margin = UserDefaults.standard.double(forKey: "window.margin")
    }

    private var geometry: LayoutGeometry { LayoutGeometry(gap: gap, margin: margin) }

    // MARK: 操作

    /// 2×2・2×3 のマスへ収める。
    func snapToCell(_ layout: GridLayout, _ index: Int, window: AXWindow? = nil) {
        guard let window = target(window), let frame = window.frame,
              let screen = NSScreen.best(for: frame) else { return }
        apply(.cell(layout, index), to: window, on: screen)
    }

    /// 左右に寄せる。同じ側へ続けて操作すると幅が 1/2 → 1/3 → 2/3 → 1/2 … と変わる。
    func snapToSide(left: Bool, window: AXWindow? = nil) {
        guard let window = target(window), let frame = window.frame,
              let screen = NSScreen.best(for: frame) else { return }
        var step = 0
        if let last, last.window.isSame(as: window), case let .side(lastLeft, lastStep) = last.placement,
           lastLeft == left, frame.isClose(to: last.frame) {
            step = (lastStep + 1) % Placement.sideFractions.count
        }
        apply(.side(left: left, step: step), to: window, on: screen)
    }

    /// 隣のディスプレイへ移す。端まで行ったら反対の端へ回り込む。
    func moveToDisplay(next: Bool) {
        let screens = NSScreen.ordered
        guard screens.count > 1, let window = target(nil), let frame = window.frame,
              let current = NSScreen.best(for: frame), let index = screens.firstIndex(of: current) else { return }
        let destination = screens[(index + (next ? 1 : -1) + screens.count) % screens.count]

        // マスに収めていたウィンドウは、移動先でも同じマスに収める。
        if let record = history.last(where: { $0.window.isSame(as: window) }), frame.isClose(to: record.frame) {
            apply(record.placement, to: window, on: destination)
            last = nil // 移動をはさんだので、左右の連続操作はやり直し
            return
        }
        // それ以外は、画面内での位置と大きさの比率を保つ。
        let from = current.axVisibleFrame, to = destination.axVisibleFrame
        let sx = to.width / from.width, sy = to.height / from.height
        let newFrame = CGRect(x: to.minX + (frame.minX - from.minX) * sx,
                              y: to.minY + (frame.minY - from.minY) * sy,
                              width: frame.width * sx, height: frame.height * sy).integral
        window.setFrame(newFrame)
        last = nil
        hud.show(text: "ディスプレイ \(screens.firstIndex(of: destination)! + 1)", placement: nil, on: destination)
    }

    // MARK: 内部

    private func target(_ window: AXWindow?) -> AXWindow? {
        guard AccessibilityPermission.shared.isTrusted else {
            AccessibilityPermission.shared.request()
            return nil
        }
        if let window { return window }
        guard let window = AXWindow.focused() else { NSSound.beep(); return nil }
        return window
    }

    private func apply(_ placement: Placement, to window: AXWindow, on screen: NSScreen) {
        let frame = geometry.frame(for: placement, in: screen.axVisibleFrame)
        window.setFrame(frame)
        // アプリによっては最小サイズなどで要求どおりにならないので、実際のフレームを覚えておく。
        let actual = window.frame ?? frame
        last = (window, placement, actual)
        history.removeAll { $0.window.isSame(as: window) }
        history.append((window, placement, actual))
        if history.count > 50 { history.removeFirst(history.count - 50) }
        hud.show(text: placement.hudText, placement: placement, on: screen)
    }
}
