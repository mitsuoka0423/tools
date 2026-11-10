import AppKit
import Carbon.HIToolbox
import Observation

/// グローバルショートカットの登録・保存・呼び出しをまとめて扱う。
/// Carbon の RegisterEventHotKey を使う（Accessibility 権限なしで動く）。
@MainActor
@Observable
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// 登録済みの操作（設定画面の一覧・重複チェックに使う）。
    private(set) var actions: [String: ShortcutAction] = [:]
    /// 現在の割り当て。nil は「なし」。
    private(set) var bindings: [String: Shortcut?] = [:]

    /// ショートカット入力中は全ホットキーを止める。
    var isSuspended = false {
        didSet { if oldValue != isSuspended { reregisterAll() } }
    }

    @ObservationIgnored private var registered: [String: (ref: EventHotKeyRef, number: UInt32)] = [:]
    @ObservationIgnored private var numberToAction: [UInt32: String] = [:]
    @ObservationIgnored private var nextNumber: UInt32 = 1
    @ObservationIgnored private var handlerInstalled = false
    private static let signature: OSType = 0x4D545453 // 'MTTS'

    private init() {}

    // MARK: 登録

    func register(_ action: ShortcutAction) {
        actions[action.id] = action
        bindings[action.id] = loadBinding(for: action)
        apply(action.id)
    }

    func unregister(actionID: String) {
        removeHotKey(actionID)
        actions[actionID] = nil
        bindings[actionID] = nil
    }

    func shortcut(for actionID: String) -> Shortcut? { bindings[actionID] ?? nil }

    func setShortcut(_ shortcut: Shortcut?, for actionID: String) {
        bindings[actionID] = .some(shortcut)
        let key = Self.defaultsKey(actionID)
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.set(Data(), forKey: key) // 空データ = 割り当てなし
        }
        apply(actionID)
    }

    func resetToDefault(_ actionID: String) {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey(actionID))
        if let action = actions[actionID] {
            bindings[actionID] = action.defaultShortcut
            apply(actionID)
        }
    }

    /// 同じショートカットを使っている別の操作。
    func conflict(for shortcut: Shortcut, excluding actionID: String) -> ShortcutAction? {
        for (id, bound) in bindings where id != actionID && bound == shortcut {
            return actions[id]
        }
        return nil
    }

    // MARK: 内部

    private static func defaultsKey(_ id: String) -> String { "shortcut.\(id)" }

    /// 保存されている割り当て（モジュールが無効で未登録の操作にも使える）。
    func storedShortcut(for action: ShortcutAction) -> Shortcut? {
        if actions[action.id] != nil { return shortcut(for: action.id) }
        return loadBinding(for: action)
    }

    /// 設定ファイルから割り当てを反映する。モジュールが無効なら保存だけ行う。
    func importShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        guard storedShortcut(for: action) != shortcut else { return }
        if actions[action.id] != nil {
            setShortcut(shortcut, for: action.id)
        } else if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey(action.id))
        } else {
            UserDefaults.standard.set(Data(), forKey: Self.defaultsKey(action.id))
        }
    }

    private func loadBinding(for action: ShortcutAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey(action.id)) else {
            return action.defaultShortcut
        }
        if data.isEmpty { return nil }
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? action.defaultShortcut
    }

    private func apply(_ actionID: String) {
        removeHotKey(actionID)
        guard !isSuspended, actions[actionID] != nil, let shortcut = shortcut(for: actionID) else { return }
        installHandlerIfNeeded()
        let number = nextNumber
        nextNumber += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: number)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("MitsuTools: ショートカット \(shortcut.displayString) を登録できませんでした (\(status))")
            return
        }
        registered[actionID] = (ref, number)
        numberToAction[number] = actionID
    }

    private func removeHotKey(_ actionID: String) {
        guard let entry = registered.removeValue(forKey: actionID) else { return }
        UnregisterEventHotKey(entry.ref)
        numberToAction[entry.number] = nil
    }

    private func reregisterAll() {
        for id in actions.keys { apply(id) }
    }

    fileprivate func fire(number: UInt32) {
        guard let id = numberToAction[number], let action = actions[id] else { return }
        action.handler()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let number = hotKeyID.id
            MainActor.assumeIsolated { HotKeyCenter.shared.fire(number: number) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
