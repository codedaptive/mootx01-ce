// FieldLWWMergeTests.swift
//
// Tests for FieldLWWMerge and ColumnHLCMap.
//
// Covers:
//   - Disjoint columns: both survive the merge
//   - Same column: newest HLC wins
//   - Commutativity property test: merge(A, B) == merge(B, A)
//   - Tombstone matrix: empty map wins, edit-beats-delete, tie-goes-to-tombstone
//   - ColumnHLCMap.merge: pick-highest per column
//   - ColumnHLCMap.stampAll: stamps every key with given HLC
//   - PackedHLC ordering: physicalTime > logicalCount > nodeID

import Testing
import Foundation
import SubstrateTypes
import ConvergenceKit
import PersistenceKit

// MARK: - Helpers

private func hlc(physical: Int64, logical: Int32 = 0, node: Int32 = 1) -> PackedHLC {
    PackedHLC(HLC(physicalTime: physical, logicalCount: logical, nodeID: node))
}

// MARK: - PackedHLC ordering

@Suite("PackedHLC.Comparable — lexicographic ordering")
struct PackedHLCOrderingTests {

    @Test("physicalTime dominates")
    func physicalTimeDominates() {
        let a = hlc(physical: 100, logical: 99, node: 255)
        let b = hlc(physical: 101, logical: 0,  node: 0)
        #expect(a < b)
        #expect(!(b < a))
    }

    @Test("logicalCount breaks physicalTime tie")
    func logicalCountBreaksTie() {
        let a = hlc(physical: 100, logical: 0, node: 255)
        let b = hlc(physical: 100, logical: 1, node: 0)
        #expect(a < b)
    }

    @Test("nodeID breaks full tie")
    func nodeIDBreaksTie() {
        let a = hlc(physical: 100, logical: 5, node: 1)
        let b = hlc(physical: 100, logical: 5, node: 2)
        #expect(a < b)
    }

    @Test("equal HLCs compare equal")
    func equalHLCs() {
        let a = hlc(physical: 100, logical: 5, node: 3)
        let b = hlc(physical: 100, logical: 5, node: 3)
        #expect(!(a < b))
        #expect(!(b < a))
        #expect(a == b)
    }
}

// MARK: - ColumnHLCMap

@Suite("ColumnHLCMap — map operations")
struct ColumnHLCMapTests {

    @Test("stampAll: every key maps to the given HLC")
    func stampAll() {
        let h = hlc(physical: 50)
        let map = ColumnHLCMap.stampAll(keys: ["title", "body", "score"], hlc: h)
        #expect(map.entries["title"] == h)
        #expect(map.entries["body"]  == h)
        #expect(map.entries["score"] == h)
        #expect(map.entries.count == 3)
    }

    @Test("stampAll: empty keys → empty map")
    func stampAllEmpty() {
        let map = ColumnHLCMap.stampAll(keys: [], hlc: hlc(physical: 10))
        #expect(map.isEmpty)
    }

    @Test("merge: disjoint columns — all survive")
    func mergeDisjoint() {
        let a = ColumnHLCMap(entries: ["title": hlc(physical: 100)])
        let b = ColumnHLCMap(entries: ["body":  hlc(physical: 200)])
        let merged = a.merge(with: b)
        #expect(merged.entries["title"] == hlc(physical: 100))
        #expect(merged.entries["body"]  == hlc(physical: 200))
        #expect(merged.entries.count == 2)
    }

    @Test("merge: same column — highest HLC wins")
    func mergeSameColumnHighest() {
        let a = ColumnHLCMap(entries: ["title": hlc(physical: 100)])
        let b = ColumnHLCMap(entries: ["title": hlc(physical: 200)])
        let merged = a.merge(with: b)
        #expect(merged.entries["title"] == hlc(physical: 200))
    }

    @Test("merge: same column — lower HLC does not overwrite higher")
    func mergeSameColumnLowerLoses() {
        let a = ColumnHLCMap(entries: ["score": hlc(physical: 500)])
        let b = ColumnHLCMap(entries: ["score": hlc(physical: 100)])
        let merged = a.merge(with: b)
        #expect(merged.entries["score"] == hlc(physical: 500))
    }

