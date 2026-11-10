import SwiftUI
import Carbon.HIToolbox

/// クリックしてからキーを押すとショートカットを登録できる入力欄。
/// esc で取り消し、⌫ で割り当てを外す。
struct ShortcutRecorder: View {
    let actionID: String

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var warning: String?

    private var center: HotKeyCenter { .shared }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                Button(action: toggleRecording) {
                    Text(label)
                        .monospacedDigit()
                        .frame(minWidth: 96)
                        .foregroundStyle(isRecording ? Color.accentColor : .primary)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .help("クリックして新しいショートカットを押してください。esc で取り消し、⌫ で割り当てを外します。")

                if center.shortcut(for: actionID) != nil, !isRecording {
                    Button {
                        center.setShortcut(nil, for: actionID)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("割り当てを外す")
                }
            }
            if let warning {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var label: String {
        if isRecording { return "キーを押してください…" }
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
