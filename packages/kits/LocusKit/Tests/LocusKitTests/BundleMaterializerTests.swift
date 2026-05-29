// BundleMaterializerTests.swift
//
// Tests for the Bundle A materialization, the first real caller of
// countFold256. The keystone is that the wing roll-up, computed by
// merging the stored room bundles through a blob round-trip, equals the
// direct fold of every active drawer in the wing. That exercises the
// whole pipeline (derive, fold, serialize, store, read, merge) and
// proves the lossless tree composition holds end to end.

import Foundation
import SubstrateTypes
import Testing
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
@testable import LocusKit

@Suite("BundleMaterializerTests")
struct BundleMaterializerTests {

    private let estateUUID = "33333333-3333-3333-3333-333333333333"

    private func makeStores() async throws -> (DrawerStore, NodeBundleStore, URL) {
        let url = TestStorage.tempURL()
        let storage = TestStorage.sqlite(url)
        let drawers = try await DrawerStore(storage: storage)
        let bundles = try await NodeBundleStore(storage: storage)
        return (drawers, bundles, url)
    }

    private func drawer(id: String, room: String, adjective: Int64) -> Drawer {
        let lineage = "00000000-0000-0000-0000-0000000000" + String(id.suffix(2))
        let lineageID = UUID(uuidString: lineage) ?? UUID()
        let content = "c-" + id
        return Drawer(id: TestStorage.tid(id), content: content, wing: "w", room: room, addedBy: "test",
                      filedAt: Date(timeIntervalSince1970: 1_700_000_000),
                      embeddingModelID: "m",
                      adjectiveBitmap: adjective,
                      lineageID: lineageID)
    }

    // MARK: - Count-vector blob round-trip

    @Test("Count-vector survives the blob encode/decode round-trip")
    func countsBlobRoundTrip() throws {
        var fps: [Fingerprint256] = []
        for i in 0..<50 {
            let u = UInt64(i)
            fps.append(Fingerprint256(block0: u &* 2_862_933_555_777_941_757,
                                      block1: u &* 3_037_000_493,
                                      block2: u &* 7,
                                      block3: u))
        }
        let cv = CountVector256.fold(fps)
        let data = NodeBundleStore.encodeCounts(cv)
        #expect(data.count == 1024)
        #expect(try NodeBundleStore.decodeCounts(data, n: cv.n) == cv)
    }

