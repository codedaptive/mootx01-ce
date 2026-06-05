// EstateAssociationRuleMiningTests.swift
//
// Integration tests for `EstateAssociationRuleMining` (mission MX-2).
//
// Two surfaces under test:
//   1. `mineAssociationRules(estate:thresholds:)` — reads a registered
//      MatrixTier and delegates to the pairwise ARM engine.
//   2. `mineAprioriRules(estate:thresholds:)` — reads the estate's
//      audit log and delegates to the multi-antecedent Apriori engine.
//
// Both entry points are pure adapters: they shape inputs, delegate
// math to SubstrateML, and return results. These tests verify the
// adapter wiring, not the algorithm correctness (which is covered by
// SubstrateMLTests and the conformance vectors in
// docs/engineering/substrate_reference/test-harness/vectors/).

import Testing
import Foundation
import SubstrateML
import SubstrateTypes
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import GeniusLocusKit

// MARK: - Test-only actor extension

// Injects synthetic audit entries directly into the kit's in-memory
// G-Set, bypassing the LocusKit bridge. Used to set up deterministic
// Apriori test fixtures without needing live captures. The method is
// actor-isolated; callers `await` it.
extension GeniusLocusKit {
    func injectAuditEntries(
        _ entries: [UnifiedAuditEntry],
        for handle: EstateHandle
    ) {
        auditLogs[handle, default: UnifiedAuditLog()].add(contentsOf: entries)
    }
}

// MARK: - Suite

@Suite("EstateAssociationRuleMining")
struct EstateAssociationRuleMiningTests {