    // COMMUTATIVITY PROPERTY TEST (spec mandated)
    //
    // ColumnHLCMap.merge is commutative: for any two maps A and B,
    // A.merge(with: B) == B.merge(with: A).
    //
    // Proof: merge picks max(hlcA, hlcB) per column. max is commutative.
    // We test with a fixed set of representative inputs covering disjoint,
    // overlapping-lower, overlapping-higher, and tie cases.
    @Test("merge commutativity: A.merge(B) == B.merge(A)")
    func mergeCommutativity() {
        let cases: [(ColumnHLCMap, ColumnHLCMap)] = [
            // Disjoint
            (
                ColumnHLCMap(entries: ["c1": hlc(physical: 100)]),
                ColumnHLCMap(entries: ["c2": hlc(physical: 200)])
            ),
            // A wins on col1, B wins on col2
            (
                ColumnHLCMap(entries: ["c1": hlc(physical: 300), "c2": hlc(physical: 10)]),
                ColumnHLCMap(entries: ["c1": hlc(physical: 100), "c2": hlc(physical: 500)])
            ),
            // Tie on col1
            (
                ColumnHLCMap(entries: ["c1": hlc(physical: 100, logical: 5, node: 2)]),
                ColumnHLCMap(entries: ["c1": hlc(physical: 100, logical: 5, node: 2)])
            ),
            // Empty vs non-empty
            (
                ColumnHLCMap(),
                ColumnHLCMap(entries: ["c1": hlc(physical: 999)])
            ),
            // Multiple overlapping columns + disjoint
            (
                ColumnHLCMap(entries: [
                    "c1": hlc(physical: 100),
                    "c2": hlc(physical: 200),
                    "c3": hlc(physical: 50),
                ]),
                ColumnHLCMap(entries: [
                    "c1": hlc(physical: 99),
                    "c2": hlc(physical: 201),
                    "c4": hlc(physical: 1000),
                ])
            ),
        ]

        for (a, b) in cases {
            let ab = a.merge(with: b)
            let ba = b.merge(with: a)
            #expect(ab == ba, "commutativity failed for maps \(a) and \(b)")
        }
    }

    @Test("Codable round-trip through JSON")
    func codableRoundTrip() throws {
        let map = ColumnHLCMap(entries: [
            "title": hlc(physical: 1_000_000, logical: 3, node: 5),
            "body":  hlc(physical: 2_000_000, logical: 0, node: 1),
        ])
        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode(ColumnHLCMap.self, from: data)
        #expect(decoded == map)
    }

    @Test("JSON shape has entries key at root")
    func jsonShape() throws {
        let map = ColumnHLCMap(entries: ["col": hlc(physical: 42)])
        let data = try JSONEncoder().encode(map)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["entries"] != nil, "top-level key must be 'entries'")
        let entries = json?["entries"] as? [String: Any]
        #expect(entries?["col"] != nil)
    }
}

// MARK: - FieldLWWMerge

@Suite("FieldLWWMerge — column merge logic")
struct FieldLWWMergeTests {

    // MARK: Disjoint columns

    @Test("disjoint columns: all incoming applied when no local HLCs")
    func disjointNoLocal() {
        let incoming: [String: TypedValue] = [
            "title": .text("hello"),
            "score": .int(42),
        ]
        let incomingColumnHLCs = ColumnHLCMap.stampAll(keys: incoming.keys, hlc: hlc(physical: 100))
        let (apply, updated) = FieldLWWMerge.merge(
            incomingValues: incoming,
            incomingColumnHLCs: incomingColumnHLCs,
            incomingRowHLC: hlc(physical: 100),
            localColumnHLCs: ColumnHLCMap()
        )
        #expect(apply["title"] == .text("hello"))
        #expect(apply["score"] == .int(42))
        #expect(updated.entries["title"] == hlc(physical: 100))
        #expect(updated.entries["score"] == hlc(physical: 100))
    }

    @Test("disjoint columns: both survive merge with different local HLCs")
    func disjointBothSurvive() {
        // Local has "title" at T=50; incoming adds "body" at T=100
        let incoming: [String: TypedValue] = ["body": .text("new body")]
        let incomingColHLCs = ColumnHLCMap(entries: ["body": hlc(physical: 100)])
        let localColHLCs = ColumnHLCMap(entries: ["title": hlc(physical: 50)])

        let (apply, updated) = FieldLWWMerge.merge(
            incomingValues: incoming,
            incomingColumnHLCs: incomingColHLCs,
            incomingRowHLC: hlc(physical: 100),
            localColumnHLCs: localColHLCs
        )
        // "body" is applied (no local HLC for it)
        #expect(apply["body"] == .text("new body"))
        // "title" is not in incomingValues so not touched
        #expect(apply["title"] == nil)
        // updated map has both
        #expect(updated.entries["body"]  == hlc(physical: 100))
        #expect(updated.entries["title"] == hlc(physical: 50))
    }

    // MARK: Same column — newest wins

