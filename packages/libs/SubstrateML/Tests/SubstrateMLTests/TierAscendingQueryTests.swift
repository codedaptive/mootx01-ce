// TierAscendingQueryTests.swift
//
// Tier-ascending query protocol per cookbook § 12.4 / paper § 9.3.
// swift-testing peer suite for Sources/SubstrateML/TierAscendingQuery.swift.
//
// rust/src/tier_query.rs documents an intentional Swift/Rust
// asymmetry — RecallScore/RecallResult/DistanceBreakdown/RowProjection
// have no Rust equivalent by design — so this suite tests the query
// PROTOCOL behavior (local dispatch, combine, DP noising, privacy
// ledger) rather than chasing Rust parity on those Swift-only shapes.

import Foundation
import Testing
import SubstrateTypes
@testable import SubstrateML

@Suite("TierAscendingQuery protocol")
struct TierAscendingQueryTests {

    private func hlc(_ t: Int64) -> HLC { HLC(physicalTime: t, logicalCount: 0, nodeID: 1) }
    private func score(_ id: RowId, _ s: Float32) -> RecallScore { RecallScore(rowId: id, score: s) }

    @Test("computeLocal dispatches the named primitive on its input")
    func computeLocalDispatches() {
        let q = TierAscendingQuery(
            originatingEstate: UUID(), primitiveName: "recall_moment_summary",
            primitiveInput: Data([1, 2, 3]), targetTier: .peer,
            privacyBudget: DPParameters(), queryHLC: hlc(1))
        var sawName = ""
        var sawInput = Data()
        let result = TierAscendingQueryProtocol.computeLocal(query: q) { name, input in
            sawName = name; sawInput = input
            return RecallResult(rows: [], primitiveName: name)
        }
        #expect(sawName == "recall_moment_summary")
        #expect(sawInput == Data([1, 2, 3]))
        #expect(result.primitiveName == "recall_moment_summary")
    }

    @Test("combine unions rows by id, summing their scores")
    func combineUnionsAndSums() {
        let r1 = UUID(), r2 = UUID(), r3 = UUID()
        let local = RecallResult(rows: [score(r1, 1.0), score(r2, 2.0)], primitiveName: "p")
        let peer = PeerResponse(
            peerEstate: UUID(),
            contribution: RecallResult(rows: [score(r2, 0.5), score(r3, 3.0)], primitiveName: "p"),
            consumedEpsilon: 0.1, consumedDelta: 0.0)
        let combined = TierAscendingQueryProtocol.combine(local: local, peers: [peer])
        let byId = Dictionary(uniqueKeysWithValues: combined.rows.map { ($0.rowId, $0.score) })
        #expect(byId[r1] == 1.0)
        #expect(byId[r2] == 2.5)   // summed across local + peer
        #expect(byId[r3] == 3.0)
        #expect(combined.rows.count == 3)
    }

    @Test("combine returns rows sorted by score descending")
    func combineSortsDescending() {
        let r1 = UUID(), r2 = UUID(), r3 = UUID()
        let local = RecallResult(
            rows: [score(r1, 1.0), score(r2, 5.0), score(r3, 3.0)], primitiveName: "p")
        let combined = TierAscendingQueryProtocol.combine(local: local, peers: [])
        let scores = combined.rows.map { $0.score }
        #expect(scores == scores.sorted(by: >))
        #expect(combined.rows.first?.rowId == r2)
    }

    @Test("combine carries the widest peer confidence interval")
    func combineCarriesWidestCI() {
        let local = RecallResult(rows: [score(UUID(), 1.0)], primitiveName: "p")
        let narrow = PeerResponse(
            peerEstate: UUID(),
            contribution: RecallResult(rows: [], confidenceInterval: (-0.1, 0.1), primitiveName: "p"),
            consumedEpsilon: 0.1, consumedDelta: 0)
        let wide = PeerResponse(
            peerEstate: UUID(),
            contribution: RecallResult(rows: [], confidenceInterval: (-2.0, 2.0), primitiveName: "p"),
            consumedEpsilon: 0.1, consumedDelta: 0)
        let combined = TierAscendingQueryProtocol.combine(local: local, peers: [narrow, wide])
        #expect(combined.confidenceInterval?.lower == -2.0)
        #expect(combined.confidenceInterval?.upper == 2.0)
    }

    @Test("applyDPToContribution is deterministic for a fixed RNG seed")
    func dpNoiseIsSeedDeterministic() {
        let id = UUID()
        let result = RecallResult(rows: [score(id, 1.0)], primitiveName: "p")
        let budget = DPParameters(epsilon: 1.0)
        let a = TierAscendingQueryProtocol.applyDPToContribution(result, budget: budget, rngSeed: 0xABCDEF)
        let b = TierAscendingQueryProtocol.applyDPToContribution(result, budget: budget, rngSeed: 0xABCDEF)
        #expect(a.rows.first?.score == b.rows.first?.score)
        // A different seed should (with overwhelming probability) noise differently.
        let c = TierAscendingQueryProtocol.applyDPToContribution(result, budget: budget, rngSeed: 0x123456)
        #expect(a.rows.first?.score != c.rows.first?.score)
    }

    // MARK: - Privacy ledger

    @Test("a fresh ledger reports the full daily budget as remaining")
    func ledgerStartsFull() {
        let peer = UUID()
        let ledger = PrivacyLedger(dailyBudget: DPParameters(epsilon: 1.0, delta: 1e-6))
        let rem = ledger.remaining(peer: peer)
        #expect(rem.epsilon == 1.0)
        #expect(rem.delta == 1e-6)
        #expect(ledger.canConsume(peer: peer, query: DPParameters(epsilon: 0.5, delta: 0)))
    }

    @Test("consume debits the budget and eventually refuses over-budget queries")
    func ledgerConsumeAndRefuse() {
        let peer = UUID()
        var ledger = PrivacyLedger(dailyBudget: DPParameters(epsilon: 1.0, delta: 1e-6))
        ledger.consume(peer: peer, query: DPParameters(epsilon: 0.8, delta: 0))
        #expect(abs(ledger.remaining(peer: peer).epsilon - 0.2) < 1e-9)
        // 0.8 already spent; a 0.5 query would exceed the 1.0 budget.
        #expect(ledger.canConsume(peer: peer, query: DPParameters(epsilon: 0.5, delta: 0)) == false)
    }

    @Test("dailyReset restores the full budget")
    func ledgerDailyReset() {
        let peer = UUID()
        var ledger = PrivacyLedger(dailyBudget: DPParameters(epsilon: 1.0, delta: 1e-6))
        ledger.consume(peer: peer, query: DPParameters(epsilon: 0.9, delta: 0))
        ledger.dailyReset()
        #expect(ledger.remaining(peer: peer).epsilon == 1.0)
    }
}
