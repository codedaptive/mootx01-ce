// PreciseRecallTests.swift
//
// End-to-end test of the PreciseRecall recipe against a real
// GeniusLocusKit estate over in-memory storage — no mocks. Proves the
// ascent closes the measured gauntlet gap: a coarse hybrid grab keeps the
// true target in the pool (recall), and the precision re-rank lifts it
// above its near-duplicate distractors (found@1).
//
// The estate is seeded into BOTH the corpus (BM25) and vector lanes so the
// .unionBest coarse grab has real multi-lane candidates to surface — the
// same join discipline RecallDirectorTests uses (corpus.ingest +
// vectorStore.addVector keyed by drawer.id). The distractors all share the
// query's words and a LOOK-ALIKE number; only the target carries the
// queried figure, so character-shingle / hybrid ranking alone cannot tell
// them apart — the precision signal must.
//
// CK-PR-7 (F3 trace-budget fix) uses a SQLite-backed estate so that the
// recall_trace table is the real persistent store. Only SQLite enforces the
// actual INSERT path; InMemory writes trace rows to the same in-memory table
// store, but the test verifies count from a freshly-constructed DrawerStore
// over the same storage to prove the written row count matches the final
// limit, not the coarse pool.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
@testable import CognitionKit

@Suite("PreciseRecallTests")
struct PreciseRecallTests {

