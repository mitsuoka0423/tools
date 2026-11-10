import AppKit
import SwiftUI
import Observation
import Carbon.HIToolbox

@MainActor
@Observable
final class BookmarkPanelModel {
    let store: BookmarkStore
    var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    private(set) var results: [Bookmark] = []
    var selection = 0
    /// パネルを開くたびに増やし、検索欄へフォーカスを移すきっかけにする
    var focusRequest = 0

    init(store: BookmarkStore) { self.store = store }

    func refresh() {
        results = store.search(query)
        selection = 0
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = min(max(selection + delta, 0), results.count - 1)
    }
}

/// Spotlight 型のブックマーク検索パネル。選んだブックマークはデフォルトのブラウザで開く。
@MainActor
final class BookmarkPanelController {
    private let store: BookmarkStore
    private let model: BookmarkPanelModel
    private var panel: FloatingPanel?

    static let size = CGSize(width: 640, height: 420)

    init(store: BookmarkStore) {
        self.store = store
        self.model = BookmarkPanelModel(store: store)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() { isVisible ? close() : show() }

    func show() {
        // 開くたびに、ブラウザ側で変わったブックマークを読み直す
        store.reload(force: false)
        model.query = ""
        model.refresh()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let screen = NSScreen.withMouse {
            let frame = screen.visibleFrame
            let origin = CGPoint(x: frame.midX - Self.size.width / 2,
                                 y: frame.maxY - frame.height * 0.18 - Self.size.height)
            panel.setFrame(CGRect(origin: origin, size: Self.size), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        model.focusRequest += 1
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(contentRect: CGRect(origin: .zero, size: Self.size))
        panel.onResignKey = { [weak self] in self?.close() }
        panel.onCancel = { [weak self] in self?.close() }
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        panel.setRootView(BookmarkPanelView(model: model, onOpen: { [weak self] in self?.open($0) }))
        return panel
    }

    /// ↑↓ で選ぶ、↩︎ で開く、⌘1〜9 で直接開く。それ以外は検索欄へ渡す。
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        switch Int(event.keyCode) {
        case kVK_DownArrow where flags.isEmpty:
            model.move(1)
            return true
        case kVK_UpArrow where flags.isEmpty:
            model.move(-1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
            if model.results.indices.contains(model.selection) { open(model.results[model.selection]) }
            return true
        default:
            if flags == .command, let n = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(n) {
                if model.results.indices.contains(n - 1) { open(model.results[n - 1]) }
                return true
            }
            return false
        }
    }

    private func open(_ bookmark: Bookmark) {
        close()
        NSWorkspace.shared.open(bookmark.url) // デフォルトのブラウザで開く
    }
}

// MARK: - View

private struct BookmarkPanelView: View {
    @Bindable var model: BookmarkPanelModel
    let onOpen: (Bookmark) -> Void

    @FocusState private var searchFocused: Bool

    private let outerRadius: CGFloat = 26
    private let inset: CGFloat = 8

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                TextField("ブックマークを検索", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            list
                .frame(maxHeight: .infinity)

            footer
        }
        .padding(inset)
        .frame(width: BookmarkPanelController.size.width, height: BookmarkPanelController.size.height)
        .glassEffect(.regular, in: .rect(cornerRadius: outerRadius))
        .onAppear { searchFocused = true }
        .onChange(of: model.focusRequest) { DispatchQueue.main.async { searchFocused = true } }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if model.results.isEmpty {
                        Text(emptyMessage)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        row(item, index: index, selected: index == model.selection)
                            .id(item.id)
                            .onTapGesture { onOpen(item) }
                            .onHover { if $0 { model.selection = index } }
                    }
                }
                .padding(2)
            }
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .onChange(of: model.selection) {
                if model.results.indices.contains(model.selection) { proxy.scrollTo(model.results[model.selection].id) }
            }
        }
    }

    private var emptyMessage: String {
        if model.store.bookmarks.isEmpty {
            return "ブックマークがありません。設定の「ブックマーク」で読み込むブラウザを選んでください。"
        }
        return "一致するブックマークはありません"
    }

    private func row(_ item: Bookmark, index: Int, selected: Bool) -> some View {
        HStack(spacing: 10) {
            FaviconView(bookmark: item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                Text(subtitle(item))
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer(minLength: 8)
            Text(item.browser)
                .font(.caption)
                .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    /// URL（スキームを除く）とフォルダ
    private func subtitle(_ item: Bookmark) -> String {
        var url = item.url.absoluteString
        for prefix in ["https://", "http://"] where url.hasPrefix(prefix) { url.removeFirst(prefix.count) }
        return item.folder.isEmpty ? url : "\(url)　\(item.folder)"
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if !model.results.isEmpty {
                Text("\(model.selection + 1) / \(model.results.count) 件").monospacedDigit()
            }
            Spacer()
            Text("↩ デフォルトのブラウザで開く")
            Text("⌘1〜9 直接開く")
            Text("esc 閉じる")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// ブラウザが保存しているファビコン。なければ、ホスト名の頭文字を色付きの四角で出す。
private struct FaviconView: View {
    let bookmark: Bookmark

    var body: some View {
        Group {
            if let data = bookmark.favicon, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color)
                    .overlay(
                        Text(initial)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    private var host: String {
        var host = bookmark.url.host() ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private var initial: String { host.first.map { String($0).uppercased() } ?? "?" }

    /// 同じホストはいつも同じ色になるようにする
    private var color: Color {
        let hash = host.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.45, brightness: 0.75)
    }
}
