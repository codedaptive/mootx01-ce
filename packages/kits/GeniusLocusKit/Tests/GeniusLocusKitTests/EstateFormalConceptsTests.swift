// EstateFormalConceptsTests.swift
//
// Integration tests for `EstateFormalConcepts` (mission MX-3a).
//
// Two surfaces under test:
//   1. `mineFormalConcepts(estate:miner:)` — reads audit log,
//      builds RowAttributeView rows, materialises FormalContext,
//      delegates to BoundedConceptMiner.
//   2. `formalConceptCoverDeltas(estate:miner:)` — same pipeline
//      plus ConceptCoverDeltas.covering(concepts:) over the mined concept set.
//
// Both entry points are pure adapters: they shape inputs, delegate
// math to SubstrateML, and return results. These tests verify the
// adapter wiring, not the algorithm correctness (which is covered by
// SubstrateMLTests and the conformance vectors).

import Testing
import Foundation
import SubstrateML
import SubstrateTypes
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

@Suite("EstateFormalConcepts")
struct EstateFormalConceptsTests {

    // MARK: - Estate helpers

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-efca-tests")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// HLC factory: keeps test fixtures independent of wall time.
    private func hlc(_ p: Int64, _ l: Int32 = 0) -> HLC {
        HLC(physicalTime: p, logicalCount: l, nodeID: 1)
    }

    // MARK: - Edge cases

    @Test("mineFormalConcepts returns empty for an estate with no audit entries")
    func mineFormalConceptsEmptyAuditLogReturnsEmpty() async throws {
        let (kit, handle) = try await openEstate()
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let concepts = try await kit.mineFormalConcepts(estate: handle, miner: miner)
        #expect(concepts.isEmpty)
    }

    @Test("formalConceptCoverDeltas returns empty cover deltas for empty audit log")
    func coverDeltasEmptyAuditLogReturnsEmpty() async throws {
        let (kit, handle) = try await openEstate()
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let coverDeltas = try await kit.formalConceptCoverDeltas(estate: handle, miner: miner)
        #expect(coverDeltas.coverDeltas.isEmpty)
    }

    // MARK: - Two cohorts produce two concepts

    /// Inject two clean cohorts into the durable audit log so that bounded
    /// FCA finds exactly two concepts.
    ///
    /// Dataset (4 rows, 4 unique rowIDs), expressed through bitmap-column
    /// bits (bit position p on a column = attribute value p; see the
    /// injectAuditEvents seam):
    ///   Rows 0-1: adjective bit 1 AND operational bit 2 → cohort A, support 2
    ///   Rows 2-3: adjective bit 3 AND operational bit 4 → cohort B, support 2
    ///
    /// With minSupport=2, both cohorts are emitted as concepts whose
    /// intents contain the (field, value) FormalAttributes derived
    /// from each row's column bits.
    @Test("mineFormalConcepts finds two concepts for two-cohort audit log")
    func mineFormalConceptsTwoCohorts() async throws {
        let (kit, handle) = try await openEstate()

        let rowIDs = (0..<4).map { _ in UUID() }
        var rows: [AuditFixtureRow] = []

        // Rows 0-1: cohort A
        for i in 0..<2 {
            rows.append(AuditFixtureRow(
                rowID: rowIDs[i], adjective: 1 << 1, operational: 1 << 2,
                hlc: hlc(Int64(i + 1), 0)))
        }
        // Rows 2-3: cohort B
        for i in 2..<4 {
            rows.append(AuditFixtureRow(
                rowID: rowIDs[i], adjective: 1 << 3, operational: 1 << 4,
                hlc: hlc(Int64(i + 10), 0)))
        }

        try await kit.injectAuditEvents(rows, for: handle)

        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let concepts = try await kit.mineFormalConcepts(estate: handle, miner: miner)

        // Two clean cohorts → exactly two concepts.
        #expect(concepts.count == 2, "expected 2 concepts, got \(concepts.count)")
        // Each concept covers exactly 2 rows.
        #expect(concepts.allSatisfy { $0.support == 2 })
        // Intents are non-empty (the cohort attributes).
        #expect(concepts.allSatisfy { !$0.intent.isEmpty })
    }

    // MARK: - Cover deltas wiring

    /// Nested cohort: rows 0-3 carry adjective bit 1; rows 0-1 additionally
    /// carry operational bit 2. Single-seed mining produces two concepts in
    /// a cover relation. The cover-delta set must contain exactly one delta
    /// (the cover {adjective:1} → {operational:2}).
    @Test("formalConceptCoverDeltas returns cover delta for nested cohorts")
    func coverDeltasNestedCohorts() async throws {
        let (kit, handle) = try await openEstate()

        let rowIDs = (0..<4).map { _ in UUID() }
        var rows: [AuditFixtureRow] = []

        // All four rows carry adjective bit 1; rows 0-1 additionally carry
        // operational bit 2.
        for i in 0..<4 {
            rows.append(AuditFixtureRow(
                rowID: rowIDs[i],
                adjective: 1 << 1,
                operational: i < 2 ? 1 << 2 : 0,
                hlc: hlc(Int64(i + 1), 0)))
        }

        try await kit.injectAuditEvents(rows, for: handle)

        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let coverDeltas = try await kit.formalConceptCoverDeltas(estate: handle, miner: miner)

        // Nested fixture: {adjective:1} ⊂ {adjective:1, operational:2} —
        // one direct cover.
        #expect(coverDeltas.coverDeltas.count == 1,
                "nested cohorts must produce exactly one cover delta, got \(coverDeltas.coverDeltas.count)")

        let delta = coverDeltas.coverDeltas[0]
        // lowerIntent is the smaller concept's intent (the broader attribute).
        #expect(delta.lowerIntent.count == 1)
        // addedAttributes is the delta (the more specific attribute).
        #expect(delta.addedAttributes.count == 1)
        // The combined lowerIntent ∪ addedAttributes has 2 attributes.
        #expect(delta.lowerIntent.count + delta.addedAttributes.count == 2)
    }

    // MARK: - Min-support gate

    @Test("mineFormalConcepts respects min-support gate")
    func mineFormalConceptsMinSupportGate() async throws {
        let (kit, handle) = try await openEstate()

        // One cohort of 2 rows (support 2) and one singleton (support 1).
        let rowIDs = (0..<3).map { _ in UUID() }
        var rows: [AuditFixtureRow] = []

        // Rows 0-1: adjective bit 1 (support 2)
        for i in 0..<2 {
            rows.append(AuditFixtureRow(
                rowID: rowIDs[i], adjective: 1 << 1, hlc: hlc(Int64(i + 1), 0)))
        }
        // Row 2: adjective bit 2 (support 1)
        rows.append(AuditFixtureRow(
            rowID: rowIDs[2], adjective: 1 << 2, hlc: hlc(10, 0)))

        try await kit.injectAuditEvents(rows, for: handle)

        // minSupport=2: singleton concept is gated out.
        let miner = BoundedConceptMiner(minSupport: 2, maxIntentSize: 8, maxConcepts: 8)
        let concepts = try await kit.mineFormalConcepts(estate: handle, miner: miner)
        #expect(concepts.count == 1)
        #expect(concepts[0].support == 2)
    }
}
