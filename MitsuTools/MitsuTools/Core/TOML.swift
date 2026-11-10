import Foundation

/// 設定ファイル用の、TOML の小さなサブセット。
/// 対応: コメント、[テーブル]、キー（裸 / "引用符"）、文字列、整数、小数、真偽値、配列（複数行可）。
nonisolated enum TOMLValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([TOMLValue])

    var string: String? { if case let .string(v) = self { v } else { nil } }
    var bool: Bool? { if case let .bool(v) = self { v } else { nil } }
    var int: Int? {
        switch self {
        case let .int(v): v
        case let .double(v): Int(v)
        default: nil
        }
    }
    var double: Double? {
        switch self {
        case let .int(v): Double(v)
        case let .double(v): v
        default: nil
        }
    }
    var stringArray: [String]? {
        guard case let .array(values) = self else { return nil }
        return values.compactMap(\.string)
    }
}

typealias TOMLTable = [String: TOMLValue]

nonisolated struct TOMLError: Error, LocalizedError {
    let line: Int
    let message: String
    var errorDescription: String? { "\(line) 行目: \(message)" }
}

nonisolated enum TOML {
    /// テーブル名 → (キー → 値)。テーブルの外のキーは "" に入る。
    static func parse(_ text: String) throws -> [String: TOMLTable] {
        var result: [String: TOMLTable] = ["": [:]]
        var current = ""
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let lineNumber = i + 1
            var line = stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            i += 1
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]"), !line.hasPrefix("[[") else {
                    throw TOMLError(line: lineNumber, message: "テーブルの書き方が正しくありません")
                }
                current = unquote(String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces))
                result[current, default: [:]] = result[current] ?? [:]
                continue
            }

            // 複数行の配列は ] が閉じるまで続けて読む。
            while bracketDepth(line) > 0, i < lines.count {
                line += " " + stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
                i += 1
            }

            guard let eq = indexOfEquals(line) else {
                throw TOMLError(line: lineNumber, message: "「キー = 値」の形になっていません")
            }
            let key = unquote(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            var scanner = Scanner(String(line[line.index(after: eq)...]))
            guard let value = try scanner.parseValue(line: lineNumber) else {
                throw TOMLError(line: lineNumber, message: "値が読めません")
            }
            scanner.skipSpaces()
            guard scanner.isAtEnd else {
                throw TOMLError(line: lineNumber, message: "値のあとに余分な文字があります")
            }
            result[current, default: [:]][key] = value
        }
        return result
    }

    // MARK: 書き出し

    static func key(_ key: String) -> String {
        key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } && key.allSatisfy(\.isASCII)
            ? key : quote(key)
    }

    static func value(_ value: TOMLValue) -> String {
        switch value {
        case let .string(s): quote(s)
        case let .int(v): String(v)
        case let .double(v): v.rounded() == v ? String(Int(v)) : String(v)
        case let .bool(v): v ? "true" : "false"
        case let .array(values): "[" + values.map(Self.value).joined(separator: ", ") + "]"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    // MARK: 内部

    private static func unquote(_ s: String) -> String {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            var scanner = Scanner(s)
            if let value = try? scanner.parseValue(line: 0), case let .string(str) = value { return str }
        }
        return s
    }

    /// 文字列の外にある # 以降を取り除く。
    private static func stripComment(_ line: String) -> String {
        var inString = false, escaped = false
        for (offset, ch) in line.enumerated() {
            if escaped { escaped = false; continue }
            if ch == "\\" && inString { escaped = true; continue }
            if ch == "\"" { inString.toggle() }
            if ch == "#" && !inString { return String(line.prefix(offset)) }
        }
        return line
    }

    private static func bracketDepth(_ line: String) -> Int {
        var depth = 0, inString = false, escaped = false
        guard let eq = indexOfEquals(line) else { return 0 }
        for ch in line[line.index(after: eq)...] {
            if escaped { escaped = false; continue }
            if ch == "\\" && inString { escaped = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1 }
        }
        return depth
    }

    private static func indexOfEquals(_ line: String) -> String.Index? {
        var inString = false
        var index = line.startIndex
        while index < line.endIndex {
            let ch = line[index]
            if ch == "\"" { inString.toggle() }
            if ch == "=" && !inString { return index }
            index = line.index(after: index)
        }
        return nil
    }

    private struct Scanner {
        let chars: [Character]
        var pos = 0
        init(_ s: String) { chars = Array(s) }

        var isAtEnd: Bool { pos >= chars.count }

        mutating func skipSpaces() {
            while pos < chars.count, chars[pos] == " " || chars[pos] == "\t" { pos += 1 }
        }

        mutating func parseValue(line: Int) throws -> TOMLValue? {
            skipSpaces()
            guard pos < chars.count else { return nil }
            let ch = chars[pos]
            if ch == "\"" { return .string(try parseString(line: line)) }
            if ch == "[" { return try parseArray(line: line) }
            var token = ""
            while pos < chars.count, !",] \t".contains(chars[pos]) { token.append(chars[pos]); pos += 1 }
            switch token {
            case "true": return .bool(true)
            case "false": return .bool(false)
            default:
                let cleaned = token.replacingOccurrences(of: "_", with: "")
                if let v = Int(cleaned) { return .int(v) }
                if let v = Double(cleaned) { return .double(v) }
                throw TOMLError(line: line, message: "「\(token)」は値として読めません（文字列は \"…\" で囲んでください）")
            }
        }

        private mutating func parseString(line: Int) throws -> String {
            pos += 1 // 開きの "
            var out = ""
            while pos < chars.count {
                let ch = chars[pos]
                pos += 1
                if ch == "\"" { return out }
                if ch == "\\", pos < chars.count {
                    let next = chars[pos]
                    pos += 1
                    switch next {
                    case "n": out += "\n"
                    case "t": out += "\t"
                    case "\"": out += "\""
                    case "\\": out += "\\"
                    default: out.append(next)
                    }
                } else {
                    out.append(ch)
                }
            }
            throw TOMLError(line: line, message: "文字列が \" で閉じられていません")
        }

        private mutating func parseArray(line: Int) throws -> TOMLValue {
            pos += 1 // [
            var values: [TOMLValue] = []
            while true {
                skipSpaces()
                guard pos < chars.count else { throw TOMLError(line: line, message: "配列が ] で閉じられていません") }
                if chars[pos] == "]" { pos += 1; return .array(values) }
                guard let value = try parseValue(line: line) else {
                    throw TOMLError(line: line, message: "配列の値が読めません")
                }
                values.append(value)
                skipSpaces()
                if pos < chars.count, chars[pos] == "," { pos += 1 }
            }
        }
    }
}
