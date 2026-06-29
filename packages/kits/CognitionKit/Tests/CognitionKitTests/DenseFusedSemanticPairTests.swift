// DenseFusedSemanticPairTests.swift
//
// PLANTED-SEMANTIC-PAIR test for the dense float lane (Lane D) and the
// `dense-fused` reduction composition. It proves the lane does what the
// 256-bit SimHash-Hamming lane could not: rank a STATEMENT-phrased answer
// above topical distractors for a QUESTION-phrased query that shares almost
// no words with the answer.
//
// The estate is SQLite-backed, but the corpus and vector store use
// InMemoryStorage. The test exercises the injection seam with controlled
// vectors, not the persistent SQLite vector table.
//
// The semantics are PLANTED deterministically. CorpusKit's default
// deterministic provider hashes text, so its float vectors are not
// semantically meaningful; instead this test drives a `.miniLM` corpus with
// an injected inference closure that returns CONTROLLED 384-d vectors. The
// closure recognises each planted phrase by a distinctive token id (computed
// up front with the same DeterministicTokenizer the provider uses) and
// returns a pre-assigned concept vector:
//   - the QUERY and the ANSWER get near-parallel vectors (high cosine), even
//     though they share almost no content words, so the dense lane pulls the
//     answer toward the query;
//   - the two DISTRACTORS get orthogonal vectors, so the dense lane pushes
//     them away.
// The binary SimHash engram (and therefore the BM25 / Hamming lanes) is
// driven by the words, where query↔answer overlap is near zero — so the
// pure-lexical `text` composition cannot rank the answer first. Only the
// dense cosine separates them.

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

@Suite("DenseFusedSemanticPairTests")
struct DenseFusedSemanticPairTests {

    // The planted corpus. Each entry is (content, distinctiveWord, concept):
    //   concept indexes the controlled dense vector. The query (concept 0) and
    //   the answer (concept 0) share a concept; distractors are concepts 1, 2.
    // The query is question-phrased and names "boat", "drifting", "anchor".
    // The ANSWER is statement-phrased and shares NONE of those words (its
    // distinctive token is "seabed"). The two DISTRACTORS deliberately REUSE
    // the query's words ("boat", "drifting", "anchor") so a pure-lexical
    // ranker prefers a distractor over the answer — the gap dense-fused must
    // close. Each phrase keeps one unique marker token for the planted vector.
    private static let query =
        "how do you keep a boat from drifting while resting at anchor"
    private static let answer =
        "weighty iron mass dropped onto the seabed holds the vessel still"
    private static let distractorBudget =
        "a boat club budget covered drifting buoys placed near the anchor line"
    private static let distractorFence =
        "a fence near the boat ramp warned of drifting silt around the anchor"

