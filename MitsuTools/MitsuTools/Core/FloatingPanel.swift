import AppKit
import SwiftUI
import Carbon.HIToolbox

/// タイトルバーのない、ほかのアプリをアクティブにしたままキー入力を受け取れるパネル。
/// クリップボード履歴・マス選択オーバーレイ・HUD で使う。
final class FloatingPanel: NSPanel {
    var acceptsKey = true
    /// フォーカスを失ったときに呼ばれる（閉じる処理などに使う）。
    var onResignKey: (() -> Void)?
    /// esc を押したときに呼ばれる。
    /// テキスト入力欄は esc を自分で使ってしまい SwiftUI まで届かないので、パネルの段階で拾う。
    var onCancel: (() -> Void)?
    /// キー入力をテキスト入力欄より先に受け取る。true を返すとそのキーはそこで止める。
    /// ↑↓や↩︎も入力欄が先に使ってしまうので、一覧の操作はここで行う。
    var keyHandler: ((NSEvent) -> Bool)?

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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) {
            return
        }
        if event.type == .keyDown, event.keyCode == UInt16(kVK_Escape),
           event.modifierFlags.intersection(Shortcut.relevantModifiers).isEmpty,
           let onCancel {
            onCancel()
            return
        }
        super.sendEvent(event)
    }

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
