import AppKit
import SwiftUI

/// タイトルバーのない、ほかのアプリをアクティブにしたままキー入力を受け取れるパネル。
/// クリップボード履歴・マス選択オーバーレイ・HUD で使う。
final class FloatingPanel: NSPanel {
    var acceptsKey = true
    /// フォーカスを失ったときに呼ばれる（閉じる処理などに使う）。
    var onResignKey: (() -> Void)?

    init(contentRect: NSRect, acceptsKey: Bool = true) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: true)
        self.acceptsKey = acceptsKey
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    func setRootView<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

extension NSScreen {
    /// マウスカーソルがある画面。
    static var withMouse: NSScreen? {
        let point = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(point, $0.frame, false) } ?? main
    }
}