    @Test("same column: incoming newer → applied")
    func sameColumnIncomingNewer() {
        let incoming: [String: TypedValue] = ["score": .int(99)]
        let incomingColHLCs = ColumnHLCMap(entries: ["score": hlc(physical: 200)])
        let localColHLCs    = ColumnHLCMap(entries: ["score": hlc(physical: 100)])

        let (apply, updated) = FieldLWWMerge.merge(
            incomingValues: incoming,
            incomingColumnHLCs: incomingColHLCs,
            incomingRowHLC: hlc(physical: 200),
            localColumnHLCs: localColHLCs
        )
        #expect(apply["score"] == .int(99))
        #expect(updated.entries["score"] == hlc(physical: 200))
    }

    @Test("same column: local newer → incoming rejected")
    func sameColumnLocalNewer() {
        let incoming: [String: TypedValue] = ["score": .int(1)]
        let incomingColHLCs = ColumnHLCMap(entries: ["score": hlc(physical: 50)])
        let localColHLCs    = ColumnHLCMap(entries: ["score": hlc(physical: 200)])

        let (apply, updated) = FieldLWWMerge.merge(
            incomingValues: incoming,
            incomingColumnHLCs: incomingColHLCs,
            incomingRowHLC: hlc(physical: 50),
            localColumnHLCs: localColHLCs
        )
        #expect(apply["score"] == nil, "local is newer; incoming must be rejected")
        // Local HLC unchanged (incoming was lower so updatedEntries keeps local)
        #expect(updated.entries["score"] == hlc(physical: 200))
    }

    @Test("same column: tie (equal HLC) → incoming applied (>= semantics)")
    func sameColumnTieIncomingApplied() {
        let h = hlc(physical: 100, logical: 5, node: 3)
        let incoming: [String: TypedValue] = ["note": .text("tie")]
        let incomingColHLCs = ColumnHLCMap(entries: ["note": h])
        let localColHLCs    = ColumnHLCMap(entries: ["note": h])

        let (apply, _) = FieldLWWMerge.merge(
            incomingValues: incoming,
            incomingColumnHLCs: incomingColHLCs,
            incomingRowHLC: h,
            localColumnHLCs: localColHLCs
        )
        #expect(apply["note"] == .text("tie"), "tie → incoming wins (>= semantics)")
    }

    // MARK: Backward-compat: no per-column HLCs → row-grain fallback

    @Test("no per-column HLCs: row-grain fallback applied when newer than local")
    func rowGrainFallbackNewer() {
        let incoming: [String: TypedValue] = ["col": .text("v2")]
        let localColHLCs = ColumnHLCMap(entries: ["col": hlc(physical: 100)])

        let (apply, _) = FieldLWWMerge.merge(
            incomingValues: incoming,
            incomingColumnHLCs: ColumnHLCMap(), // no per-column HLCs
            incomingRowHLC: hlc(physical: 200), // row-grain is newer
            localColumnHLCs: localColHLCs
        )
        #expect(apply["col"] == .text("v2"))
    }

    @Test("no per-column HLCs: row-grain fallback rejected when older than local")
    func rowGrainFallbackOlder() {
        let incoming: [String: TypedValue] = ["col": .text("old")]
        let localColHLCs = ColumnHLCMap(entries: ["col": hlc(physical: 500)])

        let (apply, _) = FieldLWWMerge.merge(
            incomingValues: incoming,
            incomingColumnHLCs: ColumnHLCMap(),
            incomingRowHLC: hlc(physical: 100), // row-grain is older
            localColumnHLCs: localColHLCs
        )
        #expect(apply["col"] == nil)
    }

    // MARK: Commutativity property test

    // Apply record A then B, or B then A: final state per column must match.
    // We simulate sequential application by running merge twice.
    @Test("commutativity: merge(A then B) == merge(B then A)")
    func mergeCommutativity() {
        // Two records with overlapping columns, each newer on one.
        let valuesA: [String: TypedValue] = ["title": .text("A"), "score": .int(10)]
        let colHLCsA = ColumnHLCMap(entries: [
            "title": hlc(physical: 300),
            "score": hlc(physical: 100),
        ])

        let valuesB: [String: TypedValue] = ["title": .text("B"), "body": .text("hello")]
        let colHLCsB = ColumnHLCMap(entries: [
            "title": hlc(physical: 200),
            "body":  hlc(physical: 400),
        ])

        // Path 1: apply A first, then B
        var localHLCs = ColumnHLCMap()
        let (applyA, afterA) = FieldLWWMerge.merge(
            incomingValues: valuesA,
            incomingColumnHLCs: colHLCsA,
            incomingRowHLC: hlc(physical: 300),
            localColumnHLCs: localHLCs
        )
        localHLCs = afterA
        // "apply A" results:
        _ = applyA

        let (_, afterAB) = FieldLWWMerge.merge(
            incomingValues: valuesB,
            incomingColumnHLCs: colHLCsB,
            incomingRowHLC: hlc(physical: 400),
            localColumnHLCs: localHLCs
        )

        // Path 2: apply B first, then A
        localHLCs = ColumnHLCMap()
        let (_, afterB) = FieldLWWMerge.merge(
            incomingValues: valuesB,
            incomingColumnHLCs: colHLCsB,
            incomingRowHLC: hlc(physical: 400),
            localColumnHLCs: localHLCs
        )
        localHLCs = afterB

        let (_, afterBA) = FieldLWWMerge.merge(
            incomingValues: valuesA,
            incomingColumnHLCs: colHLCsA,
            incomingRowHLC: hlc(physical: 300),
            localColumnHLCs: localHLCs
        )

        // Final column HLC maps must be identical
        #expect(afterAB == afterBA, "final column HLC maps must converge regardless of apply order")

        // Final HLC per column must reflect the winner:
        // title: A(300) > B(200) → A wins
        // score: A(100), not in B → A's
        // body:  B(400), not in A → B's
        #expect(afterAB.entries["title"] == hlc(physical: 300))
        #expect(afterAB.entries["score"] == hlc(physical: 100))
        #expect(afterAB.entries["body"]  == hlc(physical: 400))
    }
}

