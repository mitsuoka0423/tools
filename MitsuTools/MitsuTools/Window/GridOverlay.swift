import AppKit
import SwiftUI
import Observation

/// ⌃⌥G で出す、マスを選ぶためのオーバーレイ。
/// クリックか番号キーで選ぶ。tab でレイアウト切り替え、esc で取り消し。
@MainActor
final class GridOverlayController {
    private let manager: WindowManager
    private var panel: FloatingPanel?
    private let state = OverlayState()
    private var target: AXWindow?

    init(manager: WindowManager) { self.manager = manager }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        guard AccessibilityPermission.shared.isTrusted else { AccessibilityPermission.shared.request(); return }
        guard let window = AXWindow.focused(), let frame = window.frame,
              let screen = NSScreen.best(for: frame) else { NSSound.beep(); return }
        target = window
        state.layout = GridLayout(rawValue: UserDefaults.standard.string(forKey: "window.overlayLayout") ?? "") ?? .quad
        state.screenFrame = screen.axFrame
        state.visibleFrame = screen.axVisibleFrame
        state.geometry = LayoutGeometry(gap: manager.gap, margin: manager.margin)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: false)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        target = nil
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: .zero)
        panel.level = .statusBar
        panel.onResignKey = { [weak self] in self?.close() }
        panel.setRootView(GridOverlayView(state: state,
                                          onPick: { [weak self] in self?.pick($0) },
                                          onNextLayout: { [weak self] in self?.nextLayout() },
                                          onClose: { [weak self] in self?.close() }))
        return panel
    }

    private func nextLayout() {
        state.layout = state.layout.next
        UserDefaults.standard.set(state.layout.rawValue, forKey: "window.overlayLayout")
    }

    private func pick(_ index: Int) {
        guard let window = target, index < state.layout.cellCount else { return }
        let layout = state.layout
        close()
        if layout == .halves {
            manager.snapToSide(left: index == 0, window: window)
        } else {
            manager.snapToCell(layout, index, window: window)
        }
    }
}

@MainActor
@Observable
final class OverlayState {
    var layout: GridLayout = .quad
    var screenFrame: CGRect = .zero
    var visibleFrame: CGRect = .zero
    var geometry = LayoutGeometry(gap: 12, margin: 12)

    /// オーバーレイ内（左上原点）でのマスの位置。
    func cellRect(_ index: Int) -> CGRect {
        let placement: Placement = layout == .halves ? .side(left: index == 0, step: 0) : .cell(layout, index)
        return geometry.frame(for: placement, in: visibleFrame)
            .offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }
}

private struct GridOverlayView: View {
    let state: OverlayState
    let onPick: (Int) -> Void
    let onNextLayout: () -> Void
    let onClose: () -> Void

    @FocusState private var focused: Bool
    @State private var hovered: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)

            ForEach(0..<state.layout.cellCount, id: \.self) { index in
                let rect = state.cellRect(index)
                cell(index)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }

            hint
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 40)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onKeyPress(.tab) { onNextLayout(); return .handled }
        .onKeyPress(.leftArrow) { state.layout == .halves ? (onPick(0), KeyPress.Result.handled).1 : .ignored }
        .onKeyPress(.rightArrow) { state.layout == .halves ? (onPick(1), KeyPress.Result.handled).1 : .ignored }
        .onKeyPress(characters: .decimalDigits) { press in
            guard let n = Int(press.characters), n >= 1 else { return .ignored }
            onPick(n - 1)
            return .handled
        }
    }

    private func cell(_ index: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let isHovered = hovered == index
        return ZStack {
            shape.fill(isHovered ? Color.accentColor.opacity(0.38) : Color.white.opacity(0.10))
            shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 1.5)
            Text(label(index))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .frame(width: 52, height: 52)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .contentShape(shape)
        .onHover { hovered = $0 ? index : (hovered == index ? nil : hovered) }
        .onTapGesture { onPick(index) }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func label(_ index: Int) -> String {
        state.layout == .halves ? (index == 0 ? "←" : "→") : "\(index + 1)"
    }

    private var hint: some View {
        HStack(spacing: 14) {
            Text(state.layout.label).fontWeight(.semibold)
            Text(state.layout == .halves ? "← → で選ぶ" : "番号キーで選ぶ")
            Text("tab で切り替え")
            Text("esc で取り消し")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}
