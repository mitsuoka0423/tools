import Carbon.HIToolbox

/// キーボードの入力方式（入力ソース）1 つ。例: 「ABC」「ひらがな」
nonisolated struct InputSource: Identifiable, Hashable, Sendable {
    /// 例: com.apple.keylayout.ABC
    let id: String
    let name: String
}

/// 入力方式の一覧の取得と切り替え。Apple の Text Input Sources（TIS）を使う。
nonisolated enum InputSourceManager {
    /// 使える状態になっている（システム設定の「入力ソース」に追加されている）入力方式。
    static func available() -> [InputSource] {
        sources(matching: nil).compactMap { source in
            guard isSelectable(source), let id = string(source, kTISPropertyInputSourceID),
                  let name = string(source, kTISPropertyLocalizedName) else { return nil }
            return InputSource(id: id, name: name)
        }
    }

    /// いま使っている入力方式の ID
    static func currentID() -> String? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return string(current, kTISPropertyInputSourceID)
    }

    /// 入力方式を切り替える。すでにそれなら何もしない。切り替えられたら true。
    @discardableResult
    static func select(id: String) -> Bool {
        if currentID() == id { return true }
        guard let source = sources(matching: [kTISPropertyInputSourceID as String: id]).first else { return false }
        return TISSelectInputSource(source) == noErr
    }

    // MARK: 内部

    private static func sources(matching filter: [String: Any]?) -> [TISInputSource] {
        let list = TISCreateInputSourceList(filter as CFDictionary?, false)?.takeRetainedValue()
        return (list as? [TISInputSource]) ?? []
    }

    /// 文字入力に使う入力方式だけ（絵文字パレットなどは除く）
    private static func isSelectable(_ source: TISInputSource) -> Bool {
        guard bool(source, kTISPropertyInputSourceIsSelectCapable) else { return false }
        return string(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String)
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? String
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
        return (Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? Bool) ?? false
    }
}
