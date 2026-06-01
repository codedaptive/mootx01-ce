// BitmapFieldConstantsConformanceTests.swift
//
// Cookbook § 2.8 verification-table conformance gate. Cookbook
// § 2.8: "Implementations MUST surface this table as an automated
// conformance test that fails when a source constant deviates
// from spec."
//
// This file enforces that gate for the constants SubstrateLib
// owns. As of F11 (2026-05-27) that's the ten RowState raw
// values (cookbook § 2.3 / § 2.8 rows 1-10). The remaining
// §2.8 entries (Sensitivity, Exportability, Trust, Drawer
// feature flags, Provenance source/channel) are declared in
// LocusKit and will be added to a sibling LocusKit conformance
// test as part of the LocusKit cascade that follows F11.
//
// When this test fails, the failure message names the specific
// (constant, expected, actual) triple per §2.8 row so the diff
// against the cookbook is immediate.

import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

@Suite("Bitmap field constants — cookbook §2.8 verification table")
struct BitmapFieldConstantsConformanceTests {

    /// Cookbook § 2.8 verification table, rows 1-10 (the State
    /// scale-gapped raw values). Each entry is (case, expected
    /// raw, §2.8 row number). Cluster boundaries 0 / 16 / 32 are
    /// chosen so cluster(s) = (s >> 4) & 0x3 is a single
    /// shift-and-mask per cookbook §2.3.
    private static let stateTable: [(state: RowState, expectedRaw: UInt8, row: Int)] = [
        // Cluster A — active / becoming.
        (.active,      0,  1),
        (.pending,     1,  2),
        (.contested,   2,  3),
        (.accepted,    3,  4),
        // Cluster B — superseded / historical (boundary at 16).
        (.superseded, 16,  5),
        (.decayed,    17,  6),
        (.withdrawn,  18,  7),
        (.expired,    19,  8),
        // Cluster C — terminal (boundary at 32).
        (.rejected,   32,  9),
        (.tombstoned, 33, 10),
    ]

    /// Every RowState case's raw value matches the cookbook §2.8
    /// verification table. The test surfaces ALL mismatches in
    /// one run so a stale value triggers one focused failure
    /// rather than one-by-one whack-a-mole.
    @Test func testRowStateRawValuesMatchVerificationTable() {
        var mismatches: [String] = []
        for entry in Self.stateTable {
            if entry.state.rawValue != entry.expectedRaw {
                mismatches.append(
                    "§2.8 row \(entry.row): RowState.\(entry.state) expected raw=\(entry.expectedRaw), got \(entry.state.rawValue)")
            }
        }
        #expect(mismatches.isEmpty,
            "RowState diverges from cookbook §2.8:\n\(mismatches.joined(separator: "\n"))")
    }

    /// The case set is exactly the ten cookbook §2.3 values —
    /// no more, no fewer. Catches accidental additions and
    /// catches accidental deletions.
    @Test func testRowStateCaseSetMatchesVerificationTable() {
        let actual = Set(RowState.allCases.map(\.rawValue))
        let expected: Set<UInt8> = [0, 1, 2, 3, 16, 17, 18, 19, 32, 33]
        #expect(actual == expected,
            "RowState case set diverges from cookbook §2.3 — actual \(actual.sorted()), expected \(expected.sorted())")
        #expect(RowState.allCases.count == 10,
            "RowState must have exactly 10 cases per cookbook §2.3")
    }

    /// Scale-gapped cluster predicate per cookbook §2.3:
    /// `cluster(s) = (s >> 4) & 0x3` resolves to 0 (A), 1 (B),
    /// 2 (C). Verifies the encoding choice that motivated the
    /// raw values is internally consistent.
    @Test func testClusterPredicateResolvesCorrectly() {
        let clusterA: Set<RowState> = [.active, .pending, .contested, .accepted]
        let clusterB: Set<RowState> = [.superseded, .decayed, .withdrawn, .expired]
        let clusterC: Set<RowState> = [.rejected, .tombstoned]

        for s in clusterA {
            let cluster = (s.rawValue >> 4) & 0x3
            #expect(cluster == 0, "\(s) should resolve to cluster A (0), got \(cluster)")
        }
        for s in clusterB {
            let cluster = (s.rawValue >> 4) & 0x3
            #expect(cluster == 1, "\(s) should resolve to cluster B (1), got \(cluster)")
        }
        for s in clusterC {
            let cluster = (s.rawValue >> 4) & 0x3
            #expect(cluster == 2, "\(s) should resolve to cluster C (2), got \(cluster)")
        }
    }
}
