// WikidataSubsetTests.swift
//
// Validates that the bundled subset loads, parses, and that
// its data has the expected shape and integrity properties.
// The same structural assertions hold against both real and
// synthetic data.

import Testing
@testable import EideticLib

@Suite("Wikidata subset")
struct WikidataSubsetTests {

    @Test("subset loads from bundle")
    func subsetLoadsFromBundle() {
        #expect(WikidataSubset.loadBundled() != nil)
    }

    @Test("subset versions pinned")
    func subsetVersionsPinned() throws {
        let subset = try #require(WikidataSubset.loadBundled())
        #expect(subset.schemaVersion == "1")
        #expect(!subset.dataVersion.isEmpty)
    }

    @Test("every entry has non-empty qid and label")
    func everyEntryHasNonEmptyQidAndLabel() throws {
        let subset = try #require(WikidataSubset.loadBundled())
        for entry in subset.entries {
            #expect(
                !entry.qid.isEmpty,
                "entry must carry a Q-ID"
            )
            #expect(
                entry.qid.hasPrefix("Q"),
                "Q-ID \(entry.qid) must start with Q"
            )
            #expect(
                !entry.label.isEmpty,
                "entry \(entry.qid) label must be non-empty"
            )
        }
    }

    @Test("every qid unique")
    func everyQidUnique() throws {
        let subset = try #require(WikidataSubset.loadBundled())
        let qids = subset.entries.map { $0.qid }
        #expect(
            Set(qids).count == qids.count,
            "Q-IDs must be unique within the subset"
        )
    }

    @Test("labels are already lowercased")
    func labelsAreAlreadyLowercased() throws {
        let subset = try #require(WikidataSubset.loadBundled())
        for entry in subset.entries {
            #expect(
                entry.label == entry.label.lowercased(),
                "label \(entry.label) must be lowercased"
            )
            for alias in entry.aliases {
                #expect(
                    alias == alias.lowercased(),
                    "alias \(alias) must be lowercased"
                )
            }
        }
    }
}