    @Test("decodeCounts throws LocusKitError.invalidContent on a wrong-sized blob")
    func decodeCountsThrowsOnMalformedBlob() {
        // Pre-F12 this trapped via `precondition`, taking the process down
        // on a corrupt or empty bundles row; post-fix it surfaces a typed
        // error so callers can recover. Both the empty blob (Data() that
        // `blobValue` returns on a missing/mistyped cell) and a wrong-
        // sized blob trigger the same case.
        #expect(throws: LocusKitError.self) {
            _ = try NodeBundleStore.decodeCounts(Data(), n: 0)
        }
        #expect(throws: LocusKitError.self) {
            _ = try NodeBundleStore.decodeCounts(Data(repeating: 0, count: 256), n: 0)
        }
    }

    // MARK: - Room materialization

    @Test("materializeRoom folds the room's active drawers and stores it")
    func materializeRoomFoldsActiveDrawers() async throws {
        let (drawers, bundles, url) = try await makeStores()
        defer { TestStorage.cleanup(url) }
        let families = EstateFingerprintFamilies(estateUUID: estateUUID)

        let ds = [drawer(id: "01", room: "r1", adjective: 0x01 << 26),
                  drawer(id: "02", room: "r1", adjective: 0x02 << 26),
                  drawer(id: "03", room: "r1", adjective: 0x04 << 26)]
        for d in ds { try await drawers.addDrawer(d) }

        let mat = BundleMaterializer(drawers: drawers, bundles: bundles, families: families)
        let cv = try await mat.materializeRoom(wing: "w", room: "r1")

        // The stored bundle equals the freshly folded one, and equals
        // the direct fold of the three derived fingerprints.
        let expected = CountVector256.fold(ds.map { families.fingerprint(of: $0) })
        #expect(cv == expected)
        #expect(cv.n == 3)
        let stored = try await bundles.get(wing: "w", room: "r1", kind: .activeA)
        #expect(stored == cv)
    }

    @Test("materializeRoom excludes non-Cluster-A drawers from Bundle A")
    func materializeRoomFiltersToClusterA() async throws {
        let (drawers, bundles, url) = try await makeStores()
        defer { TestStorage.cleanup(url) }
        let families = EstateFingerprintFamilies(estateUUID: estateUUID)

        // Six drawers, all captured as active (cluster A). Three stay
        // active; three are then transitioned to withdrawn / decayed /
        // expired (cluster B) via mutateState — the legal one-hop
        // transitions from active per cookbook §9.3.
        let clusterARows = [
            drawer(id: "a1", room: "r1", adjective: 0),
            drawer(id: "a2", room: "r1", adjective: 0),
            drawer(id: "a3", room: "r1", adjective: 0),
        ]
        let willMoveOut = [
            drawer(id: "b1", room: "r1", adjective: 0),
            drawer(id: "b2", room: "r1", adjective: 0),
            drawer(id: "b3", room: "r1", adjective: 0),
        ]
        for d in clusterARows + willMoveOut {
            try await drawers.addDrawer(d)
        }
        try await drawers.mutateState(drawerId: willMoveOut[0].id,
                                      to: .withdrawn, via: .retract,
                                      changedBy: "test")
        try await drawers.mutateState(drawerId: willMoveOut[1].id,
                                      to: .decayed,   via: .decay,
                                      changedBy: "test")
        try await drawers.mutateState(drawerId: willMoveOut[2].id,
                                      to: .expired,   via: .expire,
                                      changedBy: "test")

        let mat = BundleMaterializer(drawers: drawers, bundles: bundles, families: families)
        let cv = try await mat.materializeRoom(wing: "w", room: "r1")

        // Bundle A folds only the three cluster-A rows. Their
        // fingerprints depend on the post-mutation adjective bitmap,
        // so we fetch the transitioned drawers and compare against
        // the un-mutated cluster-A trio.
        let expected = CountVector256.fold(clusterARows.map { families.fingerprint(of: $0) })
        #expect(cv == expected)
        #expect(cv.n == 3)

        // Sanity check: a fold over ALL six (i.e. what the pre-fix
        // path produced) differs from the cluster-A-only fold, so
        // this test would have failed before the filter landed.
        let postMutation: [Drawer] = try await {
            var out: [Drawer] = []
            for d in willMoveOut {
                if let fresh = try await drawers.getDrawer(id: d.id) {
                    out.append(fresh)
                }
            }
            return out
        }()
        let allSix = clusterARows + postMutation
        let allFold = CountVector256.fold(allSix.map { families.fingerprint(of: $0) })
        #expect(cv != allFold)
    }

    @Test("An unmaterialized node reads back as nil")
    func absentNodeIsNil() async throws {
        let (_, bundles, url) = try await makeStores()
        defer { TestStorage.cleanup(url) }
        let got = try await bundles.get(wing: "w", room: "nope", kind: .activeA)
        #expect(got == nil)
    }

    // MARK: - Wing roll-up equals direct fold (the keystone)

    @Test("Wing roll-up of stored room bundles equals the direct fold of all active drawers")
    func wingRollUpEqualsDirectFold() async throws {
        let (drawers, bundles, url) = try await makeStores()
        defer { TestStorage.cleanup(url) }
        let families = EstateFingerprintFamilies(estateUUID: estateUUID)

        // Two rooms, uneven membership.
        let r1 = [drawer(id: "11", room: "r1", adjective: 0x01 << 26),
                  drawer(id: "12", room: "r1", adjective: 0x02 << 26)]
        let r2 = [drawer(id: "21", room: "r2", adjective: 0x10 << 26),
                  drawer(id: "22", room: "r2", adjective: 0x20 << 26),
                  drawer(id: "23", room: "r2", adjective: 0x40 << 26)]
        for d in r1 + r2 { try await drawers.addDrawer(d) }

        let mat = BundleMaterializer(drawers: drawers, bundles: bundles, families: families)
        try await mat.materializeRoom(wing: "w", room: "r1")
        try await mat.materializeRoom(wing: "w", room: "r2")
        let wingCV = try await mat.rollUpWing(wing: "w")

        // Direct fold of every active drawer in the wing.
        let allActive = try await drawers.drawersIn(wing: "w")
        let directCV = CountVector256.fold(allActive.map { families.fingerprint(of: $0) })

        #expect(wingCV == directCV)
        #expect(wingCV.n == 5)

        // The wing roll-up is stored under room == "".
        let storedWing = try await bundles.get(wing: "w", room: "", kind: .activeA)
        #expect(storedWing == wingCV)
    }
}
