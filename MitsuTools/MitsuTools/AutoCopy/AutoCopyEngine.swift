import AppKit
import Carbon.HIToolbox

/// 選択範囲の自動コピーの本体。
///
/// 「意図して選んだ範囲を、選び終えた時点で 1 回だけコピーする」。
/// - 確定：ボタン・キーを離していて、選択がもう続かないとわかった時点。
///   マルチクリックの途中かもしれない間だけ待つ（W）。動いた・キーを押した・ドラッグ・3 回目なら待たない。
/// - 意図：ドラッグ、2 回以上のクリック、⇧＋クリック、⌘A（設定でオフにできる）、
///   設定でオンなら ⇧＋移動キー。1 回のクリックやフォーカスで、アプリが作った全選択はコピーしない。
@MainActor
final class AutoCopyEngine {
    /// 設計の Q0〜Q4
    enum Phase { case idle, selecting, awaiting, deciding, copied }

    private struct Gesture {
        enum Kind { case mouse, key, selectAll }
        var kind: Kind
        var clicks = 0
        var dragged = false
        var shift = false
        var down: CGPoint = .zero
    }

    /// 最後に自動コピーした内容。置き換え貼り付けの保護と、同じ選択を何度もコピーしないために使う。
    private struct LastCopy {
        let text: String
        let pid: pid_t
        let changeCount: Int
        /// 自動コピーで書き換える前のクリップボードの中身
        let previous: [[(NSPasteboard.PasteboardType, Data)]]
    }

    let settings: AutoCopySettings
    let learner: ClickGapLearner
    private(set) var phase: Phase = .idle

    private var gesture: Gesture?
    private var lastUp: (time: TimeInterval, point: CGPoint)?
    private var waitWork: DispatchWorkItem?
    private var monitor: Any?
    private var activationObserver: NSObjectProtocol?
    private var keepWarmTimer: Timer?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var lastCopy: LastCopy?
    /// 自動コピーのあとに、クリックやキー入力があったか（あれば、選択はもう変わっているかもしれない）
    private var touchedSinceCopy = false
    private let popup = CopiedPopup()
    private let pasteboard = NSPasteboard.general

