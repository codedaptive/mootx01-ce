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

// Appends synthetic, mutate-shaped audit events to the estate's DURABLE
// audit log (`storage.auditLog`) — the store `auditLog(for:)` paginates
// and bridges for the miners. Audit data lives only in `_storagekit_audit`
// (disk-default storage residency removed the in-memory G-Set), so fixtures must land there to be
// visible to mining.
//
// Event shape: verb "mutate", beforeBitmaps all-zero, afterBitmaps as
// given, and IDENTICAL before/after lattice anchors. `AuditBridge` then
// emits exactly one `.bitmap` UnifiedAuditEntry per CHANGED column and no
// anchor/Q-ID entries — full control of each row's attribute set.
// `RowAttributeView` turns every set bit at position p of a column value
// into one (column, p) attribute, and the alphabetical fieldPath
// vocabulary ("adjective" < "operational" < "provenance") yields field
// indices 0 / 1 / 2 respectively. So `adjective: 1 << v` produces exactly
// the item `Item(field: 0, value: v)`, and so on per column.
struct AuditFixtureRow {
    let rowID: UUID
    var adjective: Int64 = 0
    var operational: Int64 = 0
    var provenance: Int64 = 0
    let hlc: HLC
}

extension GeniusLocusKit {
    func injectAuditEvents(
        _ rows: [AuditFixtureRow],
        for handle: EstateHandle
    ) async throws {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        // Same anchor before and after: the bridge emits latticeAnchor /
        // wikidataQID entries only when the anchor CHANGES, so a fixed
        // anchor keeps those paths out of the mining vocabulary.
        let anchor = LatticeAnchor(udcCode: 0, qidPointer: 0)
        for row in rows {
            try await storage.auditLog.append(AuditEvent(
                estateUuid: handle.estateUUID,
                rowId: row.rowID,
                hlc: row.hlc,
                verb: "mutate",
                beforeBitmaps: (adjective: 0, operational: 0, provenance: 0),
                afterBitmaps: (adjective: row.adjective,
                               operational: row.operational,
                               provenance: row.provenance),
                beforeLatticeAnchor: anchor,
                afterLatticeAnchor: anchor,
                actor: "test-fixture"
            ))
        }
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
    /// conformance vector) via durable audit events so the adapter path
    /// (storage → AuditBridge → RowAttributeView → Apriori) is exercised
    /// end-to-end.
    ///
    /// Dataset (N=5 rows, 5 unique rowIDs), expressed through the three
    /// bitmap columns (bit position p on a column = item value p; the
    /// alphabetical column vocabulary gives adjective=0, operational=1,
    /// provenance=2):
    ///   Rows 0-2: adjective bit 1 AND operational bit 2   (co-occur)
    ///   Row  3:   adjective bit 1 AND provenance bit 3
    ///   Row  4:   provenance bit 3 only
    ///
    /// With minSupport=0.5, minConfidence=0.5:
    ///   RowAttributeView rows:
    ///     rows 0-2: [(0,1),(1,2)]
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

        var rows: [AuditFixtureRow] = []
        // Rows 0-2: adjective bit 1 + operational bit 2.
        for i in 0..<3 {
            rows.append(AuditFixtureRow(
                rowID: rowIDs[i], adjective: 1 << 1, operational: 1 << 2,
                hlc: hlc(Int64(i + 1), 0)))
        }
        // Row 3: adjective bit 1 + provenance bit 3.
        rows.append(AuditFixtureRow(
            rowID: rowIDs[3], adjective: 1 << 1, provenance: 1 << 3,
            hlc: hlc(10, 0)))
        // Row 4: provenance bit 3 only.
        rows.append(AuditFixtureRow(
            rowID: rowIDs[4], provenance: 1 << 3, hlc: hlc(20, 0)))

        try await kit.injectAuditEvents(rows, for: handle)

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

        // 3 rows with items A, B, C all co-occurring — bit 1 on each of the
        // three columns: A=Item(0,1) adjective, B=Item(1,1) operational,
        // C=Item(2,1) provenance.
        let rowIDs = (0..<4).map { _ in UUID() }
        var rows: [AuditFixtureRow] = []
        for i in 0..<3 {
            rows.append(AuditFixtureRow(
                rowID: rowIDs[i],
                adjective: 1 << 1, operational: 1 << 1, provenance: 1 << 1,
                hlc: hlc(Int64(i + 1), 0)))
        }
        // 1 row with only A and B (breaks C's frequency).
        rows.append(AuditFixtureRow(
            rowID: rowIDs[3], adjective: 1 << 1, operational: 1 << 1,
            hlc: hlc(100, 0)))

        try await kit.injectAuditEvents(rows, for: handle)

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

    // MARK: - Audit-entry cap (vulnerability fix)

    // These two tests verify the audit-entry cap introduced to prevent a
    // caller-induced OOM/hang via `moot_lens_apriori` on estates with large
    // lifetime audit histories. The cap is exercised via the internal
    // `mineAprioriRules(estate:thresholds:entryLimit:)` overload so the
    // test does not need to inject 50,000 entries.

    // CAP-1: constant value guard. If the constant is ever changed, this
    // test fails loudly rather than silently regressing the safety property.
    @Test("maxAuditEntriesForMining constant is 50,000")
    func auditEntriesCapConstantValue() {
        // The cap must be large enough that normal human-driven estates
        // (≤ 10,000 entries) mine fully, and small enough that adversarial
        // replay cannot OOM the server process.
        #expect(GeniusLocusKit.maxAuditEntriesForMining == 50_000)
    }

    // CAP-2: behavioral — entries outside the cap (oldest) are excluded,
    // entries within the cap (newest) are included. Uses the internal
    // `entryLimit` override so the cap boundary can be exercised with a
    // small fixture (10 old entries + 10 new entries, limit = 10).
    //
    // Design (bit position p on a column = item value p; column vocab
    // sorts alphabetically: adjective=0, operational=1):
    //   Old group (HLC 1-5): 5 rows, adjective bit 1 + operational bit 2 —
    //     each event bridges to 2 entries → 10 old entries.
    //     Pattern: Item(field:0, value:1) ↔ Item(field:1, value:2)
    //
    //   New group (HLC 11-15): 5 rows, adjective bit 3 + operational bit 4
    //     → 10 new entries.
    //     Pattern: Item(field:0, value:3) ↔ Item(field:1, value:4)
    //
    //   With entryLimit=10: only the 10 newest entries (the new group) are
    //   visible to the Apriori engine. Rules must involve values 3 and 4
    //   (not 1 or 2). The old group is excluded by the cap.
    //
    //   With entryLimit=20 (all entries): both groups are visible. Rows are
    //   distinct (different UUIDs), so both patterns contribute, and rules
    //   for values 1, 2, 3, 4 can appear.
    @Test("Apriori cap excludes oldest entries and mines only the bounded window")
    func auditEntriesCapExcludesOldestEntries() async throws {
        let (kit, handle) = try await openEstate()

        // 5 row UUIDs for the old group, 5 for the new group.
        let oldRows = (0..<5).map { _ in UUID() }
        let newRows = (0..<5).map { _ in UUID() }

        var rows: [AuditFixtureRow] = []

        // Old group: HLC 1-5. Bits (adjective 1, operational 2).
        for (i, rowID) in oldRows.enumerated() {
            rows.append(AuditFixtureRow(
                rowID: rowID, adjective: 1 << 1, operational: 1 << 2,
                hlc: hlc(Int64(i + 1), 0)))
        }
        // New group: HLC 11-15. Bits (adjective 3, operational 4).
        for (i, rowID) in newRows.enumerated() {
            rows.append(AuditFixtureRow(
                rowID: rowID, adjective: 1 << 3, operational: 1 << 4,
                hlc: hlc(Int64(11 + i), 0)))
        }

        try await kit.injectAuditEvents(rows, for: handle)

        let thresholds = AprioriThresholds(
            minSupport: 0.5,
            minConfidence: 0.5,
            minLift: 1.0,
            maxK: 2
        )

        // With entryLimit=10 (the new group only): rules for values 3 and 4.
        let cappedRules = try await kit.mineAprioriRules(
            estate: handle,
            thresholds: thresholds,
            entryLimit: 10
        )
        // All items in capped rules must have values 3 or 4 (the new-group values).
        // Values 1 and 2 belong to the excluded old group.
        for rule in cappedRules {
            for item in rule.antecedent {
                // Low-6-bit extraction: value 3 → 3, value 4 → 4.
                #expect(item.value == 3 || item.value == 4,
                    "capped mining must only see values from the new group (3 or 4), got \(item.value)")
            }
            let cVal = rule.consequent.value
            #expect(cVal == 3 || cVal == 4,
                "capped mining must only see values from the new group (3 or 4), got \(cVal)")
        }
        // Cap must not exclude all entries — with minSupport=0.5 over 5 rows
        // each carrying both fields, we expect exactly 2 rules.
        #expect(cappedRules.count == 2, "expected 2 rules from the new-group window")

        // With entryLimit=20 (all entries): both groups are included. Old and
        // new rows are distinct, so both patterns contribute. The combined
        // dataset has 10 rows with two distinct (field, value) pairs each.
        // All 10 rows carry f.x and f.y, so all items are frequent at 0.5.
        // We expect rules — but both old-group (1,2) and new-group (3,4)
        // values will appear because all 10 rows are included.
        let allRules = try await kit.mineAprioriRules(
            estate: handle,
            thresholds: thresholds,
            entryLimit: 20
        )
        let allValues = Set(allRules.flatMap { rule in
            rule.antecedent.map { $0.value } + [rule.consequent.value]
        })
        // When all entries are included, the old-group values (1 and 2)
        // must appear in at least one rule (not filtered out).
        #expect(allValues.contains(1) || allValues.contains(2),
            "uncapped mining should see old-group values (1 or 2)")
    }
}
