import AppKit
import SwiftUI
import Observation
import Carbon.HIToolbox

/// 履歴パネルの表示状態。
@MainActor
@Observable
final class ClipboardPanelModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all, text, image, file
        var id: String { rawValue }
        var label: String {
            switch self { case .all: "すべて"; case .text: "テキスト"; case .image: "画像"; case .file: "ファイル" }
        }
    }

    let store: ClipboardStore
    var query = ""
    var filter: Filter = .all
    var selection = 0

    init(store: ClipboardStore) { self.store = store }

    var visibleItems: [ClipboardItem] {
        store.items.filter { item in
            let kindOK: Bool = switch filter {
            case .all: true
            case .text: item.kind == .text
            case .image: item.kind == .image
            case .file: item.kind == .file
            }
            return kindOK && (query.isEmpty || item.searchText.localizedCaseInsensitiveContains(query))
        }
    }

    func reset() {
        query = ""
        filter = .all
        selection = 0
    }

    func move(_ delta: Int) {
        let count = visibleItems.count
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }
}

/// Spotlight 型のクリップボード履歴パネル。
@MainActor
final class ClipboardPanelController {
    private let store: ClipboardStore
    private let model: ClipboardPanelModel
    private var panel: FloatingPanel?

    static let size = CGSize(width: 640, height: 420)

    init(store: ClipboardStore) {
        self.store = store
        self.model = ClipboardPanelModel(store: store)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.reset()
        if let screen = NSScreen.withMouse {
            let frame = screen.visibleFrame
            let origin = CGPoint(x: frame.midX - Self.size.width / 2,
                                 y: frame.maxY - frame.height * 0.18 - Self.size.height)
            panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: Self.size))
        panel.onResignKey = { [weak self] in self?.close() }
        panel.onCancel = { [weak self] in self?.close() }
        panel.setRootView(
            ClipboardPanelView(model: model,
                               onChoose: { [weak self] item, plain in self?.choose(item, plainTextOnly: plain) },
                               onClose: { [weak self] in self?.close() })
        )
        return panel
    }

    private func choose(_ item: ClipboardItem, plainTextOnly: Bool) {
        store.write(item, plainTextOnly: plainTextOnly)
        close()
        guard store.autoPaste, AccessibilityPermission.shared.isTrusted else { return }
        // パネルを閉じてから、元のアプリへ ⌘V を送る。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Self.sendPaste() }
    }

    private static func sendPaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - View

struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel
    let onChoose: (ClipboardItem, Bool) -> Void
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool

    private let outerRadius: CGFloat = 26
    private let inset: CGFloat = 8
    private var innerRadius: CGFloat { outerRadius - inset } // 同心円の角丸

    var body: some View {
        let items = model.visibleItems
        VStack(spacing: 0) {
            searchField(items)
            filterChips
            HStack(spacing: 6) {
                list(items)
                preview(items.indices.contains(model.selection) ? items[model.selection] : nil)
            }
            .frame(maxHeight: .infinity)
            footer(items)
        }
        .padding(inset)
        .frame(width: ClipboardPanelController.size.width, height: ClipboardPanelController.size.height)
        .glassEffect(.regular, in: .rect(cornerRadius: outerRadius))
        .onAppear { searchFocused = true }
        .onChange(of: model.query) { model.selection = 0 }
        .onChange(of: model.filter) { model.selection = 0 }
    }

    private func searchField(_ items: [ClipboardItem]) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.title3)
                .foregroundStyle(.secondary)
            TextField("クリップボード履歴を検索", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20))
                .focused($searchFocused)
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onKeyPress(keys: [.return]) { press in
                    choose(items, index: model.selection, plain: press.modifiers.contains(.shift))
                    return .handled
                }
                .onKeyPress(characters: CharacterSet(charactersIn: "123456789")) { press in
                    guard press.modifiers == .command, let n = Int(press.characters) else { return .ignored }
                    choose(items, index: n - 1, plain: false)
                    return .handled
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var filterChips: some View {
        HStack(spacing: 4) {
            ForEach(ClipboardPanelModel.Filter.allCases) { filter in
                Button(filter.label) { model.filter = filter }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 3)
                    .foregroundStyle(model.filter == filter ? Color.white : Color.primary)
                    .background(Capsule().fill(model.filter == filter ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary)))
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func list(_ items: [ClipboardItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if items.isEmpty {
                        Text(model.store.items.isEmpty ? "まだ履歴はありません" : "一致する項目はありません")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index, selected: index == model.selection)
                            .id(item.id)
                            .onTapGesture { choose(items, index: index, plain: false) }
                            .onHover { if $0 { model.selection = index } }
                    }
                }
                .padding(2)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .contentMargins(.vertical, 4, for: .scrollContent)
            .onChange(of: model.selection) {
                if items.indices.contains(model.selection) {
                    proxy.scrollTo(items[model.selection].id)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ item: ClipboardItem, index: Int, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(item.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    private func preview(_ item: ClipboardItem?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let item {
                Group {
                    switch item.kind {
                    case .image:
                        if let image = item.image {
                            Image(nsImage: image).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    case .file:
                        ScrollView {
                            Text(item.fileURLs.map(\.path).joined(separator: "\n"))
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    case .text:
                        ScrollView {
                            Text(String((item.plainText ?? "").prefix(5000)))
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                Text([item.appName, item.date.formatted(.relative(presentation: .named))]
                        .compactMap { $0 }.joined(separator: " ・ "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: innerRadius).fill(.quinary))
    }

    private func footer(_ items: [ClipboardItem]) -> some View {
        HStack(spacing: 16) {
            if !items.isEmpty {
                Text("\(model.selection + 1) / \(items.count) 件").monospacedDigit()
            }
            Spacer()
            Text("↩ 貼り付け")
            Text("⇧↩ プレーンテキストで貼り付け")
            Text("⌘1〜9 直接選択")
            Text("esc 閉じる")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func choose(_ items: [ClipboardItem], index: Int, plain: Bool) {
        guard items.indices.contains(index) else { return }
        onChoose(items[index], plain)
    }
}