// MARK: - FieldLWWMerge.tombstoneWins

@Suite("FieldLWWMerge.tombstoneWins — edit-beats-delete")
struct FieldLWWTombstoneTests {

    @Test("empty local map → tombstone wins")
    func emptyLocalMap() {
        let wins = FieldLWWMerge.tombstoneWins(
            tombstoneHLC: hlc(physical: 0),
            localColumnHLCs: ColumnHLCMap()
        )
        #expect(wins == true)
    }

    @Test("tombstone HLC >= all local column HLCs → tombstone wins")
    func tombstoneGeAllLocalHLCs() {
        let localColHLCs = ColumnHLCMap(entries: [
            "title": hlc(physical: 100),
            "body":  hlc(physical: 150),
        ])
        // tombstone at T=200 beats both
        let wins = FieldLWWMerge.tombstoneWins(
            tombstoneHLC: hlc(physical: 200),
            localColumnHLCs: localColHLCs
        )
        #expect(wins == true)
    }

    @Test("tombstone HLC == all local column HLCs → tombstone wins (tie)")
    func tombstoneEqualsAllLocalHLCs() {
        let h = hlc(physical: 100)
        let localColHLCs = ColumnHLCMap(entries: [
            "col1": h,
            "col2": h,
        ])
        let wins = FieldLWWMerge.tombstoneWins(
            tombstoneHLC: h,
            localColumnHLCs: localColHLCs
        )
        #expect(wins == true, "tie: tombstone uses >= so it wins")
    }

    @Test("one local column HLC > tombstone HLC → edit beats delete")
    func oneColumnBeatsTombstone() {
        let localColHLCs = ColumnHLCMap(entries: [
            "title": hlc(physical: 100),
            "body":  hlc(physical: 500), // newer than tombstone
        ])
        let wins = FieldLWWMerge.tombstoneWins(
            tombstoneHLC: hlc(physical: 300),
            localColumnHLCs: localColHLCs
        )
        #expect(wins == false, "body was edited after delete; row must survive")
    }

    @Test("all local columns older than tombstone → tombstone wins")
    func allColumnsOlderThanTombstone() {
        let localColHLCs = ColumnHLCMap(entries: [
            "c1": hlc(physical: 10),
            "c2": hlc(physical: 20),
            "c3": hlc(physical: 30),
        ])
        let wins = FieldLWWMerge.tombstoneWins(
            tombstoneHLC: hlc(physical: 100),
            localColumnHLCs: localColHLCs
        )
        #expect(wins == true)
    }

    // Tombstone matrix: test all combinations of one-column scenarios
    @Test("tombstone matrix: 3×3 combinations of older / equal / newer")
    func tombstoneMatrix() {
        let tBase = hlc(physical: 100)

        // (localHLC, expected tombstone result)
        let cases: [(PackedHLC, Bool)] = [
            (hlc(physical: 50),  true),   // local older  → tombstone wins
            (hlc(physical: 100), true),   // local equal  → tombstone wins (tie → >=)
            (hlc(physical: 150), false),  // local newer  → edit beats delete
        ]

        for (localHLC, expected) in cases {
            let result = FieldLWWMerge.tombstoneWins(
                tombstoneHLC: tBase,
                localColumnHLCs: ColumnHLCMap(entries: ["col": localHLC])
            )
            #expect(result == expected,
                    "tombstone=\(tBase) local=\(localHLC): expected \(expected) got \(result)")
        }
    }
}
