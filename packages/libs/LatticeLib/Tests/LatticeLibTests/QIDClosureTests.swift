// QIDClosureTests.swift
//
// Tests for the pinned Q-ID taxonomic-closure surface (mission #7b). The
// load-bearing checks are: the transitive BFS closure over the pinned
// edge graph excludes the queried qid, is sorted numerically, and is
// byte-identical to the Rust port (`qid_closure.rs` tests). The golden
// values below (closure sizes + the FNV.hash16 of the "|"-joined closure)
// are computed from the SAME pinned `QIDClosureEdges.json` the Rust port
// embeds, so an agreement here is a cross-port agreement.

import Foundation
import SubstrateTypes
import Testing
@testable import LatticeLib

@Suite("QIDClosureTests")
struct QIDClosureTests {

    // MARK: - Availability

    @Test("The pinned edge graph loads")
    func graphLoads() {
        // The artifact is bundled unconditionally via Resources; it must load.
        #expect(QIDClosure.isAvailable)
        #expect(QIDClosure.dataVersion == "1.0.0")
    }

    // MARK: - Closure shape (excludes self, numerically sorted)

    @Test("A qid is excluded from its own closure")
    func qidExcludedFromOwnClosure() {
        let anc = QIDClosure.ancestors(of: "Q146")
        #expect(!anc.contains("Q146"))
    }

    @Test("The closure is sorted numerically by the integer part of the Q-ID")
    func closureNumericallySorted() {
        let anc = QIDClosure.ancestors(of: "Q146")
        #expect(anc.count > 1)
        for i in 1..<anc.count {
            #expect(QIDClosure.qidInt(anc[i - 1]) <= QIDClosure.qidInt(anc[i]),
                    "closure not numerically sorted at index \(i): \(anc[i-1]) then \(anc[i])")
        }
    }

    // MARK: - Empty / unknown / root → []

    @Test("An empty qid resolves to an empty closure")
    func emptyQidEmpty() {
        #expect(QIDClosure.ancestors(of: "").isEmpty)
    }

    @Test("An unknown qid resolves to an empty closure")
    func unknownQidEmpty() {
        // Absent from the pinned graph → no ancestors.
        #expect(QIDClosure.ancestors(of: "Q999999999").isEmpty)
    }

    @Test("A root node with no direct edges has an empty closure")
    func rootHasEmptyClosure() {
        // Q104709533 is present in the graph with no direct P31/P279 parents.
        #expect(QIDClosure.ancestors(of: "Q104709533").isEmpty)
    }

    // MARK: - Golden cross-port pins (same artifact the Rust port embeds)

    @Test("Q146 closure size and hash match the cross-port golden value")
    func q146GoldenPin() {
        let anc = QIDClosure.ancestors(of: "Q146")
        // Golden values computed from the pinned QIDClosureEdges.json by BFS.
        #expect(anc.count == 518)
        #expect(anc.first == "Q336")
        // The exact representation DrawerFingerprint hashes: sorted-numeric,
        // "|"-joined, FNV.hash16. Pins the cross-port byte-identity.
        #expect(FNV.hash16(anc.joined(separator: "|")) == 28752)
    }

    @Test("Q5 closure size and hash match the cross-port golden value")
    func q5GoldenPin() {
        let anc = QIDClosure.ancestors(of: "Q5")
        #expect(anc.count == 508)
        #expect(FNV.hash16(anc.joined(separator: "|")) == 17946)
    }

    // MARK: - Determinism + memoization

    @Test("Repeated calls return identical results (memoized)")
    func memoizedStable() {
        let a = QIDClosure.ancestors(of: "Q5")
        let b = QIDClosure.ancestors(of: "Q5")
        #expect(a == b)
    }

    @Test("Distinct qids with different closures produce different hashes")
    func distinctClosuresDistinctHashes() {
        // Q146 (518 ancestors) and Q5 (508) share a common prefix but diverge,
        // so their "|"-joined closures hash differently.
        let h146 = FNV.hash16(QIDClosure.ancestors(of: "Q146").joined(separator: "|"))
        let h5 = FNV.hash16(QIDClosure.ancestors(of: "Q5").joined(separator: "|"))
        #expect(h146 != h5)
    }

    // MARK: - qidInt parsing

    @Test("qidInt parses the trailing integer")
    func qidIntParses() {
        #expect(QIDClosure.qidInt("Q146") == 146)
        #expect(QIDClosure.qidInt("Q1084") == 1084)
        #expect(QIDClosure.qidInt("Q5") == 5)
    }
}
