import Foundation

/// Complete representation, not a semantic quality qualification. Original text remains authoritative.
public struct CompleteContentResult: Sendable {
    public let version: String
    public let text: String
    public let sourceSHA256: String
    public let representationSHA256: String
    public let visibleRefs: Bool
    public let originalTokens: Int
    public let outputTokens: Int
    public let qualityQualified = false
    public let modelAssistance = false
}

public enum CompleteContentError: Error { case invalidRepresentation(String) }

/// Native port of the bounded complete-form-visible-v6 chain. The default counter is an
/// estimate; callers can supply their authoritative tokenizer for every savings gate.
public enum CompleteContentReducer {
    public static let version = "complete-form-visible-v6"

    public static func distill(_ source: String, count: (String) -> Int = estimateTokens) throws -> CompleteContentResult {
        var text = source
        var exposed = false
        if source.hasPrefix(CompleteText.notice + CompleteText.refLegend) {
            _ = try CompleteText.expandVisible(source)
            exposed = true
        } else if !source.hasPrefix(CompleteText.timestampIntro) {
            text = CompleteText.clocks(text, count: count)
            text = CompleteJSON.tables(text, count: count)
            if !CompleteText.lines(source).contains(CompleteJSON.legend) {
                text = try CompleteText.references(text, count: count)
            }
            text = CompleteJSON.blocks(text, count: count)
            text = CompleteJSON.declarations(text, count: count)
            text = CompleteText.timestamps(text, count: count)
            if text.hasPrefix(CompleteText.refLegend) {
                let intermediate = try CompleteText.expandRefs(text)
                let candidate = try CompleteText.visible(intermediate, count: count)
                if candidate != intermediate && count(candidate) < count(source) {
                    guard try CompleteText.expandVisible(candidate) == intermediate else {
                        throw CompleteContentError.invalidRepresentation("Visible-reference reconstruction failed")
                    }
                    text = candidate
                    exposed = true
                }
            }
        }
        return CompleteContentResult(version: version, text: text,
            sourceSHA256: sourceDigest(source), representationSHA256: sourceDigest(text),
            visibleRefs: exposed, originalTokens: count(source), outputTokens: count(text))
    }
}

