// WikidataSubsetTests.swift
//
// Validates that the bundled subset loads, parses, and that
// its data has the expected shape and integrity properties.
// The same structural assertions hold against both real and
// synthetic data.

import XCTest
@testable import EideticLib

final class WikidataSubsetTests: XCTestCase {

    func testSubsetLoadsFromBundle() {
        XCTAssertNotNil(WikidataSubset.loadBundled())
    }

    func testSubsetVersionsPinned() throws {
        let subset = try XCTUnwrap(WikidataSubset.loadBundled())
        XCTAssertEqual(subset.schemaVersion, "1")
        XCTAssertFalse(subset.dataVersion.isEmpty)
    }

    func testEveryEntryHasNonEmptyQidAndLabel() throws {
        let subset = try XCTUnwrap(WikidataSubset.loadBundled())
        for entry in subset.entries {
            XCTAssertFalse(
                entry.qid.isEmpty,
                "entry must carry a Q-ID"
            )
            XCTAssertTrue(
                entry.qid.hasPrefix("Q"),
                "Q-ID \(entry.qid) must start with Q"
            )
            XCTAssertFalse(
                entry.label.isEmpty,
                "entry \(entry.qid) label must be non-empty"
            )
        }
    }

    func testEveryQidUnique() throws {
        let subset = try XCTUnwrap(WikidataSubset.loadBundled())
        let qids = subset.entries.map { $0.qid }
        XCTAssertEqual(
            Set(qids).count, qids.count,
            "Q-IDs must be unique within the subset"
        )
    }

    func testLabelsAreAlreadyLowercased() throws {
        let subset = try XCTUnwrap(WikidataSubset.loadBundled())
        for entry in subset.entries {
            XCTAssertEqual(
                entry.label, entry.label.lowercased(),
                "label \(entry.label) must be lowercased"
            )
            for alias in entry.aliases {
                XCTAssertEqual(
                    alias, alias.lowercased(),
                    "alias \(alias) must be lowercased"
                )
            }
        }
    }
}
