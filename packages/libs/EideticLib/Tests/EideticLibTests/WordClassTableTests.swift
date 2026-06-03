// WordClassTableTests.swift
//
// Per-type coverage for WordClassTable
// (Sources/EideticLib/WordClassTable.swift): the static noun/verb
// fast-path table loaded from Resources/WordClassTable.json and its
// process-lifetime cache. Mirrors the Rust port's word_class.rs
// `table_parses_with_pinned_versions` (pinned versions + non-empty
// membership sets) and pins the §1.3 snake_case wire schema.

import Testing
import Foundation
@testable import EideticLib
@testable import LatticeLib

@Suite("WordClassTable")
struct WordClassTableTests {

    @Test("bundled table loads")
    func bundledTableLoads() {
        #expect(WordClassTable.loadBundled() != nil,
                "WordClassTable.json must ship in the module bundle")
    }

    @Test("table parses with pinned versions")
    func tableParsesWithPinnedVersions() throws {
        // Mirrors the Rust `table_parses_with_pinned_versions` test.
        let table = try #require(WordClassTable.loadBundled())
        #expect(table.tableVersion == "1.0.0")
        #expect(table.minOSVersion == "17.0")
        #expect(!table.snapshotDate.isEmpty)
    }

    @Test("cache membership sets are non-empty")
    func cacheMembershipSetsAreNonEmpty() {
        #expect(!WordClassTableCache.nounSet.isEmpty)
        #expect(!WordClassTableCache.verbSet.isEmpty)
    }

    @Test("nouns and verbs are lowercased")
    func nounsAndVerbsAreLowercased() throws {
        let table = try #require(WordClassTable.loadBundled())
        for noun in table.nouns {
            #expect(noun == noun.lowercased(), "noun \(noun) must be lowercased")
        }
        for verb in table.verbs {
            #expect(verb == verb.lowercased(), "verb \(verb) must be lowercased")
        }
    }

    @Test("wire schema uses pinned snake_case keys")
    func wireSchemaUsesPinnedSnakeCaseKeys() throws {
        // The §1.3 schema is the cross-leg contract: both legs parse
        // the same JSON, so the CodingKeys must emit snake_case.
        let table = WordClassTable(
            tableVersion: "1.0.0",
            minOSVersion: "17.0",
            snapshotDate: "2026-01-01",
            nouns: ["dinner"],
            verbs: ["run"]
        )
        let data = try JSONEncoder().encode(table)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"table_version\""))
        #expect(json.contains("\"min_os_version\""))
        #expect(json.contains("\"snapshot_date\""))

        // And the snake_case JSON decodes back to an equal value set.
        let decoded = try JSONDecoder().decode(WordClassTable.self, from: data)
        #expect(decoded.tableVersion == "1.0.0")
        #expect(decoded.minOSVersion == "17.0")
        #expect(decoded.snapshotDate == "2026-01-01")
        #expect(decoded.nouns == ["dinner"])
        #expect(decoded.verbs == ["run"])
    }
}
