import Foundation

/// VS Code 系のエディタの設定ファイル（settings.json）を読み書きする。
///
/// 自動コピーが VS Code で動くようにするには、アプリ側に 2 つの設定が要る（2026-11 実測）:
/// - editor.editContext: false … 入力欄を従来の textarea に戻す（EditContext の中身は
///   macOS のアクセシビリティに一切出ない）
/// - editor.accessibilitySupport: "on" … エディタに「支援技術を使っている」と教えて、
///   選んだ文字を textarea 側に写させる（auto だと、外部からの有効化では写さない）
/// 両方そろって、選んだ文字が AXSelectedText に出てくる。書き込み後はウィンドウの
/// 開き直しが必要（設定は読めるようになるが、mirroring が再評価されない）。
///
/// settings.json はコメントと書き込み順を自由に使える JSONC なので、
/// JSON として読み直して全体を書き換えるとコメントや並びが失われる。
/// 対象のキー（と差し替えの範囲）だけを探して、そこに文字として書き込む方式にする。
enum EditContextSettings {

    /// 自動コピーの目的で見た状態。ready = 必要な設定がそろっている。
    enum Status: Equatable { case ready, needsSettings }

    enum WriteResult: Equatable {
        /// 足りない設定を書き込んだ（または値を直した）
        case configured(file: String)
        /// もう全部そろっていた
        case alreadyConfigured(file: String)
        /// JSON の形が特殊で、書き込み先を安全に決められず触らなかった
        case unparseable(file: String)
        /// ファイルが読めない・書けない
        case failed(file: String)
    }

    /// 要求する設定 1 件
    struct Requirement {
        let key: String
        /// 書き込む値（JSON のリテラルそのまま。"on" のように引用符ごと）
        let want: String
        /// これらの値（小文字化し引用符を取ったもの）なら「設定済み」とみなす
        let accepted: Set<String>
    }

    static let requirements: [Requirement] = [
        Requirement(key: "editor.editContext", want: "false", accepted: ["false", "off", "disabled", "never"]),
        Requirement(key: "editor.accessibilitySupport", want: "\"on\"", accepted: ["on", "true"]),
    ]

    // MARK: 読み

