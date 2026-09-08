import Foundation

/// Ordered, strict JSON transforms used by the complete native reducer.
enum CompleteJSON {
    static let legend = "Compact JSON: $packedTable contains columns and rows. Each row is one object; values match columns in order. All other JSON is unchanged.\n"
    static let declarationLegend = "$swiftDeclarations rows follow columns. Original kind and name fields are duplicated in each Swift signature; originalColumns records their original positions. Kind is the declaration keyword; name is its following identifier, or empty for init and non-identifier func names. No declaration text is omitted.\n"
    private struct Field: Equatable { let key: String; let value: Value }
    private indirect enum Value: Equatable {
        case object([Field]), array([Value]), string(String), integer(String), boolean(Bool), null
        var fields: [Field]? { if case let .object(v) = self { return v }; return nil }
        var items: [Value]? { if case let .array(v) = self { return v }; return nil }
        var string: String? { if case let .string(v) = self { return v }; return nil }
        subscript(_ key: String) -> Value? { fields?.first { $0.key.unicodeScalars.elementsEqual(key.unicodeScalars) }?.value }
    }
    private enum Invalid: Error { case json }
    private struct Parser {
        let bytes: [UInt8]; var i = 0
        mutating func whitespace() { while i < bytes.count && [9,10,13,32].contains(bytes[i]) { i += 1 } }
        mutating func take(_ b: UInt8) -> Bool { if i < bytes.count && bytes[i] == b { i += 1; return true }; return false }
        mutating func string() throws -> String {
            let start = i
            guard take(34) else { throw Invalid.json }
            var escape = false
            while i < bytes.count {
                let b = bytes[i]; i += 1
                if escape { escape = false; continue }
                if b == 92 { escape = true; continue }
                if b == 34 {
                    guard let value = try JSONSerialization.jsonObject(with: Data(bytes[start..<i]), options: [.fragmentsAllowed]) as? String else { throw Invalid.json }
                    return value
                }
            }
            throw Invalid.json
        }
        mutating func value(_ depth: Int = 0) throws -> Value {
            guard depth < 128 else { throw Invalid.json }; whitespace()
            guard i < bytes.count else { throw Invalid.json }
            if bytes[i] == 34 { return .string(try string()) }
            if take(123) {
                whitespace(); var fields: [Field] = []; var keys = Set<[UInt32]>()
                if take(125) { return .object(fields) }
                repeat {
                    whitespace(); let key = try string()
                    guard keys.insert(key.unicodeScalars.map(\.value)).inserted else { throw Invalid.json }
                    whitespace(); guard take(58) else { throw Invalid.json }
                    fields.append(Field(key: key, value: try value(depth + 1))); whitespace()
                    if take(125) { return .object(fields) }
                    guard take(44) else { throw Invalid.json }
                } while true
            }
            if take(91) {
                whitespace(); var values: [Value] = []
                if take(93) { return .array(values) }
                repeat {
                    values.append(try value(depth + 1)); whitespace()
                    if take(93) { return .array(values) }
                    guard take(44) else { throw Invalid.json }
                } while true
            }
            for (token, result) in [("true", Value.boolean(true)), ("false", .boolean(false)), ("null", .null)] {
                let literal = Array(token.utf8)
                if bytes[i...].starts(with: literal) { i += literal.count; return result }
            }
            let start = i; _ = take(45)
            guard i < bytes.count && (48...57).contains(bytes[i]) else { throw Invalid.json }
            if !take(48) { while i < bytes.count && (48...57).contains(bytes[i]) { i += 1 } }
            let number = String(decoding: bytes[start..<i], as: UTF8.self)
            guard number != "-0", number.filter({ $0 != "-" }).count <= 4300 else { throw Invalid.json }
            return .integer(number)
        }
    }
    private static func parse(_ source: String) throws -> Value {
        var parser = Parser(bytes: Array(source.utf8)); let value = try parser.value(); parser.whitespace()
        guard parser.i == parser.bytes.count else { throw Invalid.json }; return value
    }
    private static func quote(_ text: String) -> String {
        var out = "\""
        for s in text.unicodeScalars {
            switch s.value {
            case 34: out += "\\\""
            case 92: out += "\\\\"
            case 8: out += "\\b"
            case 9: out += "\\t"
            case 10: out += "\\n"
            case 12: out += "\\f"
            case 13: out += "\\r"
            case 0..<32: out += String(format: "\\u%04x", s.value)
            default: out.unicodeScalars.append(s)
            }
        }
        return out + "\""
    }
    private static func dump(_ v: Value) -> String {
        switch v {
        case let .object(fs): return "{" + fs.map { quote($0.key) + ":" + dump($0.value) }.joined(separator: ",") + "}"
        case let .array(vs): return "[" + vs.map(dump).joined(separator: ",") + "]"
        case let .string(s): return quote(s)
        case let .integer(n): return n
        case let .boolean(b): return b ? "true" : "false"
        case .null: return "null"
        }
    }
    private static func object(_ pairs: [(String, Value)]) -> Value { .object(pairs.map { Field(key: $0.0, value: $0.1) }) }
    private static func encode(_ value: Value) throws -> Value {
        switch value {
        case let .object(fs):
            guard value["$packedTable"] == nil else { throw Invalid.json }
            return .object(try fs.map { Field(key: $0.key, value: try encode($0.value)) })
        case let .array(vs):
            if vs.count >= 3, let first = vs[0].fields, !first.isEmpty,
               vs.allSatisfy({ $0.fields?.map { Array($0.key.unicodeScalars) } == first.map { Array($0.key.unicodeScalars) } }) {
                guard !first.contains(where: { $0.key == "$packedTable" }) else { throw Invalid.json }
                return object([("$packedTable", object([("columns", .array(first.map { .string($0.key) })),
                    ("rows", .array(try vs.map { .array(try $0.fields!.map { try encode($0.value) }) }))]))])
            }
            return .array(try vs.map(encode))
        default: return value
        }
    }
    private static func strip(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.drop(while: space).reversed().drop(while: space).reversed())) }
    private static func space(_ s: Unicode.Scalar) -> Bool { isPythonWhitespace(s) || (0x1c...0x1f).contains(s.value) }
    private static func lines(_ s: String) -> [String] {
        let a = Array(s.unicodeScalars); var result: [String] = []; var start = 0; var i = 0
        while i < a.count {
            if [10,11,12,13,28,29,30,133,8232,8233].contains(a[i].value) {
                if a[i].value == 13 && i + 1 < a.count && a[i+1].value == 10 { i += 1 }
                result.append(String(String.UnicodeScalarView(a[start...i]))); start = i + 1
            }; i += 1
        }
        if start < a.count { result.append(String(String.UnicodeScalarView(a[start...]))) }; return result
    }
    /// Preserve every recognized splitlines boundary, including CRLF as a pair.
    /// A removed non-LF terminator would join the JSON value to following prose.
    private static func ending(_ text: String) -> String {
        let suffix = Array(text.unicodeScalars.suffix(2))
        if suffix == ["\r", "\n"] { return "\r\n" }
        guard let last = suffix.last,
              [10,11,12,13,28,29,30,133,8232,8233].contains(last.value) else { return "" }
        return String(last)
    }
    private static func fence(_ line: String, pattern: String, state: inout String?) -> Bool {
        let pythonPattern = pattern.replacingOccurrences(of: #"\s"#, with: #"[\s\x{001c}-\x{001f}]"#)
        guard let range = line.range(of: pythonPattern, options: .regularExpression) else { return false }
        let token = String(line[range]).filter { $0 == "`" || $0 == "~" }
        if let previous = state {
            if token.first == previous.first && token.count >= previous.count && strip(String(line[range.upperBound...])).isEmpty { state = nil }
        } else { state = token }; return true
    }
    static func tables(_ source: String, count: (String) -> Int) -> String {
        var state: String?; var out = ""
        for line in lines(source) {
            if fence(line, pattern: #"^\s*(`{3,}|~{3,})"#, state: &state) || state != nil { out += line; continue }
            let text = strip(line)
            if (text.hasPrefix("{") || text.hasPrefix("[")), let value = try? parse(text), let encoded = try? encode(value), encoded != value {
                out += legend + dump(encoded) + ending(line)
            } else { out += line }
        }
        return count(out) < count(source) ? out : source
    }
    static func blocks(_ source: String, count: (String) -> Int) -> String {
        let ls = lines(source); var out = ""; var state: String?; var i = 0
        while i < ls.count {
            let line = ls[i]; let marked = fence(line, pattern: #"^\s{0,3}(`{3,}|~{3,})"#, state: &state)
            let stripped = String(line.drop(while: { $0 == " " || $0 == "\t" }))
            if marked || state != nil || !(stripped.hasPrefix("{") || stripped.hasPrefix("[")) { out += line; i += 1; continue }
            var stack: [Unicode.Scalar] = []; var quoted = false; var escaped = false; var end: String.Index?; var original = ""; var malformed = false
            var j = i
            while j < ls.count && end == nil && !malformed {
                let base = original.endIndex; original += ls[j]
                var p = j == i ? original.unicodeScalars.index(original.startIndex, offsetBy: line.unicodeScalars.count - stripped.unicodeScalars.count) : base
                while p < original.endIndex {
                    let c = original.unicodeScalars[p]; let next = original.unicodeScalars.index(after: p)
                    if quoted { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false } }
                    else if c == "\"" { quoted = true }
                    else if c == "{" || c == "[" { stack.append(c) }
                    else if c == "}" || c == "]" {
                        if stack.popLast() != (c == "}" ? "{" : "[") { malformed = true; break }
                        if stack.isEmpty { end = next; break }
                    }; p = next
                }; j += 1
            }
            guard let end, !malformed else { out += ls[i...].joined(); break }
            if strip(String(original[end...])).isEmpty, let value = try? parse(strip(String(original[..<end]))), let encoded = try? encode(value) {
                let replacement = (encoded == value ? "" : legend) + dump(encoded) + ending(original)
                out += count(replacement) < count(original) ? replacement : original
            } else { out += original }; i = j
        }
        return count(out) < count(source) ? out : source
    }
    private static func fields(_ value: Value) -> (String, String)? {
        guard let signature = value.string,
              let match = signature.range(of: #"^(?:(?:public|private|fileprivate|internal|open|static|class|final|mutating|nonmutating|override|required|convenience|indirect|lazy)[\s\x{001c}-\x{001f}]+)*(func|let|var|enum|init|struct|extension|typealias|actor|protocol|class)(?![\p{L}\p{N}_])"#, options: .regularExpression) else { return nil }
        let kind = String(String.UnicodeScalarView(signature[match].unicodeScalars.split(whereSeparator: space).last ?? []))
        if kind == "init" { return (kind, "") }
        let tail = String(signature[match.upperBound...])
        if let name = tail.range(of: #"^[\s\x{001c}-\x{001f}]+([A-Za-z_][A-Za-z_0-9]*)"#, options: .regularExpression) { return (kind, strip(String(tail[name]))) }
        return kind == "func" ? (kind, "") : nil
    }
    private static func unpack(_ value: Value) throws -> Value {
        if let vs = value.items { return .array(try vs.map(unpack)) }
        guard let fs = value.fields else { return value }
        if let table = value["$packedTable"] {
            guard fs.count == 1, table.fields?.count == 2, let columns = table["columns"]?.items,
                  !columns.isEmpty, columns.allSatisfy({ $0.string != nil }), Set(columns.map { Array($0.string!.unicodeScalars) }).count == columns.count,
                  let rows = table["rows"]?.items else { throw Invalid.json }
            return .array(try rows.map { row in
                guard let items = row.items, items.count == columns.count else { throw Invalid.json }
                return .object(try zip(columns, items).map { Field(key: $0.0.string!, value: try unpack($0.1)) })
            })
        }
        return .object(try fs.map { Field(key: $0.key, value: try unpack($0.value)) })
    }
    private static func derive(_ value: Value) throws -> Value {
        if let vs = value.items { return .array(try vs.map(derive)) }
        guard let fs = value.fields else { return value }
        guard value["$swiftDeclarations"] == nil else { throw Invalid.json }
        if fs.count == 1, let table = value["$packedTable"], let columns = table["columns"]?.items,
           let rows = table["rows"]?.items, !rows.isEmpty,
           let k = columns.firstIndex(of: .string("kind")), let n = columns.firstIndex(of: .string("name")), let s = columns.firstIndex(of: .string("signature")),
           rows.allSatisfy({ row in
               guard let items = row.items, items.count == columns.count, let f = fields(items[s]) else { return false }
               return items[k] == .string(f.0) && items[n] == .string(f.1)
           }) {
            let kept = columns.indices.filter { $0 != k && $0 != n }
            return object([("$swiftDeclarations", object([("columns", .array(kept.map { columns[$0] })), ("originalColumns", .array(columns)),
                ("rows", .array(try rows.map { row in .array(try kept.map { try derive(row.items![$0]) }) }))]))])
        }
        return .object(try fs.map { Field(key: $0.key, value: try derive($0.value)) })
    }
    static func declarations(_ source: String, count: (String) -> Int) -> String {
        let ls = lines(source); var out = ""; var state: String?; var i = 0
        while i < ls.count {
            if fence(ls[i], pattern: #"^ {0,3}(`{3,}|~{3,})"#, state: &state) { out += ls[i]; i += 1; continue }
            if state == nil && ls[i] == legend && i + 1 < ls.count, let original = try? parse(strip(ls[i+1])),
               (try? unpack(original)) != nil, let encoded = try? derive(original), encoded != original {
                out += ls[i] + declarationLegend + dump(encoded) + ending(ls[i+1]); i += 2
            } else { out += ls[i]; i += 1 }
        }
        return count(out) < count(source) ? out : source
    }
}
