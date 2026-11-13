import AppKit
import SwiftUI

/// コピーした範囲の少し上に出す「コピーしました」。クリックは通り抜ける。
@MainActor
final class CopiedPopup {
    private var panel: FloatingPanel?
    private var hideWork: DispatchWorkItem?

    /// rect は Accessibility の座標（左上原点）。nil ならマウスの位置の上に出す。
    func show(at rect: CGRect?, duration: Double) {
        let panel = self.panel ?? {
            let p = FloatingPanel(contentRect: .zero, acceptsKey: false)
            p.ignoresMouseEvents = true
            p.level = .statusBar
            p.setRootView(CopiedPopupView())
            self.panel = p
            return p
        }()
        let size = panel.contentView?.fittingSize ?? CGSize(width: 160, height: 56)
        let mouse = NSEvent.mouseLocation
        // 位置の基準（AppKit の座標＝左下原点）
        let anchor = rect.map { NSScreen.fromAX($0) } ?? CGRect(x: mouse.x, y: mouse.y + 14, width: 0, height: 0)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.withMouse
        let area = screen?.visibleFrame ?? anchor.insetBy(dx: -400, dy: -400)
        // 影のための余白（上下左右 12pt）があるので、少しだけ重ねる
        var y = anchor.maxY - 8
        if y + size.height > area.maxY { y = anchor.minY - size.height + 8 } // 上に余白がなければ下に出す
        let x = min(max(anchor.midX - size.width / 2, area.minX), area.maxX - size.width)
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fadeOut() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }
}

private struct CopiedPopupView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, .green)
                .font(.system(size: 16))
            Text("コピーしました").font(.system(size: 13, weight: .semibold))
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .padding(12) // 影のための余白
        .fixedSize()
    }
}