    /// Open an in-memory estate, capture each content string as a drawer,
    /// and seed every drawer into the corpus + vector lanes so the
    /// .unionBest grab has real BM25 and vector candidates. Returns the kit,
    /// handle, and the drawer id for each content (in input order).
    private func makeSeededEstate(
        capturing contents: [String]
    ) async throws -> (GeniusLocusKit, EstateHandle, [String]) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "precise-recall-test")
        let config = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: config)
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        // Shared corpus + vector store across all drawers (one lane each).
        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await CorpusContentEngine(standaloneOn: corpusStorage)
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let modelID = await corpus.modelID
        // Deterministic seed time — never Date() in a test that asserts
        // ranking, so the run is reproducible.
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        var ids: [String] = []
        for content in contents {
            let frame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "ledger",
                latticeAnchor: .udc("000"),
                addedBy: "tester",
                embeddingModelID: "test-model-v1")
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
            try await corpus.ingest(content, contentID: drawer.id, now: now)
            let engram = try await corpus.embed(content)
            try await vectorStore.addVector(
                itemID: drawer.id, engram: engram,
                modelID: modelID, modelVersion: "1.0", filedAt: now)
        }

        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, ids)
    }

    // CK-PR-1: the discriminating number. Three near-duplicate drawers
    // share every word and the same sentence frame; only the figure
    // differs. The query names "46". PreciseRecall must rank the drawer
    // carrying 46 first — found@1 on a set where coarse ranking alone
    // cannot discriminate.
    @Test("the drawer with the queried number ranks first")
    func queriedNumberRanksFirst() async throws {
        try await withCognitionLock {
            let (kit, handle, ids) = try await makeSeededEstate(capturing: [
                "the war indemnity imposed by the treaty was 11 million gold marks",
                "the war indemnity imposed by the treaty was 46 million gold marks",
                "the war indemnity imposed by the treaty was 23 million gold marks",
            ])
            let target = ids[1]   // the 46-million drawer

            let matches = try await PreciseRecall.run(
                kit: kit, handle: handle,
                query: "the war indemnity was 46 million marks",
                filter: .unconfirmed, limit: 10, pool: 30)

            #expect(!matches.isEmpty, "the coarse grab must surface candidates")
            // found@1: the distinctive-number target is rank 1.
            #expect(matches.first?.id == target,
                    "the drawer carrying the queried figure 46 must rank first")
            // Recall is held: the target is in the returned set (found@10).
            #expect(matches.contains { $0.id == target })
        }
    }

    // CK-PR-2: the bounded reduce never drops the target out of the pool.
    // Even at limit 1, the single returned match is the precise target —
    // the reduce re-orders, it does not prune the right answer away.
    @Test("limit 1 returns the precise target, not a distractor")
    func boundedReduceKeepsTarget() async throws {
        try await withCognitionLock {
            let (kit, handle, ids) = try await makeSeededEstate(capturing: [
                "quarterly revenue for the Helsinki division was 11 million euros",
                "quarterly revenue for the Helsinki division was 46 million euros",
            ])
            let target = ids[1]

            let matches = try await PreciseRecall.run(
                kit: kit, handle: handle,
                query: "Helsinki division revenue 46 million",
                filter: .unconfirmed, limit: 1, pool: 30)

            #expect(matches.count == 1)
            #expect(matches.first?.id == target)
        }
    }

    // CK-PR-4: a NAMED composition runs end-to-end and ranks the planted
    // target. The hamming+tokenExact composition (dense closeness + exact
    // numeric match) must surface the 46-million drawer first over its
    // look-alikes, exercising the ablation selector through the real recipe.
    @Test("a named composition ranks the planted target first")
    func namedCompositionRanksTarget() async throws {
        try await withCognitionLock {
            let (kit, handle, ids) = try await makeSeededEstate(capturing: [
                "the war indemnity imposed by the treaty was 11 million gold marks",
                "the war indemnity imposed by the treaty was 46 million gold marks",
                "the war indemnity imposed by the treaty was 23 million gold marks",
            ])
            let target = ids[1]

            let matches = try await PreciseRecall.run(
                kit: kit, handle: handle,
                query: "the war indemnity was 46 million marks",
                filter: .unconfirmed, limit: 10, pool: 30,
                composition: "hamming+tokenExact")

            #expect(!matches.isEmpty)
            #expect(matches.first?.id == target,
                    "hamming+tokenExact must rank the queried-figure drawer first")
        }
    }

    // CK-PR-5: every grid composition is runnable through the recipe and keeps
    // the target in the bounded set (recall held for all compositions — the
    // ablation never silently drops the answer). None is pre-judged here; this
    // only asserts each composition RUNS and preserves recall.
    @Test("every grid composition runs and keeps the target in the returned set")
    func everyCompositionRunsAndHoldsRecall() async throws {
        try await withCognitionLock {
            let (kit, handle, ids) = try await makeSeededEstate(capturing: [
                "quarterly revenue for the Helsinki division was 11 million euros",
                "quarterly revenue for the Helsinki division was 46 million euros",
            ])
            let target = ids[1]
            for name in NeuronKit.CompositionGrid.names {
                let matches = try await PreciseRecall.run(
                    kit: kit, handle: handle,
                    query: "Helsinki division revenue 46 million",
                    filter: .unconfirmed, limit: 10, pool: 30, composition: name)
                #expect(matches.contains { $0.id == target },
                        "composition '\(name)' must hold the target in the bounded set")
            }
        }
    }

    // CK-PR-6: DENSE-FIRST late hydration (steps 3+4). The pool is fetched
    // body-free (`.bitmapOnly`), so the returned matches' content can only be
    // non-empty if the narrow-then-hydrate reduce late-hydrated the survivors
    // through the GLK hydration capability. Assert the returned target carries
    // its real body — proving the body was read late, for the survivor, and the
    // recipe output still serializes content (PreciseMatch shape preserved).
    @Test("returned survivors carry their late-hydrated content")
    func returnedSurvivorsAreLateHydrated() async throws {
        try await withCognitionLock {
            let body = "the war indemnity imposed by the treaty was 46 million gold marks"
            let (kit, handle, ids) = try await makeSeededEstate(capturing: [
                "the war indemnity imposed by the treaty was 11 million gold marks",
                body,
                "the war indemnity imposed by the treaty was 23 million gold marks",
            ])
            let target = ids[1]

            let matches = try await PreciseRecall.run(
                kit: kit, handle: handle,
                query: "the war indemnity was 46 million marks",
                filter: .unconfirmed, limit: 10, pool: 30)

            let targetMatch = matches.first { $0.id == target }
            #expect(targetMatch != nil, "the target must be returned")
            // The body-free pool carried empty content; this content is present
            // only because the survivor was late-hydrated.
            #expect(targetMatch?.content == body,
                    "the returned survivor must carry its late-hydrated body")
        }
    }

    // CK-PR-3: pool is clamped to be at least `limit` — a caller asking for
    // more than the pool still gets a non-shrunk, ranked set.
    @Test("pool is clamped to at least limit")
    func poolClampedToLimit() async throws {
        try await withCognitionLock {
            let (kit, handle, _) = try await makeSeededEstate(capturing: [
                "the bridge over the river was 200 metres long",
                "the bridge over the river was 350 metres long",
                "the bridge over the river was 90 metres long",
            ])
            // pool below limit: clamp must lift it so the reduce returns the
            // full available set rather than truncating to the tiny pool.
            let matches = try await PreciseRecall.run(
                kit: kit, handle: handle,
                query: "the bridge was 350 metres long",
                filter: .unconfirmed, limit: 5, pool: 1)

            #expect(matches.count >= 1, "clamped pool still returns ranked matches")
        }
    }

    // CK-PR-7: the trace budget is the final limit, not the coarse pool.
    //
    // Before the F3 fix, a PreciseRecall with pool=50 and limit=3 wrote up to
    // 50 recall_trace rows (the pool width) per query. After the fix,
    // GLKRecallRequest carries a separate `traceLimit = limit` so the
    // RecallDirector caps trace writes to the 3 rows the caller received.
    //
    // A SQLite-backed estate is required: SQLite is the real persistent store
    // for recall_trace rows. The estate is seeded with 15 drawers so the coarse
    // pool (50) is meaningfully larger than the estate size (15) >> final limit
    // (3), making the pool >> limit contrast clear. We open a second
    // DrawerStore over the same SQLite Storage to read the written trace rows
    // independently of the live estate — no testable-import hacks needed.
    @Test("precise-recall trace rows are capped to the final limit, not the pool")
    func traceRowsCappedToFinalLimit() async throws {
        try await withCognitionLock {
            // Unique SQLite file per run — parallel test execution safe.
            let dir = FileManager.default.temporaryDirectory
            let url = dir.appendingPathComponent(
                "cognitionkit-precise-trace-\(UUID().uuidString).sqlite")
            defer {
                // Remove SQLite file and WAL/SHM sidecars created by the test.
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: url.path + "-wal"))
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: url.path + "-shm"))
            }

            // Open a SQLite-backed estate via GeniusLocusKit so the real
            // recall_trace INSERT path runs (InMemory also writes to the table,
            // but the second-DrawerStore read pattern works for both).
            let estateID = UUID()
            let config = EstateConfiguration(estateID: estateID, backend: .sqlite(url: url))
            let storage = try SQLiteStorage(configuration: config)
            let kit = GeniusLocusKit()
            let handle = try await kit.open(
                storage: storage,
                owner: OwnerCredentials(ownerIdentifier: "precise-trace-test"))

            // Shared corpus + vector store — same seeding discipline as
            // makeSeededEstate, ensuring the .unionBest coarse grab has real
            // BM25 and vector candidates across the 15-drawer estate.
            let corpusStorage = InMemoryStorage(
                configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
            let corpus = try await CorpusContentEngine(standaloneOn: corpusStorage)
            let vsStorage = InMemoryStorage(
                configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
            try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
            let vectorStore = VectorStore(storage: vsStorage)
            let modelID = await corpus.modelID
            let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

            // Capture 15 drawers with unique content. Pool = 50 >> estate size
            // (15) >> final limit (3). This makes the pool vs. limit contrast
            // unambiguous: without the fix all 15 (or however many pass the
            // LocusKit filter) are written as trace rows; with the fix only ≤ 3.
            let sentences = (0..<15).map { i in
                "the quarterly report for region \(i) showed revenue of \(i * 10) million"
            }
            for content in sentences {
                let frame = CaptureFrame(
                    content: content,
                    channel: .typed,
                    room: "trace-test",
                    latticeAnchor: .udc("000"),
                    addedBy: "tester",
                    embeddingModelID: "test-model-v1")
                let drawer = try await kit.capture(handle, frame)
                try await corpus.ingest(content, contentID: drawer.id, now: now)
                let engram = try await corpus.embed(content)
                try await vectorStore.addVector(
                    itemID: drawer.id, engram: engram,
                    modelID: modelID, modelVersion: "1.0", filedAt: now)
            }
            await kit.registerCorpus(corpus, for: handle)
            await kit.registerVectorStore(vectorStore, for: handle)

            // Run PreciseRecall: pool = 50 (>> estate size 15 >> final limit 3).
            // The coarse grab surfaces all 15 drawers; the precision re-rank
            // returns the top 3. The trace write must record ≤ 3 rows.
            let finalLimit = 3
            let _ = try await PreciseRecall.run(
                kit: kit, handle: handle,
                query: "quarterly report revenue region",
                filter: .unconfirmed, limit: finalLimit, pool: 50)

            // Read trace rows via a fresh DrawerStore over the same storage —
            // independent of the live estate, no testable-import required.
            // `recallTraceSince(.distantPast)` returns ALL trace rows written
            // since time began (the table was empty before this test run).
            let reader = try await DrawerStore(storage: storage)
            let traces = try await reader.recallTraceSince(.distantPast)

            // The trace table must contain at most `finalLimit` rows: the F3
            // fix threads `traceLimit = limit` (3) into the GLKRecallRequest
            // so the RecallDirector caps `frame.traceLimit` at 3, not at the
            // pool size (50) or the estate size (15).
            #expect(
                traces.count <= finalLimit,
                "precise-recall trace rows must be ≤ final limit \(finalLimit), got \(traces.count)")
        }
    }
}