    static func status(at url: URL) -> Status {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return .needsSettings }
        return missingRequirements(in: Array(raw)).isEmpty ? .ready : .needsSettings
    }

    // MARK: 書き

    /// 足りない設定を書き足す（または値を直する）
    @discardableResult
    static func configure(_ url: URL) -> WriteResult {
        let file = url.path
        var raw = ""
        if FileManager.default.fileExists(atPath: file) {
            guard let read = try? String(contentsOf: url, encoding: .utf8) else { return .failed(file: file) }
            raw = read
        }
        let chars = Array(raw)

        func emit(_ out: [Character]) -> WriteResult {
            write(String(out), to: url) ? .configured(file: file) : .failed(file: file)
        }

        // 中身が空、または {} だけのときは、つくり直してしまうのが一番ていねい
        if chars.isEmpty || raw.trimmingCharacters(in: .whitespacesAndNewlines) == "{}" {
            var body = "{\n"
            for r in requirements { body += "    \"\(r.key)\": \(r.want),\n" }
            body = String(body.dropLast(2)) + "\n}\n" // 最後の , を落とす
            return emit(Array(body))
        }

        let missing = missingRequirements(in: chars)
        if missing.isEmpty { return .alreadyConfigured(file: file) }

        // 置き換えは後ろの位置から（範囲がずれないように）、そのあとに未設定の書き足し
        var out = chars
        let replaces = missing.compactMap { item -> (Range<Int>, String)? in
            guard let replace = item.replace else { return nil }
            return (replace, item.requirement.want)
        }.sorted { $0.0.lowerBound > $1.0.lowerBound }
        for (range, text) in replaces { out.replaceSubrange(range, with: Array(text)) }

        let inserts = missing.filter { $0.replace == nil }.map { "    \"\($0.requirement.key)\": \($0.requirement.want),\n" }
        if !inserts.isEmpty {
            guard let open = firstBrace(out) else { return .unparseable(file: file) }
            let head = String(out[...open]) // { を含む
            let tail = String(out[(open + 1)...])
            var body = "\n" + inserts.joined()
            if nextCode(out, from: open + 1) == "}" { // 空のオブジェクトだった：末尾カンマを落とす
                body.removeLast(2)
                out = Array(head + body + "\n" + tail)
            } else {
                out = Array(head + body + tail)
            }
        }
        return emit(out)
    }

    private static func write(_ text: String, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: JSONC をまたぐ探査

    struct Finding {
        let requirement: Requirement
        /// 値の本体の範囲（置き換えに使う）。nil = キーが見当たらない
        let replace: Range<Int>?
        /// 値が「設定済み」のどれかに合っているか
        let satisfied: Bool
    }

    /// 要件のうち、まだ満たしていないものを数える
    private static func missingRequirements(in chars: [Character]) -> [Finding] {
        var found: [String: (range: Range<Int>?, satisfied: Bool)] = [:]
        let n = chars.count
        var i = 0
        while i < n {
            let c = chars[i]
            if c == "/" {
                let after = skipJunk(chars, from: i)
                if after == i { i += 1 } else { i = after }
                continue
            }
            guard c == "\"" else { i += 1; continue }
            let token = readString(chars, open: i)
            i = token.end
            guard let req = requirements.first(where: { $0.key == token.content }), found[req.key] == nil else { continue }
            var after = skipJunk(chars, from: i)
            guard after < n, chars[after] == ":" else { continue } // キーではなく値側の文字列
            after = skipJunk(chars, from: after + 1)
            guard after < n else { found[req.key] = (after..<after, false); continue }
            if chars[after] == "\"" {
                let v = readString(chars, open: after)
                // 文字列値（"auto" など）は引用符ごと置き換えるので、want 側の引用符と二重にならない
                found[req.key] = (after..<v.end, req.accepted.contains(v.content.lowercased()))
            } else if chars[after].isLetter {
                var end = after
                while end < n, chars[end].isLetter { end += 1 }
                found[req.key] = (after..<end, req.accepted.contains(String(chars[after..<end]).lowercased()))
            } else {
                found[req.key] = (after..<after, false) // 数など、合致する形ではない
            }
        }
        return requirements.compactMap { req -> Finding? in
            let hit = found[req.key]
            if hit?.satisfied == true { return nil }
            return Finding(requirement: req, replace: hit?.range, satisfied: false)
        }
    }

    /// 文字列トークン。open は開始 " の位置。end は終了 " の次、contentEnd は終了 " の位置。
    private static func readString(_ chars: [Character], open: Int) -> (content: String, contentEnd: Int, end: Int) {
        var i = open + 1
        var content = ""
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count { content.append(chars[i + 1]); i += 2; continue }
            if chars[i] == "\"" { return (content, i, i + 1) }
            content.append(chars[i]); i += 1
        }
        return (content, i, i) // 閉じられていない壊れた文字列
    }

    /// 空白とコメント（// と /* */）を飛ばした次の本体の位置
    private static func skipJunk(_ chars: [Character], from start: Int) -> Int {
        var i = start
        let n = chars.count
        while i < n {
            if chars[i].isWhitespace { i += 1; continue }
            if chars[i] == "/", i + 1 < n, chars[i + 1] == "/" {
                i += 2
                while i < n, chars[i] != "\n" { i += 1 }
                continue
            }
            if chars[i] == "/", i + 1 < n, chars[i + 1] == "*" {
                i += 2
                while i + 1 < n, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            break
        }
        return i
    }

    /// 文字列とコメントの外にある、最初の {（本体の開始）
    private static func firstBrace(_ chars: [Character]) -> Int? {
        var i = 0
        let n = chars.count
        while i < n {
            switch chars[i] {
            case "\"": i = readString(chars, open: i).end
            case "/":
                let after = skipJunk(chars, from: i)
                if after == i { i += 1 } else { i = after }
            case "{": return i
            default: i += 1
            }
        }
        return nil
    }

    private static func nextCode(_ chars: [Character], from start: Int) -> Character? {
        let i = skipJunk(chars, from: min(start, chars.count))
        return i < chars.count ? chars[i] : nil
    }
}
