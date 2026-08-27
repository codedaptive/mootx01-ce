import Foundation
import Testing

// MARK: - Localization-key guard — MootCommunityUI (MA-MOOT-UI-CENSUS)
//
// The Community feature views localize through DOTTED KEYS
// ("lan.status.blocked", "transfer.plan.format.label", …) resolved against
// CommunityApp/en.lproj/Localizable.strings. `String(localized:)` with no
// matching table entry renders the RAW KEY — a placeholder label that
// disguises missing information, which the human-language acceptance law
// forbids. This guard extracts every dotted key used by the MootCommunityUI
// sources and proves each resolves in the shipped table.
//
// Interpolated keys ("obsidian.status.checkpoint \(count)") land in the
// table with format placeholders ("obsidian.status.checkpoint %lld"), so an
// interpolated use is checked by prefix; a plain key must match exactly.
// Calls carrying `defaultValue:` never leak the key and are skipped.
//
// KNOWN-MISSING BASELINE: each entry is a census RED item — a key the
// sources look up that the table does not define TODAY. If the entry gets
// fixed, this guard fails until the baseline entry is removed (stale-debt
// honesty). Any OTHER unresolved key fails immediately.
//
// Fail-closed proof: the extractor and the resolver are exercised on seeded
// fixtures below; a broken extractor cannot silently turn this guard green.

@Suite("Localization-key guard — MootCommunityUI")
struct CommunityLocalizationKeyGuard {

    // MARK: Known-missing baseline (census RED items)

    /// Empty today: every dotted key the sources look up resolves in the
    /// shipped table. R-C23 (obsidian.status.checkpoint.a11y) was closed by
    /// MI-MOOT-INTEGRATION-LANGUAGE.
    static let knownMissingKeys: Set<String> = []

    // MARK: Paths

