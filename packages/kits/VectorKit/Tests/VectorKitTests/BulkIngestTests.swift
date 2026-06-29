import Testing
import EngramLib
import PersistenceKit
import PersistenceKitSQLite
import Foundation
@testable import VectorKit

/// Tests for the import/migration-scale bulk ingest path (TASK #24).
///
/// The acceptance contract: import-scale vector ingestion must be bounded in
/// both reachable modes — sidecar-less bulk import must avoid a per-row
/// full-index rebuild, and sidecar-backed import must avoid a per-row
/// whole-sidecar rewrite plus per-row index rebuild. The fix is the batch
/// `addPayloads(_:)` API (one sidecar write + one index build per batch) and
/// the write-behind single-add path (deferred sidecar flush).
///
/// These tests acquire GlobalTestLock for the telemetry-singleton reason
/// documented in VectorStoreTests.
@Suite("BulkIngest", .serialized)
struct BulkIngestTests {

    /// Deterministic binary engram for index i. Spreads bits across all four
    /// blocks so distances are non-trivial and the corpus is well separated.
    private func engram(_ i: Int) -> Engram {
        let u = UInt64(bitPattern: Int64(i)) &* 0x9E37_79B9_7F4A_7C15
        return Engram(blocks: u,
                      u ^ 0xFFFF_0000_FFFF_0000,
                      (u << 1) | 1,
                      ~u)
    }

    private func binaryInput(_ i: Int, model: String = "minilm", now: Date) -> VectorPayloadInput {
        VectorPayloadInput(
            itemID: "chunk-\(i)",
            vectorIndex: 0,
            payload: VectorPayload(engram: engram(i)),
            modelID: model,
            modelVersion: "1.0.0",
            filedAt: now
        )
    }

