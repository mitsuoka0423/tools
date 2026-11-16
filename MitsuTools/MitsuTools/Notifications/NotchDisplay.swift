import AppKit
import SwiftUI

/// 通知を画面上部中央（ノッチ風）に出すパネル。クリックは通り抜け、追従しない。
/// 物理ノッチのある Mac ではノッチの下に重なる位置、ない Mac では「擬似ノッチ」に見える位置に出す。
@MainActor
final class NotchDisplay {
    private var panel: FloatingPanel?
    private var dismissWork: DispatchWorkItem?

    func show(_ note: IncomingNotification, seconds: Double) {
        let panel = self.panel ?? makePanel()
        let icon = note.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        panel.setRootView(NotificationCard(note: note, icon: icon))

        let size = panel.contentView?.fittingSize ?? CGSize(width: 340, height: 58)
        let width = max(300, min(size.width, 420))
        let height = max(52, min(size.height, 110))
        guard let screen = NSScreen.main ?? NSScreen.withMouse else { return }
        // 上辺ぴったりに、横は中央。ノッチのある画面では、ノッチの真下に来る（目立たない）
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height
        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.fadeOut() } }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func hide() {
        dismissWork?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let p = FloatingPanel(contentRect: .zero, acceptsKey: false)
        p.ignoresMouseEvents = true
        p.level = .statusBar
        panel = p
        return p
    }

    private func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }
}

private struct NotificationCard: View {
    let note: IncomingNotification
    let icon: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 26, height: 26)
            } else {
                Image(systemName: "bell.fill").foregroundStyle(.white).frame(width: 26, height: 26)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let subtitle = note.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                }
                if !note.body.isEmpty {
                    Text(note.body).font(.system(size: 12)).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.92))
        // 上は画面のフチに付け、した側だけ丸める（ノッチと同じ見え方）
        .clipShape(BottomRoundedCorners(radius: 14))
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BottomRoundedCorners: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: rect.origin)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                 radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                 radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}