    /// 1 件の大きさの上限。クリップボード履歴と同じ 10 MB。
    static let maxBytes = 10 * 1024 * 1024
    private static let clickRadius: CGFloat = 6
    /// Chrome などが Accessibility の情報を作り終えるのを待って読み直す間隔（秒）
    private static let retryDelays: [Double] = [0.4, 0.8, 1.5, 3.0]
    private static let dragThreshold: CGFloat = 4
    private static let navigationKeys: Set<Int> = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                                                   kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown]

    init(settings: AutoCopySettings, learner: ClickGapLearner) {
        self.settings = settings
        self.learner = learner
    }

    // MARK: 開始・停止

    func start() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved,
                                           .scrollWheel, .keyDown, .flagsChanged]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        installPasteTapIfPossible()
        // Chrome・Electron は、前面に来たときに Accessibility を有効にしておく
        if let app = NSWorkspace.shared.frontmostApplication { SelectionReader.prepare(app) }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { SelectionReader.prepare(app) }
        }
        // しばらく問い合わせがあるとツリーをたたんでしまうので、前面のアプリを周期的に触る
        let keepWarm = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            guard self != nil, let app = NSWorkspace.shared.frontmostApplication else { return }
            MainActor.assumeIsolated { SelectionReader.prepare(app) }
        }
        RunLoop.main.add(keepWarm, forMode: .common)
        keepWarmTimer = keepWarm
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        keepWarmTimer?.invalidate()
        keepWarmTimer = nil
        removePasteTap()
        waitWork?.cancel()
        popup.hide()
        gesture = nil
        lastCopy = nil
        phase = .idle
    }

    /// 待つ時間（W）。上限はシステムの「ダブルクリックの間隔」。
    var waitSeconds: Double {
        let ms = settings.waitMode == .auto ? learner.currentMs : min(settings.manualWaitMs, ClickGapLearner.systemMaxMs)
        return Double(ms) / 1000
    }

    // MARK: 入力

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown: mouseDown(event)
        case .leftMouseDragged:
            if phase == .selecting, var g = gesture, g.kind == .mouse, !g.dragged,
               distance(NSEvent.mouseLocation, g.down) > Self.dragThreshold {
                g.dragged = true
                gesture = g
            }
        case .leftMouseUp: mouseUp(event)
        case .mouseMoved:
            // ダブルクリックのあと、マウスを動かしたら、待たずに確定する
            if phase == .awaiting, let up = lastUp, distance(NSEvent.mouseLocation, up.point) > Self.clickRadius { decide() }
        case .scrollWheel:
            if phase == .awaiting { decide() }
        case .keyDown: keyDown(event)
        case .flagsChanged:
            if phase == .selecting, gesture?.kind == .key, !event.modifierFlags.contains(.shift) { decide(after: 0.06) }
        default: break
        }
    }

    private func mouseDown(_ event: NSEvent) {
        touchedSinceCopy = true
        popup.hide()
        installPasteTapIfPossible() // 許可があとから出た場合に備える
        let point = NSEvent.mouseLocation, now = ProcessInfo.processInfo.systemUptime
        // W 以内に、同じ場所で次のクリック：マルチクリックの続き
        if phase == .awaiting, let up = lastUp, var g = gesture,
           now - up.time <= waitSeconds, distance(point, up.point) <= Self.clickRadius {
            waitWork?.cancel()
            learner.record(gap: now - up.time, afterClick: g.clicks)
            g.down = point
            gesture = g
            phase = .selecting
            return
        }
        // 別の操作が始まった。前の操作は、確定させずに捨てる（選択はもう変わっているかもしれないため）
        waitWork?.cancel()
        gesture = Gesture(kind: .mouse, clicks: event.clickCount, shift: event.modifierFlags.contains(.shift), down: point)
        phase = .selecting
    }

    private func mouseUp(_ event: NSEvent) {
        guard phase == .selecting, var g = gesture, g.kind == .mouse else { return }
        g.clicks = max(g.clicks + (g.clicks == 0 ? 1 : 0), event.clickCount)
        gesture = g
        lastUp = (ProcessInfo.processInfo.systemUptime, NSEvent.mouseLocation)
        if g.dragged || g.clicks >= 3 {
            decide()
            return
        }
        phase = .awaiting
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.decide() } }
        waitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + waitSeconds, execute: work)
    }

    private func keyDown(_ event: NSEvent) {
        let code = Int(event.keyCode)
        let flags = event.modifierFlags.intersection(Shortcut.relevantModifiers)
        let isPaste = code == kVK_ANSI_V && flags == .command
        if !isPaste { touchedSinceCopy = true }
        if phase == .awaiting { decide() }
        if code == kVK_ANSI_A && flags == .command {
            if settings.selectAllCopies {
                popup.hide()
                gesture = Gesture(kind: .selectAll)
                phase = .selecting
                decide(after: 0.12)
            }
            return
        }
        guard settings.keyboardSelection else { return }
        if flags.contains(.shift), Self.navigationKeys.contains(code), !(phase == .selecting && gesture?.kind == .key) {
            popup.hide()
            gesture = Gesture(kind: .key)
            phase = .selecting
        }
    }

    // MARK: 確定・判定

    private func decide(after delay: Double = 0) {
        waitWork?.cancel()
        guard let g = gesture else { phase = .idle; return }
        gesture = nil
        phase = .deciding
        // 選択がアプリに反映されるのを少し待ってから読む
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.03) { [weak self] in
            MainActor.assumeIsolated { self?.finish(g) }
        }
    }

    private func finish(_ g: Gesture, attempt: Int = 0) {
        defer { if phase == .deciding { phase = .idle } }
        let intended = g.kind != .mouse || g.dragged || g.clicks >= 2 || g.shift
        guard intended, AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !PrivacySettings.shared.isSensitive(app.bundleIdentifier),
              !settings.excludedBundleIDs.contains(app.bundleIdentifier ?? "") else { return }
        let selection: SelectionReader.Selection
        switch SelectionReader.read(pid: app.processIdentifier) {
        case .selection(let s) where !s.isSecure: selection = s
        case .notReady where attempt < Self.retryDelays.count:
            // アプリが Accessibility の情報を作り終えるのを待って、読み直す（選択はそのまま残っている）
            let pid = app.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
                MainActor.assumeIsolated {
                    // 待つ間に、ほかの操作が始まっていたらやめる
                    guard let self, self.phase == .idle, self.gesture == nil,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    self.phase = .deciding
                    self.finish(g, attempt: attempt + 1)
                }
            }
            return
        case .blockedByEditContext:
            // VS Code など。読み取りの失敗を繰り返すより、直しかたを一度だけ知らせる
            EditContextGuide.showOnce(for: app)
            return
        default: return
        }
        let text = selection.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= Self.maxBytes else { return }
        // 直前に自動コピーしたものと、同じアプリの同じ選択なら、もう一度はコピーしない
        if let last = lastCopy, last.text == text, last.pid == app.processIdentifier,
           pasteboard.changeCount == last.changeCount { return }

        let previous = snapshotPasteboard()
        // 自動コピーは、この Mac だけ（ユニバーサルクリップボードでほかの端末に送らない）
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        lastCopy = LastCopy(text: text, pid: app.processIdentifier, changeCount: pasteboard.changeCount, previous: previous)
        touchedSinceCopy = false
        phase = .copied
        if settings.showPopup { popup.show(at: selection.rect, duration: settings.popupSeconds) }
        DispatchQueue.main.asyncAfter(deadline: .now() + settings.popupSeconds) { [weak self] in
            MainActor.assumeIsolated { if self?.phase == .copied { self?.phase = .idle } }
        }
    }

    private func snapshotPasteboard() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                // 「あとでファイルを渡す」約束の型は、書き戻すと貼り付けに失敗するので控えない
                let raw = type.rawValue
                guard !raw.contains("promised"), !raw.contains("NSPromise"), !raw.contains("FilePromise"),
                      let data = item.data(forType: type) else { return nil }
                return (type, data)
            }
        }
    }

    // MARK: 置き換え貼り付けの保護

    /// ⌘V がアプリに届く直前に呼ばれる。
    /// 自動コピーした範囲を選んだまま ⌘V した（＝その範囲を置き換えたい）なら、自動コピーの前の内容に戻しておく。
    fileprivate func pasteWillHappen() {
        guard settings.protectPaste, let last = lastCopy, !touchedSinceCopy,
              pasteboard.changeCount == last.changeCount,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == last.pid,
              !last.previous.isEmpty else { return }
        pasteboard.clearContents()
        let items = last.previous.map { reps -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in reps { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
        lastCopy = nil
    }

    private func installPasteTapIfPossible() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: autoCopyPasteTap, userInfo: refcon) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    private func removePasteTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    fileprivate func reenablePasteTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// ⌘V を、アプリに届く前に見るためのイベントタップ。見るだけで、キーの中身は記録しない。
private nonisolated func autoCopyPasteTap(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                          refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated { Unmanaged<AutoCopyEngine>.fromOpaque(refcon).takeUnretainedValue().reenablePasteTap() }
        return Unmanaged.passUnretained(event)
    }
    if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_V) {
        let flags = event.flags
        if flags.contains(.maskCommand), !flags.contains(.maskShift), !flags.contains(.maskAlternate), !flags.contains(.maskControl) {
            MainActor.assumeIsolated { Unmanaged<AutoCopyEngine>.fromOpaque(refcon).takeUnretainedValue().pasteWillHappen() }
        }
    }
    return Unmanaged.passUnretained(event)
}