    static var appRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CommunityBoundaryTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/Mootx01-App
    }

    static var sourcesRoot: URL {
        appRoot.appendingPathComponent("Sources/MootCommunityUI")
    }

    static var stringsTable: URL {
        appRoot.appendingPathComponent("CommunityApp/en.lproj/Localizable.strings")
    }

    // MARK: Extraction

    /// One dotted-key use site: the key prefix (up to the first
    /// interpolation) and whether the literal interpolates.
    struct KeyUse: Hashable {
        let file: String
        let prefix: String
        let interpolated: Bool
    }

    /// Extract every dotted localization key used via
    /// `String(localized: "a.b.c …")` in one source text. Calls that carry
    /// `defaultValue:` are skipped (they cannot leak the key). Literals whose
    /// first token is not a lowercase dotted slug (English-as-key copy) are
    /// skipped.
    static func dottedKeyUses(in source: String, file: String) -> [KeyUse] {
        var uses: [KeyUse] = []
        var search = source.startIndex
        while let markerRange = source.range(of: "localized:", range: search..<source.endIndex) {
            search = markerRange.upperBound
            // Skip whitespace (including newlines) to the literal.
            var index = markerRange.upperBound
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
            guard index < source.endIndex, source[index] == "\"" else { continue }
            // Read the literal, honoring backslash escapes.
            var literal = ""
            var cursor = source.index(after: index)
            var closed = false
            while cursor < source.endIndex {
                let character = source[cursor]
                if character == "\\" {
                    literal.append(character)
                    cursor = source.index(after: cursor)
                    if cursor < source.endIndex {
                        literal.append(source[cursor])
                        cursor = source.index(after: cursor)
                    }
                    continue
                }
                if character == "\"" { closed = true; break }
                literal.append(character)
                cursor = source.index(after: cursor)
            }
            guard closed else { continue }
            // A trailing `defaultValue:` argument means the key never leaks.
            let lookahead = source[source.index(after: cursor)...].prefix(60)
            let afterLiteral = lookahead.drop(while: { $0.isWhitespace })
            if afterLiteral.hasPrefix(","),
               afterLiteral.dropFirst().drop(while: { $0.isWhitespace }).hasPrefix("defaultValue") {
                continue
            }
            // Prefix before the first interpolation.
            let interpolated = literal.contains("\\(")
            let prefix = (literal.components(separatedBy: "\\(").first ?? literal)
                .trimmingCharacters(in: .whitespaces)
            let firstToken = prefix.components(separatedBy: " ").first ?? ""
            guard firstToken.contains("."),
                  !firstToken.isEmpty,
                  firstToken.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "." })
            else { continue }
            uses.append(KeyUse(file: file, prefix: prefix, interpolated: interpolated))
        }
        return uses
    }

    /// Parse `"KEY" = "VALUE";` lines from a .strings table.
    static func tableKeys(in stringsSource: String) -> Set<String> {
        var keys: Set<String> = []
        for rawLine in stringsSource.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\"") else { continue }
            var key = ""
            var cursor = line.index(after: line.startIndex)
            var closed = false
            while cursor < line.endIndex {
                let character = line[cursor]
                if character == "\\" {
                    key.append(character)
                    cursor = line.index(after: cursor)
                    if cursor < line.endIndex {
                        key.append(line[cursor])
                        cursor = line.index(after: cursor)
                    }
                    continue
                }
                if character == "\"" { closed = true; break }
                key.append(character)
                cursor = line.index(after: cursor)
            }
            guard closed,
                  line[line.index(after: cursor)...]
                      .trimmingCharacters(in: .whitespaces)
                      .hasPrefix("=")
            else { continue }
            keys.insert(key)
        }
        return keys
    }

    /// Whether one use site resolves against the table.
    static func resolves(_ use: KeyUse, in table: Set<String>) -> Bool {
        if use.interpolated {
            return table.contains { $0.hasPrefix(use.prefix) }
        }
        return table.contains(use.prefix)
    }

    // MARK: Guard tests

    @Test("every dotted localization key used by MootCommunityUI resolves, except the enumerated known-missing debt")
    func dottedKeysResolve() throws {
        let table = Self.tableKeys(
            in: try String(contentsOf: Self.stringsTable, encoding: .utf8))
        #expect(table.count >= 100, "only \(table.count) table entries parsed from \(Self.stringsTable.path) — parser or path broken")

        var uses: Set<KeyUse> = []
        for file in try CommunityHumanLanguageSourceGuard.swiftFiles(under: Self.sourcesRoot) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for use in Self.dottedKeyUses(in: source, file: file.lastPathComponent) {
                uses.insert(use)
            }
        }
        #expect(uses.count >= 50, "only \(uses.count) dotted key uses extracted — extractor or path broken")

        var unresolved: Set<String> = []
        for use in uses where !Self.resolves(use, in: table) {
            unresolved.insert(use.prefix)
        }
        let newMissing = unresolved.subtracting(Self.knownMissingKeys)
        #expect(newMissing.isEmpty, """
            Dotted localization keys with NO entry in \
            CommunityApp/en.lproj/Localizable.strings — the raw key renders \
            on screen or is read by VoiceOver:
            \(newMissing.sorted().joined(separator: "\n"))
            """)
        let healed = Self.knownMissingKeys.subtracting(unresolved)
        #expect(healed.isEmpty, """
            Known-missing keys now resolve — remove them from the baseline \
            and close the census RED item:
            \(healed.sorted().joined(separator: "\n"))
            """)
    }

    // MARK: Extractor self-tests (fail-closed proof)

    @Test("the extractor finds dotted keys and skips English-as-key and defaultValue calls")
    func extractorFindsSeededKeys() {
        let fixture = """
        Text(String(localized: "fixture.section.title"))
        Text(String(localized: "fixture.count \\(n)"))
        Text(String(localized: "A human sentence."))
        Text(String(localized: "fixture.safe.key", defaultValue: "Safe"))
        Text(String(
            localized:
                "fixture.multiline.key \\(count)"
        ))
        """
        let uses = Self.dottedKeyUses(in: fixture, file: "Fixture.swift")
        let prefixes = Set(uses.map(\.prefix))
        #expect(prefixes == ["fixture.section.title", "fixture.count", "fixture.multiline.key"])
        #expect(uses.first { $0.prefix == "fixture.count" }?.interpolated == true)
        #expect(uses.first { $0.prefix == "fixture.section.title" }?.interpolated == false)
    }

    @Test("a seeded missing key is detected against a fixture table")
    func resolverDetectsMissingKey() {
        let table = Self.tableKeys(in: """
        /* comment */
        "fixture.present" = "Present";
        "fixture.formatted %lld" = "%lld things";
        """)
        #expect(table == ["fixture.present", "fixture.formatted %lld"])
        let present = KeyUse(file: "F", prefix: "fixture.present", interpolated: false)
        let formatted = KeyUse(file: "F", prefix: "fixture.formatted", interpolated: true)
        let missing = KeyUse(file: "F", prefix: "fixture.absent", interpolated: false)
        #expect(Self.resolves(present, in: table))
        #expect(Self.resolves(formatted, in: table))
        #expect(!Self.resolves(missing, in: table))
    }
}