/// Python splitlines/regex helpers used only by the complete representation grammar.
enum CompleteText {
    static let refLegend = "Repeated-text notation: [[TSREF:n DEFINE]] introduces one exact line; [[TSREF:n REPEAT]] repeats that complete line at its current position.\n"
    static let notice = "Linked repeats show their original numeric link prefix before the reference; the reference still denotes the whole original entry.\n"
    static let timestampIntro = "Timestamp prefixes: [Tn HH:MM] means template Tn below with HH:MM substituted. Templates are JSON strings; decode escapes. No timezone is implied.\n"
    static let timestampBoundary = "--- Original-order text ---\n"
    static func strip(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.drop(while: whitespace).reversed().drop(while: whitespace).reversed()))
    }
    static func whitespace(_ scalar: Unicode.Scalar) -> Bool {
        isPythonWhitespace(scalar) || (0x1c...0x1f).contains(scalar.value)
    }
    static func lines(_ text: String) -> [String] {
        let s = Array(text.unicodeScalars)
        var result: [String] = []; var start = 0; var i = 0
        while i < s.count {
            if [10, 11, 12, 13, 28, 29, 30, 133, 8232, 8233].contains(s[i].value) {
                if s[i].value == 13 && i + 1 < s.count && s[i + 1].value == 10 { i += 1 }
                result.append(s[start...i].asString()); start = i + 1
            }
            i += 1
        }
        if start < s.count { result.append(s[start...].asString()) }
        return result
    }
    struct Match {
        let groups: [String?]
        let end: String.Index
        subscript(_ index: Int) -> String { groups[index] ?? "" }
    }
    static func match(_ pattern: String, _ text: String) -> Match? {
        let pythonPattern = pattern.replacingOccurrences(of: #"\s"#, with: #"[\x{0009}-\x{000D}\x{001C}-\x{0020}\x{0085}\x{00A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}]"#)
        guard let regex = try? NSRegularExpression(pattern: pythonPattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range, in: text) else { return nil }
        return Match(groups: (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } }, end: r.upperBound)
    }
    static func fence(_ line: String, state: inout String?, pattern: String = #"^\s*(`{3,}|~{3,})"#) -> Bool {
        guard let m = match(pattern, line) else { return false }
        let token = m[1]
        if let active = state {
            if token.first == active.first && token.count >= active.count && strip(String(line[m.end...])).isEmpty { state = nil }
        } else { state = token }
        return true
    }
    static func clocks(_ source: String, count: (String) -> Int) -> String {
        guard let marker = match(#"(?:\A|\n)## Transcript[ \t]*\r?(?=\n|\z)"#, source) else { return source }
        var output = ""; var edits = 0; var previous = "0"
        for line in lines(String(source[marker.end...])) {
            if strip(line).isEmpty { output += line; continue }
            guard let m = match(#"^\[(\d{2,}):(\d{2})(?::(\d{2}))?\] "#, line),
                  let a = decimal(m[1]), let bs = decimal(m[2]), let b = Int(bs), b < 60 else { return source }
            let c = m.groups[3].flatMap(decimal).flatMap(Int.init)
            if m.groups[3] != nil && c == nil { return source }
            if let c, c >= 60 { return source }
            let value = multiplyAdd(a, by: c == nil ? 60 : 3600, add: c == nil ? b : b * 60 + c!)
            guard value.count > previous.count || (value.count == previous.count && value >= previous) else { return source }
            previous = value; edits += 1
            output += "\(value) " + line[m.end...]
        }
        guard edits >= 8 else { return source }
        let candidate = source[..<marker.end] + "\nEach nonblank line starts with its elapsed time in seconds, followed by the spoken segment.\n" + output
        return count(candidate) < count(source) ? candidate : source
    }
    private static func decimal(_ text: String) -> String? {
        var output = ""
        for scalar in text.unicodeScalars {
            guard scalar.properties.generalCategory == .decimalNumber,
                  let value = scalar.properties.numericValue else { return nil }
            output += String(Int(value))
        }
        let stripped = output.drop(while: { $0 == "0" })
        return stripped.isEmpty ? "0" : String(stripped)
    }
    private static func multiplyAdd(_ number: String, by factor: Int, add: Int) -> String {
        var carry = add; var digits: [UInt8] = []
        for digit in number.utf8.reversed() {
            let value = Int(digit - 48) * factor + carry
            digits.append(UInt8(value % 10) + 48); carry = value / 10
        }
        while carry > 0 { digits.append(UInt8(carry % 10) + 48); carry /= 10 }
        return String(decoding: digits.reversed(), as: UTF8.self)
    }
    static func references(_ source: String, count: (String) -> Int) throws -> String {
        guard !source.contains("[[TSREF:") else { return source }
        let input = lines(source); var state: String?; var eligible: [[UInt8]: [Int]] = [:]; var order: [String] = []
        for (i, line) in input.enumerated() {
            if fence(line, state: &state) { continue }
            if state != nil || line.unicodeScalars.count < 100 || line.unicodeScalars.last != "\n" ||
                match(#"^\s*(?:#|>|\||\{|\[|\d+[.)])"#, line) != nil || line.hasPrefix("    ") || line.hasPrefix("\t") { continue }
            let key = Array(line.utf8)
            if eligible[key] == nil { order.append(line) }
            eligible[key, default: []].append(i)
        }
        var output = input; var n = 0
        for line in order {
            let indexes = eligible[Array(line.utf8)]!
            guard indexes.count >= 2 else { continue }
            let define = "[[TSREF:\(n + 1) DEFINE]] " + line
            let repeated = "[[TSREF:\(n + 1) REPEAT]]\n"
            guard count(define) + (indexes.count - 1) * count(repeated) < indexes.count * count(line) else { continue }
            n += 1; output[indexes[0]] = define
            for i in indexes.dropFirst() { output[i] = repeated }
        }
        let candidate = refLegend + output.joined()
        guard n > 0, count(candidate) < count(source) else { return source }
        guard try expandRefs(candidate) == source else { throw CompleteContentError.invalidRepresentation("Repeated-text reconstruction failed") }
        return candidate
    }
    static func expandRefs(_ text: String) throws -> String {
        guard text.hasPrefix(refLegend) else { return text }
        var definitions: [String: String] = [:]; var output = ""
        for line in lines(String(text.dropFirst(refLegend.count))) {
            if let m = match(#"^\[\[TSREF:(\d+) DEFINE\]\] "#, line) {
                guard definitions[m[1]] == nil else { throw CompleteContentError.invalidRepresentation("Duplicate definition") }
                let value = String(line[m.end...]); definitions[m[1]] = value; output += value
            } else if let m = match(#"^\[\[TSREF:(\d+) REPEAT\]\]\n\z"#, line) {
                guard let value = definitions[m[1]] else { throw CompleteContentError.invalidRepresentation("Forward or unknown reference") }
                output += value
            } else { output += line }
        }
        return output
    }
    static let visibleDefine = #"^\[\[TSREF:(\d+) DEFINE\]\] - \[\[([0-9]+)-[^\]\n]+\]\]"#
    static func expandVisible(_ text: String) throws -> String {
        guard text.hasPrefix(notice + refLegend) else { return text }
        var definitions: [String: String] = [:]; var output = ""
        for line in lines(String(text.dropFirst((notice + refLegend).count))) {
            if let m = match(visibleDefine, line) { definitions[m[1]] = m[2] }
            if let m = match(#"^entry ([0-9]+): (\[\[TSREF:(\d+) REPEAT\]\]\n)\z"#, line) {
                guard definitions[m[3]] == m[1] else { throw CompleteContentError.invalidRepresentation("Visible identity mismatch") }
                output += m[2]
            } else { output += line }
        }
        return try expandRefs(refLegend + output)
    }
    static func visible(_ source: String, count: (String) -> Int) throws -> String {
        guard !source.contains(notice) else { return source }
        let prior = try references(source, count: count)
        guard prior != source else { return source }
        var definitions: [String: String] = [:]; var output = ""; var cues = 0
        for var line in lines(String(prior.dropFirst(refLegend.count))) {
            if let m = match(visibleDefine, line) { definitions[m[1]] = m[2] }
            if let m = match(#"^\[\[TSREF:(\d+) REPEAT\]\]\n\z"#, line), let identifier = definitions[m[1]] {
                line = "entry \(identifier): " + line; cues += 1
            }
            output += line
        }
        let candidate = notice + refLegend + output
        guard cues > 0, count(candidate) < count(source) else { return source }
        guard try expandVisible(candidate) == source else { throw CompleteContentError.invalidRepresentation("Reconstruction mismatch") }
        return candidate
    }
    static func mapUnfenced(_ source: String, replace: (String) -> String) -> String {
        var state: String?
        return lines(source).map { line in
            if fence(line, state: &state, pattern: #"^ {0,3}(`{3,}|~{3,})"#) || state != nil { return line }
            return replace(line)
        }.joined()
    }
    static func timestamps(_ source: String, count: (String) -> Int) -> String {
        guard !source.contains("[T"), !source.contains(timestampIntro), !source.contains(timestampBoundary) else { return source }
        let pattern = #"^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})( \([^\n)]+\) — )"#
        var groups: [[UInt8]: Int] = [:]; var order: [String] = []
        _ = mapUnfenced(source) { line in
            if let m = match(pattern, line), !m[3].contains("HH:MM") {
                let key = m[1] + "THH:MM" + m[3]
                if groups[Array(key.utf8)] == nil { order.append(key) }
                groups[Array(key.utf8), default: 0] += 1
            }
            return line
        }
        var selected: [[UInt8]: Int] = [:]; var definitions = ""
        for template in order {
            let n = groups[Array(template.utf8)]!; let id = selected.count + 1
            let definition = "T\(id) = " + quote(template) + "\n"
            guard n >= 2, count(definition) + n * count("[T\(id) 00:00] ") < n * count(template.replacingOccurrences(of: "HH:MM", with: "00:00")) else { continue }
            selected[Array(template.utf8)] = id; definitions += definition
        }
        var changed = false
        let body = mapUnfenced(source) { line in
            guard let m = match(pattern, line), let id = selected[Array((m[1] + "THH:MM" + m[3]).utf8)] else { return line }
            changed = true
            return "[T\(id) \(m[2])] " + line[m.end...]
        }
        let candidate = timestampIntro + definitions + timestampBoundary + body
        return changed && count(candidate) < count(source) ? candidate : source
    }
    static func quote(_ text: String) -> String {
        var output = "\""
        for s in text.unicodeScalars {
            switch s.value {
            case 34: output += "\\\""
            case 92: output += "\\\\"
            case 8: output += "\\b"
            case 9: output += "\\t"
            case 10: output += "\\n"
            case 12: output += "\\f"
            case 13: output += "\\r"
            case 0..<32: output += String(format: "\\u%04x", s.value)
            default: output.unicodeScalars.append(s)
            }
        }
        return output + "\""
    }
}