    private func sidecarURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vectorkit-bulk-\(UUID().uuidString).vec")
    }

    private func sqliteURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vectorkit-bulk-\(UUID().uuidString).sqlite3")
    }

    // ── Old-shape proof: per-row append writes N times, batch writes once ────

    /// TASK #24 old-shape proof at the ResidentArrayStore level: per-row eager
    /// `append` writes the sidecar once PER ROW (the O(N²) disease), whereas
    /// `appendBatch` writes it ONCE for the whole batch. This is the structural
    /// contrast the import-scale regression guards against.
    @Test func appendBatchWritesSidecarOnceVsPerRowAppend() async throws {
        let n = 64
        func bytes(_ i: Int) -> [UInt8] {
            VectorPayload(engram: engram(i)).bytes
        }
        func key(_ i: Int) -> VectorRecordKey {
            VectorRecordKey(itemID: "item-\(i)", vectorIndex: 0, modelID: "model-a", modelVersion: "1")
        }

        // Old shape: eager per-row append → N sidecar writes.
        let eagerURL = sidecarURL()
        defer { try? FileManager.default.removeItem(at: eagerURL) }
        let eager = ResidentArrayStore(sidecarURL: eagerURL)
        for i in 0..<n { try await eager.append(key: key(i), bytes: bytes(i)) }
        let eagerWrites = await eager.sidecarWriteCount
        #expect(eagerWrites == n,
                "per-row eager append must write the sidecar once per row (old O(N²) shape); got \(eagerWrites)")

        // New shape: one batch → exactly one sidecar write.
        let batchURL = sidecarURL()
        defer { try? FileManager.default.removeItem(at: batchURL) }
        let batched = ResidentArrayStore(sidecarURL: batchURL)
        let records = (0..<n).map { (key: key($0), bytes: bytes($0)) }
        try await batched.appendBatch(records: records)
        let batchWrites = await batched.sidecarWriteCount
        #expect(batchWrites == 1,
                "appendBatch must write the sidecar exactly once for the whole batch; got \(batchWrites)")

        #expect(await eager.snapshot().liveCount == UInt32(n))
        #expect(await batched.snapshot().liveCount == UInt32(n))
    }

    // ── (a) O(n²)-shape regression: sidecar writes are O(batches), not O(N) ──

    /// Import N=2000 binary vectors sidecar-backed through the batch API and
    /// assert the sidecar was written O(batches) times, not O(N). The OLD
    /// code shape (per-row tombstone+append) wrote the whole sidecar twice
    /// per row → ~4000 writes for N=2000; the batch path writes once per
    /// batch. A single batch must therefore cost exactly ONE sidecar write.
    ///
    /// This is the test that FAILS against the old shape: the old single-add
    /// loop's sidecar write count grows linearly with N, so the assertion
    /// `writeCount <= batches + small_constant` cannot hold for N=2000.
    @Test func bulkImportSidecarWriteCountIsBoundedByBatches() async throws {
        try await GlobalTestLock.shared.withLock {
            let dbURL = sqliteURL()
            let sideURL = sidecarURL()
            defer {
                try? FileManager.default.removeItem(at: dbURL)
                try? FileManager.default.removeItem(at: sideURL)
            }

            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage, sidecarURL: sideURL)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let n = 2000
            let batch = (0..<n).map { binaryInput($0, now: now) }

            let start = Date()
            try await store.addPayloads(batch)
            let elapsed = Date().timeIntervalSince(start)

            let writes = await store.sidecarWriteCount
            // One batch → the sidecar is written at most a small constant number
            // of times (one append; an extra write only if auto-compaction
            // fires, which it cannot here — no tombstones). The per-row old
            // shape would be ~2N. Bound generously at a small constant.
            #expect(writes <= 3,
                    "sidecar written \(writes) times for one batch of \(n) — expected O(batches), per-row shape would be ~\(2 * n)")
            // Coarse perf bound (e): well within the 3-min watchdog.
            #expect(elapsed < 60, "N=\(n) bulk ingest took \(elapsed)s")
            print("[BULK-INGEST] N=\(n) sidecar-backed batch: writes=\(writes) elapsed=\(String(format: "%.3f", elapsed))s")

            // Results are correct: every item is findable and exact self-match
            // ranks distance 0.
            let probe = engram(7)
            let matches = try await store.findNearest(probe: probe, modelID: "minilm", limit: 1)
            #expect(matches.first?.itemID == "chunk-7")
            #expect(matches.first?.distance == 0)
        }
    }

    /// Contrast proof: the per-row single-add loop, even after the write-behind
    /// fix, produces O(1) sidecar writes ONLY because of deferral — without a
    /// flush the sidecar is not written per row. With flush at the end the
    /// total is still O(1), not O(N). This demonstrates the single-add path is
    /// also bounded. (Documents the write-behind policy.)
    @Test func singleAddLoopDefersSidecarWritesUntilFlush() async throws {
        try await GlobalTestLock.shared.withLock {
            let dbURL = sqliteURL()
            let sideURL = sidecarURL()
            defer {
                try? FileManager.default.removeItem(at: dbURL)
                try? FileManager.default.removeItem(at: sideURL)
            }
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage, sidecarURL: sideURL)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let n = 500
            for i in 0..<n {
                try await store.addVector(itemID: "chunk-\(i)", engram: engram(i),
                                          modelID: "minilm", modelVersion: "1.0.0", filedAt: now)
            }
            // The write-behind single-add path does NOT write the sidecar per
            // row. The only sidecar write before flush is the one-time rebuild
            // on first use (the sidecar was absent, so _ensureIndexBuilt wrote
            // an initial empty/current file). That is O(1), independent of N.
            // The OLD per-row shape would be ~2N = ~1000 writes here.
            let writesBeforeFlush = await store.sidecarWriteCount
            #expect(writesBeforeFlush <= 2,
                    "write-behind single-add must not write the sidecar per row; got \(writesBeforeFlush) for N=\(n) (per-row shape would be ~\(2 * n))")
            try await store.flush()
            let writesAfterFlush = await store.sidecarWriteCount
            #expect(writesAfterFlush <= writesBeforeFlush + 1,
                    "flush adds at most one sidecar write; got \(writesAfterFlush)")
            print("[BULK-INGEST] single-add loop N=\(n): writes before flush=\(writesBeforeFlush) after flush=\(writesAfterFlush)")
        }
    }

    // ── (b) Sidecar-less bulk: one index build, not per-row ──────────────────

    /// Sidecar-less (memory-only) bulk import: all results correct after a
    /// single batch, and the batch crosses the MIH threshold so the active
    /// index switches once. Correctness here proves the single-build path
    /// produces the same answers as per-row adds (the MIH==BF gate covers
    /// equality of the two indexes).
    @Test func sidecarlessBulkImportBuildsOnceAndIsCorrect() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            // Low threshold so the batch promotes to MIH; both indexes must
            // still agree (conformance gate) and findNearest stays exact.
            let store = VectorStore(storage: storage, sidecarURL: nil, mihThreshold: 100)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let n = 300
            let batch = (0..<n).map { binaryInput($0, now: now) }
            try await store.addPayloads(batch)

            // Every item findable; self-match exact.
            for i in stride(from: 0, to: n, by: 37) {
                let m = try await store.findNearest(probe: engram(i), modelID: "minilm", limit: 1)
                #expect(m.first?.itemID == "chunk-\(i)")
                #expect(m.first?.distance == 0)
            }
            // No sidecar → write count passthrough is 0.
            let writes = await store.sidecarWriteCount
            #expect(writes == 0)
        }
    }

    /// Memory-only deferred-index window (no sidecar): begin → SEVERAL
    /// addPayloads (one per simulated drain pass) → publish must rebuild the
    /// index ONCE and recover every vector. This is the path the CorpusKit
    /// ingest drain exercises in serve (resident array is memory-only). Without
    /// deferral each addPayloads would rebuild; with it, the records accumulate
    /// and publish merges them in one pass.
    @Test func memoryOnlyDeferredWindowMergesAllPassesOnce() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage, sidecarURL: nil, mihThreshold: 100)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let n = 300
            try await store.beginDeferredIndex()
            // Three "drain passes" worth of writes inside one deferred window.
            try await store.addPayloads((0..<100).map { binaryInput($0, now: now) })
            try await store.addPayloads((100..<200).map { binaryInput($0, now: now) })
            try await store.addPayloads((200..<n).map { binaryInput($0, now: now) })
            try await store.publishResidentIndex()

            // Every item findable after the single publish; self-match exact.
            for i in stride(from: 0, to: n, by: 37) {
                let m = try await store.findNearest(probe: engram(i), modelID: "minilm", limit: 1)
                #expect(m.first?.itemID == "chunk-\(i)")
                #expect(m.first?.distance == 0)
            }
        }
    }

    // ── (c) Crash-safety: kill mid-batch (drop before flush), reopen ─────────

    /// Single-add write-behind path, process killed before flush: the sidecar
    /// is stale/absent but the `vectors` table holds every row. A NEW
    /// VectorStore over the same files must rebuild from the table on first
    /// use, recover the exact count, and findNearest must still work.
    @Test func crashBeforeFlushRecoversFromTable() async throws {
        try await GlobalTestLock.shared.withLock {
            let dbURL = sqliteURL()
            let sideURL = sidecarURL()
            defer {
                try? FileManager.default.removeItem(at: dbURL)
                try? FileManager.default.removeItem(at: sideURL)
            }
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let n = 200

            // Session 1: write rows via the deferred single-add path, then DROP
            // the store WITHOUT flushing (simulates a crash mid-batch).
            do {
                let storage = try SQLiteStorage(configuration: EstateConfiguration(
                    estateID: UUID(), backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
                try await storage.open(schema: VectorStore.schemaDeclaration)
                let store = VectorStore(storage: storage, sidecarURL: sideURL)
                for i in 0..<n {
                    try await store.addVector(itemID: "chunk-\(i)", engram: engram(i),
                                              modelID: "minilm", modelVersion: "1.0.0", filedAt: now)
                }
                // NO flush — the sidecar on disk is stale (absent or short).
            }

            // Session 2: reopen. The table is the durable source; the resident
            // index must rebuild from it because the sidecar live-count
            // disagrees with the table row count.
            let storage = try SQLiteStorage(configuration: EstateConfiguration(
                estateID: UUID(), backend: .sqlite(url: dbURL, busyTimeout: 5.0)))
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let reopened = VectorStore(storage: storage, sidecarURL: sideURL)

            // Force the lazy build, then assert recovery.
            let m = try await reopened.findNearest(probe: engram(123), modelID: "minilm", limit: 1)
            #expect(m.first?.itemID == "chunk-123")
            #expect(m.first?.distance == 0)
            let rebuilds = await reopened.sidecarRebuildCount
            #expect(rebuilds >= 1, "stale sidecar must trigger a table rebuild; got \(rebuilds)")

            // Every row recovered: count distinct findable items.
            var found = 0
            for i in 0..<n {
                let r = try await reopened.findNearest(probe: engram(i), modelID: "minilm", limit: 1)
                if r.first?.itemID == "chunk-\(i)" && r.first?.distance == 0 { found += 1 }
            }
            #expect(found == n, "recovered \(found)/\(n) rows from the table")
        }
    }

    // ── (d) MIH==BruteForce still agree across a bulk-imported corpus ────────

    /// After a bulk import that crosses the threshold, the active MIH index
    /// must agree bit-for-bit with the brute-force oracle for a range of
    /// probes and k. This guards the conformance contract through the new
    /// batch build path.
    @Test func mihAgreesWithBruteForceAfterBulkImport() async throws {
        try await GlobalTestLock.shared.withLock {
            // Two stores over the same logical corpus: one pinned to brute
            // force (huge threshold), one promoted to MIH (low threshold).
            let storageBF = try makeScratchStorage()
            try await storageBF.open(schema: VectorStore.schemaDeclaration)
            let bf = VectorStore(storage: storageBF, sidecarURL: nil, mihThreshold: 1_000_000)

            let storageMIH = try makeScratchStorage()
            try await storageMIH.open(schema: VectorStore.schemaDeclaration)
            let mih = VectorStore(storage: storageMIH, sidecarURL: nil, mihThreshold: 50)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let n = 400
            let batch = (0..<n).map { binaryInput($0, now: now) }
            try await bf.addPayloads(batch)
            try await mih.addPayloads(batch)

            for seed in [0, 11, 199, 333, 399] {
                for k in [1, 5, 10] {
                    let probe = engram(seed)
                    let a = try await bf.findNearest(probe: probe, modelID: "minilm", limit: k)
                    let b = try await mih.findNearest(probe: probe, modelID: "minilm", limit: k)
                    #expect(a.map(\.itemID) == b.map(\.itemID), "seed=\(seed) k=\(k) itemID order")
                    #expect(a.map(\.distance) == b.map(\.distance), "seed=\(seed) k=\(k) distances")
                }
            }
        }
    }

    // ── (e) Float lane in a mixed batch invalidates and rebuilds correctly ───

    /// A batch mixing binary (vector_index 0) and float32 (vector_index 1)
    /// rows under the same item ids: the binary lane is searchable and the
    /// float lane rebuilds lazily and returns matches.
    @Test func mixedBinaryAndFloatBatch() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage, sidecarURL: nil, mihThreshold: 1_000_000)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            // Each float vector is unique (the i-th component is large), so the
            // self-match is unambiguous under cosine + (distance, itemID) tie-break.
            func floatVec(_ i: Int) -> [Float] {
                var v = [Float](repeating: 0.1, count: 8)
                v[i % 8] = Float(i) + 10.0
                return v
            }
            var batch: [VectorPayloadInput] = []
            for i in 0..<50 {
                batch.append(binaryInput(i, now: now))
                batch.append(VectorPayloadInput(
                    itemID: "chunk-\(i)", vectorIndex: 1,
                    payload: VectorPayload(floats: floatVec(i)),
                    modelID: "minilm", modelVersion: "1.0.0", filedAt: now))
            }
            try await store.addPayloads(batch)

            let bin = try await store.findNearest(probe: engram(3), modelID: "minilm", limit: 1)
            #expect(bin.first?.itemID == "chunk-3")

            // Float self-match: probe with chunk-3's exact float vector. Cosine
            // distance 0 to itself, so chunk-3 ranks first.
            let fl = try await store.findNearestFloat(probe: floatVec(3), modelID: "minilm", limit: 3)
            #expect(!fl.isEmpty)
            #expect(fl.first?.itemID == "chunk-3")
        }
    }

    // ── Finding 2: deferred buffer back-pressure (secfix/punt-vector) ─────────

    /// The memory-only deferred buffer must flush before growing without bound.
    ///
    /// Uses a custom `deferredPendingLimit = 100` so the flush triggers after
    /// 100 records. Sends 300 records in 50-record batches (→ three flush
    /// events during the deferred window). After `publishResidentIndex`, every
    /// seeded item must be retrievable at distance 0.
    ///
    /// This test verifies the `_flushDeferredPending` code path is reachable and
    /// leaves the index in a consistent state.
    @Test func deferredBufferBackPressureFlushesAndStaysCorrect() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            // Low deferredPendingLimit (100) so flush triggers frequently at
            // small scale. Low mihThreshold to avoid MIH build overhead.
            let store = VectorStore(storage: storage, sidecarURL: nil,
                                    mihThreshold: 10_000,
                                    deferredPendingLimit: 100)

            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let total = 300
            let batchSize = 50

            try await store.beginDeferredIndex()

            // Send records in batches of 50; three batches will exceed the limit.
            for start in stride(from: 0, to: total, by: batchSize) {
                let end = min(start + batchSize, total)
                let batch = (start..<end).map { binaryInput($0, now: now) }
                try await store.addPayloads(batch)
            }
            try await store.publishResidentIndex()

            // Every 37th item must be findable at distance 0 after flushed publish.
            for i in stride(from: 0, to: total, by: 37) {
                let results = try await store.findNearest(
                    probe: engram(i), modelID: "minilm", limit: 1)
                #expect(results.first?.itemID == "chunk-\(i)",
                        "chunk-\(i) must be findable after back-pressure flush")
                #expect(results.first?.distance == 0,
                        "self-match for chunk-\(i) must be distance 0")
            }
        }
    }

    // ── Finding 1 (via deferred path): same-itemID both survive ──────────────

    /// Two binary vectors sharing the same itemID but different vectorIndex
    /// must both survive and be retrievable when added through the deferred
    /// (beginDeferredIndex / publishResidentIndex) code path.
    ///
    /// This gates the MIH-collision fix through `_mergeBatchIntoSnapshot`,
    /// which is the merge engine the deferred path uses.
    @Test func deferredWindowSameItemIDBothSurvive() async throws {
        try await GlobalTestLock.shared.withLock {
            let storage = try makeScratchStorage()
            try await storage.open(schema: VectorStore.schemaDeclaration)
            let store = VectorStore(storage: storage, sidecarURL: nil)
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            try await store.beginDeferredIndex()

            // Two distinct vectors under the same itemID, different vectorIndex.
            // vec0 = all-zeros → distance 0 to zero probe
            // vec1 = 1 bit set → distance 1 to zero probe
            let batch: [VectorPayloadInput] = [
                VectorPayloadInput(itemID: "shared-item", vectorIndex: 0,
                                   payload: VectorPayload(engram: Engram(blocks: 0, 0, 0, 0)),
                                   modelID: "test-model", modelVersion: "1", filedAt: now),
                VectorPayloadInput(itemID: "shared-item", vectorIndex: 1,
                                   payload: VectorPayload(engram: Engram(blocks: 1, 0, 0, 0)),
                                   modelID: "test-model", modelVersion: "1", filedAt: now),
            ]
            try await store.addPayloads(batch)
            try await store.publishResidentIndex()

            // Query with the zero-vector; both slots must appear in the k=4 result.
            let hits = try await store.findNearest(
                probe: Engram(blocks: 0, 0, 0, 0), modelID: "test-model", limit: 4)

            #expect(hits.count == 2,
                    "both same-itemID entries must survive after deferred publish; got \(hits.count)")
            // vec0 (distance 0) must rank first.
            #expect(hits[0].itemID == "shared-item")
            #expect(hits[0].distance == 0, "zero-distance slot must rank first")
            // vec1 (distance 1) must rank second.
            #expect(hits[1].itemID == "shared-item")
            #expect(hits[1].distance == 1, "one-bit-set slot must rank second")
        }
    }
}
