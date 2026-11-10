import AppKit
import SwiftUI

/// 配置した直後に画面下へ約 1 秒出す、Liquid Glass のカプセル。
@MainActor
final class SnapHUD {
    private var panel: FloatingPanel?
    private var hideWork: DispatchWorkItem?

    func show(text: String, placement: Placement?, on screen: NSScreen) {
        let panel = self.panel ?? {
            let p = FloatingPanel(contentRect: .zero, acceptsKey: false)
            p.ignoresMouseEvents = true
            p.level = .statusBar
            self.panel = p
            return p
        }()
        panel.setRootView(SnapHUDView(text: text, placement: placement))
        let size = panel.contentView?.fittingSize ?? CGSize(width: 200, height: 48)
        let area = screen.visibleFrame
        panel.setFrame(CGRect(x: area.midX - size.width / 2, y: area.minY + 56, width: size.width, height: size.height),
                       display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel?.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { panel?.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }
}

private struct SnapHUDView: View {
    let text: String
    let placement: Placement?

    var body: some View {
        HStack(spacing: 10) {
            if let placement { MiniLayout(placement: placement).frame(width: 30, height: 19) }
            Text(text).font(.body.weight(.medium)).monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(12) // 影のための余白
        .fixedSize()
    }
}

/// どのマスに置いたかを示す小さな図。
struct MiniLayout: View {
    let placement: Placement

    var body: some View {
        GeometryReader { geo in
            let g: CGFloat = 2
            switch placement {
            case let .cell(layout, index):
                let w = (geo.size.width - g * CGFloat(layout.columns - 1)) / CGFloat(layout.columns)
                let h = (geo.size.height - g * CGFloat(layout.rows - 1)) / CGFloat(layout.rows)
                ForEach(0..<layout.cellCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i == index ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .frame(width: w, height: h)
                        .offset(x: CGFloat(i % layout.columns) * (w + g), y: CGFloat(i / layout.columns) * (h + g))
                }
            case let .side(left, step):
                let f = Placement.sideFractions[step]
                let a = (geo.size.width - g) * f, b = geo.size.width - g - a
                HStack(spacing: g) {
                    RoundedRectangle(cornerRadius: 2).fill(left ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                        .frame(width: left ? a : b)
                    RoundedRectangle(cornerRadius: 2).fill(left ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                        .frame(width: left ? b : a)
                }
            }
        }
    }
}
