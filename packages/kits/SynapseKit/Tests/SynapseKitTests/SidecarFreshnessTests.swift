// SidecarFreshnessTests.swift
//
// SYN-1: the .vec sidecar freshness check must count the SAME row set the
// sidecar is built from — serving-generation binary rows — not every binary
// row in the table.
//
// After a shadow swap publishes, the superseded generation's rows stay in the
// `vectors` table as 'pending-reclaim' until reclaimSupersededGenerations runs.
// The sidecar (rebuilt by publish) holds only the new serving rows. A freshness
// check that counts all binary rows sees 2N against a sidecar liveCount of N and
// reports the sidecar stale on every open of such an estate: a full table read,
// a resident-array rebuild, and a sidecar rewrite per process start — while the
// Rust port, counting with the serving-generation predicate, loads the sidecar
// directly. Both ports now apply the serving-generation predicate to the count.
//
// Twin: rust/tests/sidecar_freshness_tests.rs.
//
// SEC-RECALL (2026-09-07 scan, finding 4e8fe9996): the count alone cannot
// tell a sidecar built from the previous generation apart from the current
// one when the two generations hold the same number of rows. The sidecar
// header now carries the serving-generation stamp, and a fresh open rejects
// a sidecar whose stamp differs from the registry even at equal counts.

import Testing
import Foundation
import EngramLib
import PersistenceKit
@testable import SynapseKit

@Suite("SidecarFreshness", .serialized)
struct SidecarFreshnessTests {

    private static let modelID = "sidecar-freshness"
    private static let filedAt = Date(timeIntervalSince1970: 1_700_000_000)

    /// Distinct fingerprints: old-i lives in block0, new-i in block3, so the
    /// two generations never collide on distance and the probe (new-0) ranks
    /// the serving rows unambiguously.
    private static func oldEngram(_ i: UInt64) -> Engram { Engram(blocks: 0x0101 << i, 0, 0, 0) }
    private static func newEngram(_ i: UInt64) -> Engram { Engram(blocks: 0, 0, 0, 0x8080 << i) }

    private static func write(_ store: VectorStore, itemID: String, engram: Engram) async throws {
        try await store.addPayload(itemID: itemID, vectorIndex: 0,
                                   payload: VectorPayload(engram: engram),
                                   modelID: modelID, modelVersion: "v1", filedAt: filedAt)
    }

    /// Reopen after publish (superseded rows pending reclaim): the sidecar is
    /// current, so the new store loads it without a rebuild and serves exactly
    /// the serving-generation rows.
    ///
    /// Pre-fix failure: `sidecarRebuildCount == 1` — _binaryRowCount returned
    /// 10 (both generations) against the sidecar's liveCount of 5.
    @Test("reopen after publish with pending-reclaim rows loads the sidecar without a rebuild")
    func reopenAfterPublishDoesNotRebuildTheSidecar() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let sidecar = FileManager.default.temporaryDirectory
                .appendingPathComponent("synapsekit-sidecar-freshness-\(UUID().uuidString).vec")
            defer { try? FileManager.default.removeItem(at: sidecar) }

            // Store A: 5 serving rows (generation 0), then a shadow swap that
            // publishes 5 new rows. Publish rebuilds the resident array from the
            // new serving rows and rewrites the sidecar; the gen-0 rows remain
            // in the table as 'pending-reclaim'.
            let storeA = VectorStore(storage: storage, sidecarURL: sidecar)
            for i in 0..<5 { try await Self.write(storeA, itemID: "old-\(i)", engram: Self.oldEngram(UInt64(i))) }
            _ = try await storeA.beginShadowGeneration(modelIDs: [Self.modelID])
            for i in 0..<5 { try await Self.write(storeA, itemID: "new-\(i)", engram: Self.newEngram(UInt64(i))) }
            try await storeA.publishShadowGeneration(modelIDs: [Self.modelID])
            try await storeA.flush()

            // Precondition: both generations are physically present (10 binary rows).
            let allBinaryRows = try await storage.rowStore.query(
                table: "vectors",
                where: .eq(Column(table: "vectors", name: "kind"), .int(Int64(VectorKind.binary.rawValue))),
                orderBy: [], limit: nil, offset: nil)
            #expect(allBinaryRows.count == 10, "precondition: superseded rows must still be pending reclaim")