    // MARK: - Estate helpers

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "owner-earm-tests")
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

    // MARK: - Pairwise ARM

    @Test("pairwise ARM emits rules from a registered MatrixTier")
    func pairwiseARMProducesRules() async throws {
        let (kit, handle) = try await openEstate()

        // Build a MatrixTier with two integer-valued coordinates that
        // co-occur in 4 of 5 rows. The adapter projects:
        //   field.a / .integer(1) → Item(field:0, value:1)
        //   field.b / .integer(2) → Item(field:1, value:2)
        // coOccurrence entry count = 4; liveRowCount = 5.
        var tier = MatrixTier()
        let coordA = MatrixValueCoord(fieldPath: "field.a", value: .integer(1))
        let coordB = MatrixValueCoord(fieldPath: "field.b", value: .integer(2))

        // 4 rows with both coords co-occurring.
        for t in 0..<4 {
            tier.applyCapture(
                bitmapFields: [],
                valueFields: [coordA, coordB],
                hlc: hlc(Int64(100 + t))
            )
        }
        // 1 row with only coordA — breaks the perfect correlation.
        tier.applyCapture(
            bitmapFields: [],
            valueFields: [coordA],
            hlc: hlc(200)
        )

        await kit.registerMatrixTier(tier, for: handle)

        // MiningThresholds has no lift gate; all rules with
        // support ≥ 0.5 and confidence ≥ 0.5 are emitted regardless of lift.
        let thresholds = MiningThresholds(minSupport: 0.5, minConfidence: 0.5)
        let rules = await kit.mineAssociationRules(estate: handle, thresholds: thresholds)

        // Two directed rules expected: (0,1)→(1,2) and (1,2)→(0,1).
        #expect(rules.count == 2)

        // Both rules should share the same support (4/5 = 0.8 from the
        // adapter's diagonal-liveRowCount approximation).
        for r in rules {
            #expect(r.support > 0.0)
            #expect(r.confidence > 0.0)
        }
    }

    @Test("pairwise ARM returns empty when no MatrixTier is registered")
    func pairwiseARMMissingTierReturnsEmpty() async throws {
        let (kit, handle) = try await openEstate()
        // No registerMatrixTier call.
        let thresholds = MiningThresholds(minSupport: 0.1, minConfidence: 0.1)
        let rules = await kit.mineAssociationRules(estate: handle, thresholds: thresholds)
        #expect(rules.isEmpty)
    }

    @Test("pairwise ARM returns empty for empty MatrixTier")
    func pairwiseARMEmptyTierReturnsEmpty() async throws {
        let (kit, handle) = try await openEstate()
        // Register an empty tier (no captures).
        await kit.registerMatrixTier(MatrixTier(), for: handle)
        let thresholds = MiningThresholds(minSupport: 0.1, minConfidence: 0.1)
        let rules = await kit.mineAssociationRules(estate: handle, thresholds: thresholds)
        #expect(rules.isEmpty)
    }

    // MARK: - Apriori

    /// Inject the canonical am-002 dataset (mirrored from AprioriMining's
    /// conformance vector) via `UnifiedAuditEntry` so the adapter path is
    /// exercised end-to-end.
    ///
    /// Dataset (N=5 rows, 5 unique rowIDs):
    ///   Rows 0-2: f.x=1 AND f.y=2   (both fields co-occur)
    ///   Row  3:   f.x=1 AND f.z=3
    ///   Row  4:   f.z=3 only
    ///
    /// With minSupport=0.5, minConfidence=0.5:
    ///   Vocab: ["f.x", "f.y", "f.z"] → indices 0, 1, 2
    ///   RowAttributeView rows (from integer low-byte extraction):
    ///     rows 0-2: [(0,1),(1,2)]   ← f.x→item(0,1), f.y→item(1,2)
    ///     row 3:    [(0,1),(2,3)]
    ///     row 4:    [(2,3)]
    ///   {item(0,1)}: 4 rows → support=0.8 ✓
    ///   {item(1,2)}: 3 rows → support=0.6 ✓
    ///   {item(2,3)}: 2 rows → support=0.4 < 0.5 (not frequent)
    ///   {item(0,1), item(1,2)}: 3 rows → support=0.6 ✓
    ///   Rules: (1,2)→(0,1) conf=1.0, lift=1.25; (0,1)→(1,2) conf=0.75, lift=1.25
    @Test("Apriori emits am-002 conformance rules from injected audit entries")
    func aprioriProducesConformanceRules() async throws {
        let (kit, handle) = try await openEstate()

        // Five distinct row IDs for the 5-row dataset.
        let rowIDs = (0..<5).map { _ in UUID() }

        var entries: [UnifiedAuditEntry] = []

        // Rows 0-2: both f.x=1 and f.y=2 captured.
        for i in 0..<3 {
            entries.append(UnifiedAuditEntry(
                tier: .locus,
                hlc: hlc(Int64(i + 1), 0),
                verb: .capture,
                rowID: rowIDs[i],
                fieldPath: "f.x",
                beforeValue: .null,
                afterValue: .integer(1)
            ))
            entries.append(UnifiedAuditEntry(
                tier: .locus,
                hlc: hlc(Int64(i + 1), 1),
                verb: .capture,
                rowID: rowIDs[i],
                fieldPath: "f.y",
                beforeValue: .null,
                afterValue: .integer(2)
            ))
        }
        // Row 3: f.x=1 and f.z=3.
        entries.append(UnifiedAuditEntry(
            tier: .locus,
            hlc: hlc(10, 0),
            verb: .capture,
            rowID: rowIDs[3],
            fieldPath: "f.x",
            beforeValue: .null,
            afterValue: .integer(1)
        ))
        entries.append(UnifiedAuditEntry(
            tier: .locus,
            hlc: hlc(10, 1),
            verb: .capture,
            rowID: rowIDs[3],
            fieldPath: "f.z",
            beforeValue: .null,
            afterValue: .integer(3)
        ))
        // Row 4: only f.z=3.
        entries.append(UnifiedAuditEntry(
            tier: .locus,
            hlc: hlc(20, 0),
            verb: .capture,
            rowID: rowIDs[4],
            fieldPath: "f.z",
            beforeValue: .null,
            afterValue: .integer(3)
        ))

        await kit.injectAuditEntries(entries, for: handle)

        let thresholds = AprioriThresholds(
            minSupport: 0.5,
            minConfidence: 0.5,
            minLift: 1.0,
            maxK: 2
        )
        let rules = try await kit.mineAprioriRules(estate: handle, thresholds: thresholds)

        // am-002 pattern: 2 rules emitted — (1,2)→(0,1) and (0,1)→(1,2).
        #expect(rules.count == 2, "expected exactly 2 rules (am-002 pattern)")

        // Sorted lift DESC, conf DESC: (1,2)→(0,1) with conf=1.0 comes first.
        let r0 = rules[0]
        #expect(r0.antecedent.count == 1)
        #expect(r0.antecedent[0] == Item(field: 1, value: 2))
        #expect(r0.consequent == Item(field: 0, value: 1))

        let r1 = rules[1]
        #expect(r1.antecedent.count == 1)
        #expect(r1.antecedent[0] == Item(field: 0, value: 1))
        #expect(r1.consequent == Item(field: 1, value: 2))
    }

    @Test("Apriori returns empty for an estate with no audit entries")
    func aprioriEmptyAuditLogReturnsEmpty() async throws {
        let (kit, handle) = try await openEstate()
        // No captures; audit log is empty.
        let thresholds = AprioriThresholds(
            minSupport: 0.1,
            minConfidence: 0.1,
            minLift: 1.0,
            maxK: 2
        )
        let rules = try await kit.mineAprioriRules(estate: handle, thresholds: thresholds)
        #expect(rules.isEmpty)
    }

    @Test("Apriori maxK=3 emits multi-antecedent rules from three co-occurring fields")
    func aprioriMaxK3Rules() async throws {
        let (kit, handle) = try await openEstate()

        // 3 rows with fields A, B, C all co-occurring.
        // Vocab: ["f.a","f.b","f.c"] → Item(0,1), Item(1,1), Item(2,1)
        let rowIDs = (0..<4).map { _ in UUID() }
        var entries: [UnifiedAuditEntry] = []
        let fields = [("f.a", 1), ("f.b", 1), ("f.c", 1)]
        for i in 0..<3 {
            for (j, (path, v)) in fields.enumerated() {
                entries.append(UnifiedAuditEntry(
                    tier: .locus,
                    hlc: hlc(Int64(i + 1), Int32(j)),
                    verb: .capture,
                    rowID: rowIDs[i],
                    fieldPath: path,
                    beforeValue: .null,
                    afterValue: .integer(Int64(v))
                ))
            }
        }
        // 1 row with only A and B (breaks C's frequency).
        entries.append(UnifiedAuditEntry(
            tier: .locus,
            hlc: hlc(100, 0),
            verb: .capture,
            rowID: rowIDs[3],
            fieldPath: "f.a",
            beforeValue: .null,
            afterValue: .integer(1)
        ))
        entries.append(UnifiedAuditEntry(
            tier: .locus,
            hlc: hlc(100, 1),
            verb: .capture,
            rowID: rowIDs[3],
            fieldPath: "f.b",
            beforeValue: .null,
            afterValue: .integer(1)
        ))

        await kit.injectAuditEntries(entries, for: handle)

        let thresholds = AprioriThresholds(
            minSupport: 0.5,
            minConfidence: 0.5,
            minLift: 1.0,
            maxK: 3
        )
        let rules = try await kit.mineAprioriRules(estate: handle, thresholds: thresholds)

        // Expect at least the two-item antecedent rules from the {A,B,C} itemset.
        let twoAntecedent = rules.filter { $0.antecedent.count == 2 }
        #expect(twoAntecedent.count > 0, "maxK=3 should produce 2-antecedent rules")
    }
}
