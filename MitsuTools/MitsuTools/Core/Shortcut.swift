import AppKit
import Carbon.HIToolbox

/// キーコードと修飾キーの組み合わせ。
nonisolated struct Shortcut: Codable, Hashable, Sendable {
    var keyCode: UInt32
    /// NSEvent.ModifierFlags の rawValue（⌃⌥⇧⌘ のみ）。
    var modifiers: UInt

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers.intersection(Shortcut.relevantModifiers).rawValue
    }

    static let relevantModifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        let flags = modifierFlags
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// macOS の表記順（⌃⌥⇧⌘）で表した文字列。例: "⇧⌘V"
    var displayString: String {
        Shortcut.modifierSymbols(modifierFlags) + Shortcut.keyName(for: keyCode)
    }

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let name = specialKeyNames[Int(keyCode)] { return name }
        return translatedKeyName(keyCode) ?? "#\(keyCode)"
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "Space",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// 現在のキーボード配列でキーコードを文字に変換する。
    private static func translatedKeyName(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).uppercased()
        }
    }
}

// MARK: - 設定ファイル用の文字列表現（例: "ctrl+opt+left"、"shift+cmd+v"）

extension Shortcut {
    private static let modifierNames: [(String, NSEvent.ModifierFlags)] = [
        ("ctrl", .control), ("opt", .option), ("shift", .shift), ("cmd", .command),
    ]
    private static let modifierAliases: [String: NSEvent.ModifierFlags] = [
        "ctrl": .control, "control": .control, "opt": .option, "option": .option, "alt": .option,
        "shift": .shift, "cmd": .command, "command": .command,
    ]

    private static let configKeyNames: [Int: String] = {
        var map: [Int: String] = [
            kVK_LeftArrow: "left", kVK_RightArrow: "right", kVK_UpArrow: "up", kVK_DownArrow: "down",
            kVK_Return: "return", kVK_ANSI_KeypadEnter: "enter", kVK_Tab: "tab", kVK_Space: "space",
            kVK_Delete: "delete", kVK_ForwardDelete: "forwarddelete", kVK_Escape: "escape",
            kVK_Home: "home", kVK_End: "end", kVK_PageUp: "pageup", kVK_PageDown: "pagedown",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        ]
        let letters: [(String, Int)] = [
            ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E),
            ("f", kVK_ANSI_F), ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J),
            ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O),
            ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R), ("s", kVK_ANSI_S), ("t", kVK_ANSI_T),
            ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X), ("y", kVK_ANSI_Y),
            ("z", kVK_ANSI_Z), ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3),
            ("4", kVK_ANSI_4), ("5", kVK_ANSI_5), ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8),
            ("9", kVK_ANSI_9),
            ("f1", kVK_F1), ("f2", kVK_F2), ("f3", kVK_F3), ("f4", kVK_F4), ("f5", kVK_F5), ("f6", kVK_F6),
            ("f7", kVK_F7), ("f8", kVK_F8), ("f9", kVK_F9), ("f10", kVK_F10), ("f11", kVK_F11), ("f12", kVK_F12),
        ]
        for (name, code) in letters { map[code] = name }
        return map
    }()

    private static let configKeyCodes: [String: Int] =
        Dictionary(configKeyNames.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            .merging(["esc": kVK_Escape, "backspace": kVK_Delete, "arrowleft": kVK_LeftArrow, "arrowright": kVK_RightArrow,
                      "arrowup": kVK_UpArrow, "arrowdown": kVK_DownArrow, "plus": kVK_ANSI_Equal]) { a, _ in a }

    var configString: String {
        let mods = Self.modifierNames.filter { modifierFlags.contains($0.1) }.map(\.0)
        let key = Self.configKeyNames[Int(keyCode)] ?? "keycode:\(keyCode)"
        return (mods + [key]).joined(separator: "+")
    }

    /// "ctrl+opt+left" のような文字列から作る。読めなければ nil。
    init?(configString: String) {
        // 最後の要素はキー（"+" 自体をキーにする場合に備え、末尾の "+" は "plus" とみなす）。
        var text = configString.lowercased().replacingOccurrences(of: " ", with: "")
        if text.hasSuffix("++") { text = String(text.dropLast()) + "plus" }
        var parts = text.split(separator: "+").map(String.init)
        guard let keyName = parts.popLast() else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            guard let flag = Self.modifierAliases[part] else { return nil }
            flags.insert(flag)
        }
        let code: Int
        if keyName.hasPrefix("keycode:"), let n = Int(keyName.dropFirst(8)) {
            code = n
        } else if let c = Self.configKeyCodes[keyName] {
            code = c
        } else {
            return nil
        }
        self.init(keyCode: code, modifiers: flags)
    }
}

extension Shortcut {
    static func ctrlOpt(_ key: Int) -> Shortcut { Shortcut(keyCode: key, modifiers: [.control, .option]) }
    static func ctrlOptShift(_ key: Int) -> Shortcut { Shortcut(keyCode: key, modifiers: [.control, .option, .shift]) }
    static func ctrlOptCmd(_ key: Int) -> Shortcut { Shortcut(keyCode: key, modifiers: [.control, .option, .command]) }

    static let digitKeyCodes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
}

// MARK: - メニューの右側に出すための形

import SwiftUI

extension Shortcut {
    /// メニュー項目の右側に表示するための SwiftUI の形。表せないキーなら nil。
    var menuShortcut: KeyboardShortcut? {
        let key: KeyEquivalent
        switch Int(keyCode) {
        case kVK_LeftArrow: key = .leftArrow
        case kVK_RightArrow: key = .rightArrow
        case kVK_UpArrow: key = .upArrow
        case kVK_DownArrow: key = .downArrow
        case kVK_Return, kVK_ANSI_KeypadEnter: key = .return
        case kVK_Space: key = .space
        case kVK_Tab: key = .tab
        case kVK_Escape: key = .escape
        case kVK_Delete: key = .delete
        default:
            let name = configString.split(separator: "+").last.map(String.init) ?? ""
            guard name.count == 1, let character = name.first else { return nil }
            key = KeyEquivalent(character)
        }
        var modifiers: SwiftUI.EventModifiers = []
        let flags = modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(key, modifiers: modifiers)
    }
}
