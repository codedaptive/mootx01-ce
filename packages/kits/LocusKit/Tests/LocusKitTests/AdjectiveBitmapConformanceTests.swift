import Foundation
import Testing
@testable import LocusKit

/// Cookbook §2.8 verification-table conformance gate for the
/// adjective-bitmap constants LocusKit owns: AdjectiveSensitivity,
/// AdjectiveExportability, Trust, and State (which LocusKit holds in
/// addition to SubstrateLib's RowState — the two are kept in sync as
/// part of F14's RowStateAutomaton consumption).
///
/// Cookbook §2.8: "Implementations MUST surface this table as an
/// automated conformance test that fails when a source constant
/// deviates from spec." This file enforces that gate. The SubstrateLib
/// sibling test (`BitmapFieldConstantsConformanceTests`) covers the
/// substrate-owned RowState side; this file covers everything else in
/// §2.8 that LocusKit declares.
///
/// F11 cascade (2026-05-27): added after the v0.6 raw-value migration
/// to lock the new constants in place. Any drift from cookbook §2.8
/// MUST fail this test before it ships.
@Suite("AdjectiveBitmapConformanceTests")
struct AdjectiveBitmapConformanceTests {

    // MARK: - State (cookbook §2.3 / §2.8 rows 1-10)

    private static let stateTable: [(state: State, expectedRaw: Int, row: Int)] = [
        (.active,      0,  1),
        (.pending,     1,  2),
        (.contested,   2,  3),
        (.accepted,    3,  4),
        (.superseded, 16,  5),
        (.decayed,    17,  6),
        (.withdrawn,  18,  7),
        (.expired,    19,  8),
        (.rejected,   32,  9),
        (.tombstoned, 33, 10),
    ]

    @Test("State raw values match cookbook §2.8 verification table")
    func stateRawValuesMatchVerificationTable() {
        var mismatches: [String] = []
        for entry in Self.stateTable {
            if entry.state.rawValue != entry.expectedRaw {
                mismatches.append(
                    "§2.8 row \(entry.row): State.\(entry.state) expected raw=\(entry.expectedRaw), got \(entry.state.rawValue)")
            }
        }
        if !mismatches.isEmpty { Issue.record(Comment(rawValue: "State diverges from cookbook §2.8:\n" + mismatches.joined(separator: "\n"))) }
    }