            // Store B: a fresh open over the same table and sidecar.
            let storeB = VectorStore(storage: storage, sidecarURL: sidecar)
            let hits = try await storeB.findNearest(probe: Self.newEngram(0), modelID: Self.modelID, limit: 10)
            let ids = Set(hits.map(\.itemID))
            #expect(ids == Set((0..<5).map { "new-\($0)" }),
                    "reopen must serve exactly the serving-generation rows; got \(ids.sorted())")

            let rebuilds = await storeB.sidecarRebuildCount
            #expect(rebuilds == 0,
                    "sidecar was current (liveCount 5 == 5 serving-generation binary rows) but was rebuilt \(rebuilds) time(s): the freshness count must apply the serving-generation predicate")
        }
    }

    /// A publish flip that committed but never rebuilt the sidecar (the
    /// process died between the two): the durable registry serves the new
    /// generation, the sidecar still holds the old one, and both hold five
    /// rows. A fresh open must rebuild from the table and serve the new rows.
    ///
    /// Pre-fix failure: `sidecarRebuildCount == 0` and the hits were the
    /// `old-*` ids: liveCount 5 == 5 serving rows accepted the stale sidecar.
    @Test("an equal-count sidecar from the previous generation is rebuilt on reopen")
    func equalCountStaleGenerationSidecarIsRebuilt() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let sidecar = FileManager.default.temporaryDirectory
                .appendingPathComponent("synapsekit-sidecar-generation-\(UUID().uuidString).vec")
            defer { try? FileManager.default.removeItem(at: sidecar) }

            // Store A: 5 serving rows (generation 0) flushed to the sidecar,
            // then a shadow build with 5 new rows that is NOT published
            // through the store.
            let storeA = VectorStore(storage: storage, sidecarURL: sidecar)
            for i in 0..<5 { try await Self.write(storeA, itemID: "old-\(i)", engram: Self.oldEngram(UInt64(i))) }
            try await storeA.flush()
            _ = try await storeA.beginShadowGeneration(modelIDs: [Self.modelID])
            for i in 0..<5 { try await Self.write(storeA, itemID: "new-\(i)", engram: Self.newEngram(UInt64(i))) }
            try await storeA.flush()

            // The registry flip alone, exactly the first transaction of
            // publishShadowGeneration, with the sidecar rebuild that follows
            // it never reached: serving_generation = shadow_generation, the
            // shadow cleared.
            let registry = try await storage.rowStore.query(
                table: "vector_generations", where: .isTrue, orderBy: [], limit: nil, offset: nil)
            let row = try #require(registry.first { row in
                if case let .text(m) = row["model_id"] ?? .null { return m == Self.modelID }
                return false
            })
            guard case let .int(shadow) = row["shadow_generation"] ?? .null else {
                Issue.record("precondition: the shadow generation is registered")
                return
            }
            _ = try await storage.rowStore.upsert(
                table: "vector_generations",
                values: [
                    "model_id":           .text(Self.modelID),
                    "serving_generation": .int(shadow),
                    "shadow_generation":  .null,
                    "shadow_state":       .text("pending-reclaim"),
                ],
                conflictColumns: ["model_id"])

            // Store B: a fresh open. Five sidecar rows (old generation)
            // against five serving rows (new generation): the counts agree,
            // the stamps do not.
            let storeB = VectorStore(storage: storage, sidecarURL: sidecar)
            let hits = try await storeB.findNearest(probe: Self.newEngram(0), modelID: Self.modelID, limit: 10)
            let ids = Set(hits.map(\.itemID))
            #expect(ids == Set((0..<5).map { "new-\($0)" }),
                    "a reopen after an unfinished publish must serve the new generation, not the stale sidecar; got \(ids.sorted())")
            let rebuilds = await storeB.sidecarRebuildCount
            #expect(rebuilds == 1, "the stale-generation sidecar was rebuilt exactly once; got \(rebuilds)")

            // The rebuilt sidecar carries the new stamp: a third open accepts it.
            let storeC = VectorStore(storage: storage, sidecarURL: sidecar)
            _ = try await storeC.findNearest(probe: Self.newEngram(0), modelID: Self.modelID, limit: 10)
            let rebuildsC = await storeC.sidecarRebuildCount
            #expect(rebuildsC == 0, "the rebuilt sidecar is current")
        }
    }
}
