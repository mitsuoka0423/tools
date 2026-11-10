import SwiftUI
import Carbon.HIToolbox

/// クリックしてからキーを押すとショートカットを登録できる入力欄。
/// esc で取り消し、⌫ で割り当てを外す。
struct ShortcutRecorder: View {
    let actionID: String

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var warning: String?
    @State private var isHovering = false

    private var center: HotKeyCenter { .shared }

    /// 入力欄の幅。割り当ての有無や入力中かで変わらないよう固定する
    private static let width: CGFloat = 132

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            field
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    /// 入力欄。割り当てを外す ⊗ は欄の中の右端に置き、
    /// 押し間違いを減らすため、マウスを乗せている間だけ出す。押せるのはアイコンの大きさだけ。
    private var field: some View {
        let canClear = center.shortcut(for: actionID) != nil && !isRecording
        return ZStack(alignment: .trailing) {
            Button(action: toggleRecording) {
                Text(label)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(isRecording ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22) // 両端に ⊗ のぶんの余白をとり、文字を中央に保つ
                    .frame(height: 22)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("クリックして新しいショートカットを押してください。esc で取り消し、⌫ で割り当てを外します。")

            if canClear && isHovering {
                Button {
                    center.setShortcut(nil, for: actionID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("割り当てを外す")
                .padding(.trailing, 6)
                .transition(.opacity)
            }
        }
        .frame(width: Self.width)
        .background(Capsule().fill(.quaternary))
        .overlay(Capsule().strokeBorder(isRecording ? Color.accentColor : .clear, lineWidth: 1.5))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    private var label: String {
        if isRecording { return "キーを押す…" }
        return center.shortcut(for: actionID)?.displayString ?? "なし"
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        warning = nil
        isRecording = true
        center.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        center.isSuspended = false
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        switch Int(event.keyCode) {
        case kVK_Escape where flags.isEmpty:
            stopRecording()
            return
        case kVK_Delete where flags.isEmpty, kVK_ForwardDelete where flags.isEmpty:
            center.setShortcut(nil, for: actionID)
            stopRecording()
            return
        default:
            break
        }
        // ⌃⌥⌘ のどれかを含まないと、普段の入力とぶつかるので受け付けない。
        guard !flags.intersection([.control, .option, .command]).isEmpty else {
            warning = "⌃・⌥・⌘ のいずれかと組み合わせてください"
            NSSound.beep()
            return
        }
        let shortcut = Shortcut(keyCode: Int(event.keyCode), modifiers: flags)
        if let other = center.conflict(for: shortcut, excluding: actionID) {
            warning = "「\(other.title)」と重なっています"
            NSSound.beep()
            return
        }
        center.setShortcut(shortcut, for: actionID)
        stopRecording()
    }
}