    @Test("State case set is exactly the ten cookbook §2.3 raws")
    func stateCaseSetMatchesVerificationTable() {
        let actual = Set(Self.stateTable.map(\.state.rawValue))
        let expected: Set<Int> = [0, 1, 2, 3, 16, 17, 18, 19, 32, 33]
        #expect(actual == expected,
            "State case set diverges from cookbook §2.3 — actual \(actual.sorted()), expected \(expected.sorted())")
    }

    @Test("State cluster predicate (state >> 4) & 0x3 resolves correctly")
    func stateClusterPredicate() {
        let clusterA: Set<State> = [.active, .pending, .contested, .accepted]
        let clusterB: Set<State> = [.superseded, .decayed, .withdrawn, .expired]
        let clusterC: Set<State> = [.rejected, .tombstoned]
        for s in clusterA { #expect((s.rawValue >> 4) & 0x3 == 0, "\(s) should be in Cluster A") }
        for s in clusterB { #expect((s.rawValue >> 4) & 0x3 == 1, "\(s) should be in Cluster B") }
        for s in clusterC { #expect((s.rawValue >> 4) & 0x3 == 2, "\(s) should be in Cluster C") }
    }

    // MARK: - AdjectiveSensitivity (cookbook §2.3 / §2.8 rows 11-14)

    private static let sensitivityTable: [(sens: AdjectiveSensitivity, expectedRaw: Int, row: Int)] = [
        (.normal,      0, 11),
        (.elevated,   16, 12),
        (.restricted, 32, 13),
        (.secret,     48, 14),
    ]

    @Test("AdjectiveSensitivity raw values match cookbook §2.8 verification table")
    func sensitivityRawValuesMatchVerificationTable() {
        var mismatches: [String] = []
        for entry in Self.sensitivityTable {
            if entry.sens.rawValue != entry.expectedRaw {
                mismatches.append(
                    "§2.8 row \(entry.row): AdjectiveSensitivity.\(entry.sens) expected raw=\(entry.expectedRaw), got \(entry.sens.rawValue)")
            }
        }
        if !mismatches.isEmpty { Issue.record(Comment(rawValue: "AdjectiveSensitivity diverges from cookbook §2.8:\n" + mismatches.joined(separator: "\n"))) }
    }

    @Test("AdjectiveSensitivity field lives at bits 6-11 (cookbook §2.3)")
    func sensitivityFieldPosition() {
        for entry in Self.sensitivityTable {
            let bitmap = Int64(entry.expectedRaw) << 6
            let drawer = Drawer(
                content: "c", parentNodeId: "test-parent", addedBy: "test",
                filedAt: Date(timeIntervalSince1970: 0),
                embeddingModelID: "minilm-v6",
                adjectiveBitmap: bitmap
            )
            #expect(drawer.adjectiveSensitivity == entry.sens,
                "§2.8 row \(entry.row): bitmap=\(bitmap) should decode to \(entry.sens)")
        }
    }

    // MARK: - AdjectiveExportability (cookbook §2.3 / §2.8 rows 15-16)

    private static let exportabilityTable: [(exp: AdjectiveExportability, expectedRaw: Int, row: Int)] = [
        (.private_,  0, 15),
        (.public_,  32, 16),
    ]

    @Test("AdjectiveExportability raw values match cookbook §2.8 verification table")
    func exportabilityRawValuesMatchVerificationTable() {
        var mismatches: [String] = []
        for entry in Self.exportabilityTable {
            if entry.exp.rawValue != entry.expectedRaw {
                mismatches.append(
                    "§2.8 row \(entry.row): AdjectiveExportability.\(entry.exp) expected raw=\(entry.expectedRaw), got \(entry.exp.rawValue)")
            }
        }
        if !mismatches.isEmpty { Issue.record(Comment(rawValue: "AdjectiveExportability diverges from cookbook §2.8:\n" + mismatches.joined(separator: "\n"))) }
    }

    @Test("AdjectiveExportability field lives at bits 12-17 (cookbook §2.3)")
    func exportabilityFieldPosition() {
        for entry in Self.exportabilityTable {
            let bitmap = Int64(entry.expectedRaw) << 12
            let drawer = Drawer(
                content: "c", parentNodeId: "test-parent", addedBy: "test",
                filedAt: Date(timeIntervalSince1970: 0),
                embeddingModelID: "minilm-v6",
                adjectiveBitmap: bitmap
            )
            #expect(drawer.exportability == entry.exp,
                "§2.8 row \(entry.row): bitmap=\(bitmap) should decode to \(entry.exp)")
        }
    }

    // MARK: - Trust (cookbook §2.3 / §2.8 rows 17-23)

    private static let trustTable: [(trust: Trust, expectedRaw: Int, row: Int)] = [
        (.verbatim,  0, 17),
        (.observed,  1, 18),
        (.imported,  2, 19),
        (.canonical, 3, 20),
        (.derived,   4, 21),
        (.proposed,  5, 22),
        (.ambient,   6, 23),   // NEW in v0.6
    ]

    @Test("Trust raw values match cookbook §2.8 verification table")
    func trustRawValuesMatchVerificationTable() {
        var mismatches: [String] = []
        for entry in Self.trustTable {
            if entry.trust.rawValue != entry.expectedRaw {
                mismatches.append(
                    "§2.8 row \(entry.row): Trust.\(entry.trust) expected raw=\(entry.expectedRaw), got \(entry.trust.rawValue)")
            }
        }
        if !mismatches.isEmpty { Issue.record(Comment(rawValue: "Trust diverges from cookbook §2.8:\n" + mismatches.joined(separator: "\n"))) }
    }

    @Test("Trust case set is exactly the seven cookbook §2.3 raws")
    func trustCaseSetMatchesVerificationTable() {
        let actual = Set(Self.trustTable.map(\.trust.rawValue))
        let expected: Set<Int> = [0, 1, 2, 3, 4, 5, 6]
        #expect(actual == expected,
            "Trust case set diverges from cookbook §2.3 — actual \(actual.sorted()), expected \(expected.sorted())")
    }

    @Test("Trust field lives at bits 18-23 (cookbook §2.3)")
    func trustFieldPosition() {
        for entry in Self.trustTable {
            let bitmap = Int64(entry.expectedRaw) << 18
            let drawer = Drawer(
                content: "c", parentNodeId: "test-parent", addedBy: "test",
                filedAt: Date(timeIntervalSince1970: 0),
                embeddingModelID: "minilm-v6",
                adjectiveBitmap: bitmap
            )
            #expect(drawer.trust == entry.trust,
                "§2.8 row \(entry.row): bitmap=\(bitmap) should decode to \(entry.trust)")
        }
    }

    // MARK: - Full composite (all four axes simultaneously)

    /// state=.contested(2) | sensitivity=.elevated(16)<<6 | exportability=.private_(0)<<12 | trust=.observed(1)<<18
    /// = 2 | 1024 | 0 | 262144 = 263170 = 0x40402.
    @Test("Composite four-axis bitmap round-trips through all accessors")
    func compositeFourAxisRoundtrip() {
        let raw: Int64 =
            Int64(State.contested.rawValue)
            | (Int64(AdjectiveSensitivity.elevated.rawValue) << 6)
            | (Int64(AdjectiveExportability.private_.rawValue) << 12)
            | (Int64(Trust.observed.rawValue) << 18)
        #expect(raw == 0x40402, "composite encoding mismatch: \(raw) != 0x40402")
        let drawer = Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: raw
        )
        #expect(drawer.state == .contested)
        #expect(drawer.adjectiveSensitivity == .elevated)
        #expect(drawer.exportability == .private_)
        #expect(drawer.trust == .observed)
    }

    // MARK: - dreaming_recalc_required (cookbook §2.3 bit 26, §2.8 row 23)

    @Test("§2.8 row 23: dreaming_recalc_required lives at adjective bit 26 (F17)")
    func dreamingRecalcRequiredAtBit26() {
        // Default zero ⇒ flag false.
        let zeroDrawer = Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: 0
        )
        #expect(zeroDrawer.dreamingRecalcRequired == false)

        // Bit 26 set ⇒ flag true.
        let flaggedDrawer = Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: Int64(1) << 26
        )
        #expect(flaggedDrawer.dreamingRecalcRequired == true)

        // High bits don't leak in (bit 27, 28 etc. set without bit 26 ⇒ flag false).
        let neighborBitsDrawer = Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: Int64(1) << 27
        )
        #expect(neighborBitsDrawer.dreamingRecalcRequired == false)
    }

    @Test("§2.8 row 23: dreaming_recalc_required composes with other adjective fields (F17)")
    func dreamingRecalcRequiredComposesWithOtherFields() {
        // state=Active(0) | trust=Canonical(3)<<18 | dreaming_recalc_required(1)<<26
        let raw: Int64 =
            Int64(State.active.rawValue)
            | (Int64(Trust.canonical.rawValue) << 18)
            | (Int64(1) << 26)

        let drawer = Drawer(
            content: "c", parentNodeId: "test-parent", addedBy: "test",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6",
            adjectiveBitmap: raw
        )
        #expect(drawer.state == .active)
        #expect(drawer.trust == .canonical)
        #expect(drawer.dreamingRecalcRequired == true)
    }
}
