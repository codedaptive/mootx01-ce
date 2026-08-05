// PalaceBridgeDedupAnchorTests.swift
//
// The CAND-049 re-import signature must produce the same string for a fact
// whichever column holds its palace key. Rows this importer writes carry the
// key in `foreignSourceKey` and leave `sourceDrawerID` empty; rows already in
// an estate from an earlier importer carry that same key in `sourceDrawerID`.
// A signature that read only `foreignSourceKey` would match none of the
// second kind, so the first re-import would duplicate every one of them.

import Testing
import Foundation
import LocusKit
@testable import VaultKit

@Suite("CAND-049 dedup anchor is stable across row shapes")
struct PalaceBridgeDedupAnchorTests {

    private func fact(
        sourceDrawerID: String = "",
        foreignSourceKey: String = ""
    ) -> KGFact {
        KGFact(
            subject: "fleet",
            predicate: "works_with",
            object: "skippy",
            sourceDrawerID: sourceDrawerID,
            foreignSourceKey: foreignSourceKey,
            filedAt: Date(timeIntervalSince1970: 0))
    }

    /// A row this importer wrote: the palace key is in `foreignSourceKey` and
    /// `sourceDrawerID` is empty.
    @Test func currentShapeReadsTheForeignKey() {
        let anchor = PalaceBridge.dedupAnchor(
            for: fact(foreignSourceKey: "drawer_alpha_0001"))
        #expect(anchor == "drawer_alpha_0001")
    }

    /// A row that carries the same palace key in `sourceDrawerID` — the shape
    /// an earlier importer wrote. It must yield the identical anchor, or the
    /// re-import stops deduping against everything already in the estate.
    @Test func keyInSourceDrawerIDYieldsTheIdenticalAnchor() {
        let inNewColumn = PalaceBridge.dedupAnchor(
            for: fact(foreignSourceKey: "drawer_alpha_0001"))
        let inOldColumn = PalaceBridge.dedupAnchor(
            for: fact(sourceDrawerID: "drawer_alpha_0001"))
        #expect(inOldColumn == inNewColumn,
                "both column placements must sign identically")
    }

    /// A locally-filed fact anchored to a real drawer keeps comparing on that
    /// drawer id — unchanged from what the importer has always done.
    @Test func localFactStillComparesOnItsDrawerID() {
        let anchor = PalaceBridge.dedupAnchor(
            for: fact(sourceDrawerID: "6E7F1A2B-local-drawer"))
        #expect(anchor == "6E7F1A2B-local-drawer")
    }

    /// A sourceless fact anchors on the empty string, as it always has.
    @Test func sourcelessFactAnchorsOnEmptyString() {
        #expect(PalaceBridge.dedupAnchor(for: fact()) == "")
    }
}
