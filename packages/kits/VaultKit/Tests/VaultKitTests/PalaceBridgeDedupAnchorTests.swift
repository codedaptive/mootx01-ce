// PalaceBridgeDedupAnchorTests.swift
//
// The CAND-049 re-import signature must produce the same string for a fact
// however it was written. `sourceDrawerID` used to hold the foreign palace
// key; it now holds a local drawer id or nothing, and the key lives in
// `foreignSourceKey`. If the signature only read the new field, the first
// re-import against an estate populated by the previous importer would match
// nothing and duplicate every fact it had already imported.

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

    /// A row written before `foreignSourceKey` existed: the same palace key
    /// sits in `sourceDrawerID`. It must yield the identical anchor, or the
    /// re-import stops deduping against everything already in the estate.
    @Test func legacyShapeYieldsTheIdenticalAnchor() {
        let current = PalaceBridge.dedupAnchor(
            for: fact(foreignSourceKey: "drawer_alpha_0001"))
        let legacy = PalaceBridge.dedupAnchor(
            for: fact(sourceDrawerID: "drawer_alpha_0001"))
        #expect(legacy == current,
                "a pre-change row must sign identically to the row this importer writes")
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