    // 384-d controlled concept vectors. Concept A (query + answer) is one
    // direction; B and C are orthogonal to A and to each other (distinct
    // coordinate blocks). Cosine(A_query, A_answer) ≈ 1; cosine(A, B/C) = 0.
    private static func conceptVector(_ concept: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 384)
        // Each concept owns a disjoint 8-coordinate block so the vectors are
        // mutually orthogonal. The query and answer share concept 0 but with a
        // slight per-phrase perturbation so they are near-parallel, not equal.
        let base = concept * 8
        for i in 0..<8 { v[base + i] = 1.0 }
        return v
    }

    // Distinctive token ids the corpus's internal tokenizer
    // (CorpusDefaultTokenizer, FNV-1a over the model vocab) assigns to a marker
    // word in each planted phrase. Captured empirically from the live tokenizer
    // for this exact vocab (minilm-v6, vocabSize 30522) so the inference closure
    // can recognise which phrase it is embedding and return the planted concept
    // vector. The query and the answer map to concept 0 (near-parallel cosine);
    // the two distractors map to orthogonal concepts 1 and 2.
    private static let queryMarkerID: Int32 = 21071   // "how" — query only
    private static let answerMarkerID: Int32 = 21210  // "weighty" — answer only
    private static let distractor1MarkerID: Int32 = 29296 // distractor-budget only
    private static let distractor2MarkerID: Int32 = 9991  // distractor-fence only

    /// Build the inference closure: recognise each planted phrase by a
    /// distinctive token id and return the matching concept vector. The query
    /// and answer share concept 0 (near-parallel, high cosine) despite almost
    /// no shared words; the distractors get orthogonal concepts. Any unplanted
    /// text gets a neutral block.
    private static func makeInference() -> @Sendable ([Int32]) async throws -> [Float] {
        // Query and answer share concept 0; a slight lean on an answer-only
        // coordinate keeps them near-parallel (cosine ≈ 0.997) rather than
        // identical, exercising a real cosine ranking rather than an exact tie.
        // Built as a `let` so the closure captures it immutably (Sendable).
        let queryVec = conceptVector(0)
        let answerVec: [Float] = {
            var v = conceptVector(0)
            v[7] = 0.95
            return v
        }()
        let qID = queryMarkerID, aID = answerMarkerID
        let d1ID = distractor1MarkerID, d2ID = distractor2MarkerID

        return { tokens in
            let set = Set(tokens)
            if set.contains(qID)  { return queryVec }
            if set.contains(aID)  { return answerVec }
            if set.contains(d1ID) { return conceptVector(1) }
            if set.contains(d2ID) { return conceptVector(2) }
            // Unplanted text (e.g. the supportsFloat "x" probe): a neutral block.
            return conceptVector(4)
        }
    }

    /// Open a SQLite-backed estate and capture the provided `contents` into the
    /// corpus (BM25 + binary engram + float row). The planted query is embedded
    /// by callers for lookup; the captured `contents` are the answer plus
    /// distractors. Returns the kit, handle, and the drawer id for each captured
    /// phrase in input order.
    private func makeSeededEstate(
        url: URL,
        capturing contents: [String]
    ) async throws -> (GeniusLocusKit, EstateHandle, [String]) {
        let estateID = UUID()
        let config = EstateConfiguration(estateID: estateID, backend: .sqlite(url: url))
        let storage = try SQLiteStorage(configuration: config)
        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "dense-fused-semantic-test"))

        // .miniLM corpus with the planted inference closure: the float lane's
        // pooled vector is the controlled concept vector, while the binary
        // engram and BM25 lane are still driven by the phrase's words.
        let corpusStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let corpus = try await Corpus(
            storage: corpusStorage,
            model: .miniLM(inference: Self.makeInference()))
        let vsStorage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        try await vsStorage.migrate(to: VectorStore.schemaDeclaration)
        let vectorStore = VectorStore(storage: vsStorage)
        let modelID = await corpus.modelID
        let now = Date(timeIntervalSinceReferenceDate: 3_000_000)

        var ids: [String] = []
        for content in contents {
            let frame = CaptureFrame(
                content: content,
                channel: .typed,
                room: "harbour",
                latticeAnchor: .udc("000"),
                addedBy: "tester",
                embeddingModelID: "test-model-v1")
            let drawer = try await kit.capture(handle, frame)
            ids.append(drawer.id)
            // ingest writes BM25 + binary engram + the float row (Lane D).
            try await corpus.ingest(content, sourceID: drawer.id, now: now)
            let engram = try await corpus.embed(content)
            try await vectorStore.addVector(
                itemID: drawer.id, engram: engram,
                modelID: modelID, modelVersion: "1.0", filedAt: now)
        }

        await kit.registerCorpus(corpus, for: handle)
        await kit.registerVectorStore(vectorStore, for: handle)
        return (kit, handle, ids)
    }

    /// Unique SQLite file per run + sidecar cleanup.
    private func withTempSQLite(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent(
            "cognitionkit-dense-fused-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
        }
        try await body(url)
    }

    // The load-bearing test: dense-fused ranks the statement-phrased answer
    // first for the question-phrased query, where the pure-lexical `text`
    // composition does NOT (the answer shares almost no words with the query).
    @Test("dense-fused ranks the low-lexical-overlap answer that text cannot")
    func denseFusedRanksSemanticAnswer() async throws {
        try await withCognitionLock {
            try await withTempSQLite { url in
                let (kit, handle, ids) = try await makeSeededEstate(
                    url: url,
                    capturing: [
                        Self.answer,            // ids[0] — the planted answer
                        Self.distractorBudget,  // ids[1]
                        Self.distractorFence,   // ids[2]
                    ])
                let target = ids[0]

                // Baseline: pure-lexical `text`. The question and the answer
                // share almost no content words, so the lexical signal cannot
                // lift the answer above the distractors — it does not rank
                // first. (We assert the dense win below; this documents the gap.)
                let textMatches = try await PreciseRecall.run(
                    kit: kit, handle: handle, query: Self.query,
                    filter: .unconfirmed, limit: 3, pool: 30, composition: "text")
                #expect(
                    textMatches.first?.id != target,
                    "pure-lexical text must NOT rank the low-overlap answer first")

                // dense-fused: the cosine over the planted float vectors pulls
                // the answer to the top even with near-zero word overlap.
                let denseMatches = try await PreciseRecall.run(
                    kit: kit, handle: handle, query: Self.query,
                    filter: .unconfirmed, limit: 3, pool: 30, composition: "dense-fused")
                #expect(!denseMatches.isEmpty, "the coarse grab must surface candidates")
                #expect(
                    denseMatches.first?.id == target,
                    "dense-fused must rank the semantically-matched answer first")
            }
        }
    }

    // Recall is held: every grid composition (including dense-fused) keeps the
    // planted answer somewhere in the bounded returned set — the dense lane
    // adds a column, it never prunes the answer out.
    @Test("dense-fused holds the answer in the bounded returned set")
    func denseFusedHoldsRecall() async throws {
        try await withCognitionLock {
            try await withTempSQLite { url in
                let (kit, handle, ids) = try await makeSeededEstate(
                    url: url,
                    capturing: [Self.answer, Self.distractorBudget, Self.distractorFence])
                let target = ids[0]
                let matches = try await PreciseRecall.run(
                    kit: kit, handle: handle, query: Self.query,
                    filter: .unconfirmed, limit: 3, pool: 30, composition: "dense-fused")
                #expect(matches.contains { $0.id == target },
                        "dense-fused must hold the answer in the bounded set")
            }
        }
    }
}
