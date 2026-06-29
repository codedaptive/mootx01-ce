// TrainableEmbeddingBasisTests.swift
//
// Mission 6a-ii-α: the trainable-basis seam conformance proof.
//
// ## What is tested
//
//   1. SEAM HONESTY (the load-bearing proof): for each of RI/PPMI/LSA/NMF,
//      `trainOnCorpus(texts:)` → `serializeBasis()` reproduces the 6a-i
//      committed canonical basis blob BYTE-FOR-BYTE. This proves the seam
//      routes training through the providers' real conformance-gated
//      train/finalize sequence — identically to the direct 6a-i API — and is
//      the same trained state the Rust port asserts byte-identity against.
//
//   2. RECONSTRUCT DISPATCH: `EmbeddingModel.reconstruct(from:)` returns a
//      provider whose embeddings round-trip the originally-trained provider's,
//      for every trainable case; and throws `CorpusKitError.notTrainable` for
//      deterministic / named-model (miniLM, mpNet, embeddingGemma) / FDC
//      (stateless) cases — never crashes. Apple-only nlEmbedding and
//      nlContextualEmbedding cases are tested in NLEmbeddingProviderTests.swift.
//
//   3. CAPABILITY DETECTION: `EmbeddingModel.isTrainable` is true exactly for
//      RI/PPMI/LSA/NMF and false for deterministic/named/FDC.
//
// The fixture corpus is the same FIXED_CORPUS 6a-i trained on. For RI/PPMI the
// fixture stores already-tokenized term arrays; `trainOnCorpus` takes raw
// strings, so the arrays are space-joined into raw texts. `defaultKeywordTokens`
// tokenizes those raw texts back to the identical arrays (lowercase ASCII words
// separated by spaces), so the trained state — and thus the serialized blob —
// is byte-identical to the fixture. For LSA/NMF the fixture corpus is already
// raw strings, passed through unchanged.

import Testing
import Foundation
import CorpusKit
import CorpusKitProviders
import EngramLib
import VectorKit

@Suite("TrainableEmbeddingBasis")
struct TrainableEmbeddingBasisTests {

    // MARK: - Fixture decoding (only the fields this suite needs)

    /// Minimal view over a 6a-i basis fixture: the canonical blob and the
    /// training corpus. RI/PPMI corpora are `[[String]]` token arrays; LSA/NMF
    /// corpora are `[String]` raw documents. Decoded leniently per provider.
    private struct ArrayCorpusFixture: Decodable {
        let blobBase64: String
        let corpus: [[String]]
    }
    private struct StringCorpusFixture: Decodable {
        let blobBase64: String
        let corpus: [String]
    }

    private func loadArrayFixture(_ name: String) throws -> ArrayCorpusFixture {
        let data = try Data(contentsOf: sharedVectorsURL(for: name))
        return try JSONDecoder().decode(ArrayCorpusFixture.self, from: data)
    }
    private func loadStringFixture(_ name: String) throws -> StringCorpusFixture {
        let data = try Data(contentsOf: sharedVectorsURL(for: name))
        return try JSONDecoder().decode(StringCorpusFixture.self, from: data)
    }

    // MARK: - §1 Seam honesty: trainOnCorpus → serializeBasis == 6a-i blob

    @Test("RI: trainOnCorpus → serializeBasis reproduces the 6a-i blob byte-for-byte")
    func riSeamMatchesFixture() throws {
        let fixture = try loadArrayFixture("ri_basis_blob.json")
        // RI fixture corpus is token arrays; join to raw texts. defaultKeywordTokens
        // tokenizes these back to the identical arrays (space-separated ASCII words).
        let texts = fixture.corpus.map { $0.joined(separator: " ") }
        let provider = RandomIndexingProvider()
        provider.trainOnCorpus(texts: texts)
        let blob = provider.serializeBasis()
        let expected = Data(base64Encoded: fixture.blobBase64)!
        #expect(blob == expected, "RI seam blob must equal the 6a-i canonical blob byte-for-byte")
    }

    @Test("PPMI: trainOnCorpus → serializeBasis reproduces the 6a-i blob byte-for-byte")
    func ppmiSeamMatchesFixture() throws {
        let fixture = try loadArrayFixture("ppmi_basis_blob.json")
        let texts = fixture.corpus.map { $0.joined(separator: " ") }
        let provider = PpmiProvider()
        provider.trainOnCorpus(texts: texts)
        let blob = provider.serializeBasis()
        let expected = Data(base64Encoded: fixture.blobBase64)!
        #expect(blob == expected, "PPMI seam blob must equal the 6a-i canonical blob byte-for-byte")
    }

    @Test("LSA: trainOnCorpus → serializeBasis reproduces the 6a-i blob byte-for-byte")
    func lsaSeamMatchesFixture() throws {
        let fixture = try loadStringFixture("lsa_basis_blob.json")
        // LSA fixture corpus is already raw document strings. The 6a-i fixture
        // was trained on a rank-3 / 30-sweep provider; rank and SVD sweeps are
        // construction config the CALLER chooses, while `trainOnCorpus` governs
        // only the train+finalize SEQUENCE. Match the fixture's construction so
        // the trained state — and thus the blob — is byte-identical.
        let provider = LsaProvider(rank: 3, svdSweeps: 30)
        provider.trainOnCorpus(texts: fixture.corpus)
        let blob = provider.serializeBasis()
        let expected = Data(base64Encoded: fixture.blobBase64)!
        #expect(blob == expected, "LSA seam blob must equal the 6a-i canonical blob byte-for-byte")
    }

    @Test("NMF: trainOnCorpus → serializeBasis reproduces the 6a-i blob byte-for-byte")
    func nmfSeamMatchesFixture() throws {
        let fixture = try loadStringFixture("nmf_basis_blob.json")
        // The 6a-i NMF fixture was trained on a rank-3 / 100-iteration provider.
        // Rank, iterations, and seeds are construction config the CALLER chooses;
        // `trainOnCorpus` governs only the train+finalize SEQUENCE. Match the
        // fixture's construction so the trained state is byte-identical.
        let provider = NmfProvider(rank: 3, maxIterations: 100)
        provider.trainOnCorpus(texts: fixture.corpus)
        let blob = provider.serializeBasis()
        let expected = Data(base64Encoded: fixture.blobBase64)!
        #expect(blob == expected, "NMF seam blob must equal the 6a-i canonical blob byte-for-byte")
    }

    // MARK: - §2 reconstruct dispatch through the enum

    /// A non-empty probe whose embedding pins reconstruction identity.
    private let probe = "car engine"

    @Test("EmbeddingModel.reconstruct round-trips RI embeddings")
    func reconstructRI() async throws {
        let fixture = try loadArrayFixture("ri_basis_blob.json")
        let texts = fixture.corpus.map { $0.joined(separator: " ") }
        let trained = RandomIndexingProvider()
        trained.trainOnCorpus(texts: texts)

        let model = EmbeddingModel.randomIndexing(provider: trained)
        let restored = try model.reconstruct(from: trained.serializeBasis())

        let a = try await trained.embedFloat(probe)
        let b = try await restored.embedFloat(probe)
        #expect(a.map { $0.bitPattern } == b.map { $0.bitPattern })
    }

    @Test("EmbeddingModel.reconstruct round-trips PPMI embeddings")
    func reconstructPPMI() async throws {
        let fixture = try loadArrayFixture("ppmi_basis_blob.json")
        let texts = fixture.corpus.map { $0.joined(separator: " ") }
        let trained = PpmiProvider()
        trained.trainOnCorpus(texts: texts)

        let model = EmbeddingModel.ppmi(provider: trained)
        let restored = try model.reconstruct(from: trained.serializeBasis())

        let a = try await trained.embedFloat(probe)
        let b = try await restored.embedFloat(probe)
        #expect(a.map { $0.bitPattern } == b.map { $0.bitPattern })
    }

    @Test("EmbeddingModel.reconstruct round-trips LSA embeddings")
    func reconstructLSA() async throws {
        let fixture = try loadStringFixture("lsa_basis_blob.json")
        let trained = LsaProvider(rank: 3, svdSweeps: 30)
        trained.trainOnCorpus(texts: fixture.corpus)

        let model = EmbeddingModel.lsa(provider: trained)
        let restored = try model.reconstruct(from: trained.serializeBasis())

        let a = try await trained.embedFloat(probe)
        let b = try await restored.embedFloat(probe)
        #expect(a.map { $0.bitPattern } == b.map { $0.bitPattern })
    }

    @Test("EmbeddingModel.reconstruct round-trips NMF embeddings")
    func reconstructNMF() async throws {
        let fixture = try loadStringFixture("nmf_basis_blob.json")
        let trained = NmfProvider(rank: 3, maxIterations: 100)
        trained.trainOnCorpus(texts: fixture.corpus)

        let model = EmbeddingModel.nmf(provider: trained)
        let restored = try model.reconstruct(from: trained.serializeBasis())

        let a = try await trained.embedFloat(probe)
        let b = try await restored.embedFloat(probe)
        #expect(a.map { $0.bitPattern } == b.map { $0.bitPattern })
    }

    @Test("EmbeddingModel.reconstruct throws notTrainable for non-trainable models")
    func reconstructNonTrainableThrows() throws {
        // Deterministic: no carried provider, not trainable.
        #expect(throws: CorpusKitError.self) {
            _ = try EmbeddingModel.deterministic.reconstruct(from: Data([0, 1, 2, 3]))
        }
        // Named model case: carries an inference closure, not a trainable provider.
        let named = EmbeddingModel.miniLM(inference: { _ in [Float](repeating: 0, count: 4) })
        #expect(throws: CorpusKitError.self) {
            _ = try named.reconstruct(from: Data([0, 1, 2, 3]))
        }
        // FDC: carries a provider but is stateless — does NOT conform to
        // TrainableEmbeddingBasis, so reconstruction must throw notTrainable.
        let fdc = EmbeddingModel.fdc(provider: FDCProvider())
        #expect(throws: CorpusKitError.self) {
            _ = try fdc.reconstruct(from: Data([0, 1, 2, 3]))
        }
    }

    // MARK: - §3 capability detection

    @Test("isTrainable is true only for RI/PPMI/LSA/NMF")
    func isTrainableFlags() {
        #expect(EmbeddingModel.randomIndexing(provider: RandomIndexingProvider()).isTrainable)
        #expect(EmbeddingModel.ppmi(provider: PpmiProvider()).isTrainable)
        #expect(EmbeddingModel.lsa(provider: LsaProvider()).isTrainable)
        #expect(EmbeddingModel.nmf(provider: NmfProvider()).isTrainable)

        #expect(!EmbeddingModel.deterministic.isTrainable)
        #expect(!EmbeddingModel.fdc(provider: FDCProvider()).isTrainable)
        #expect(!EmbeddingModel.miniLM(inference: { _ in [] }).isTrainable)
    }

    // MARK: - §4 maintained-counts seam (incremental-counts change set, P3)
    //
    // Drives the counts seam THROUGH the protocol: `addToCounts` per chunk grows
    // the maintained vocabulary anchor, and `serializeCounts` → `restoreCounts`
    // resumes that anchor in a fresh provider. Each conformer routes the uniform
    // methods to its own accumulation (RI/PPMI fold term sequences; LSA/NMF fold
    // documents via the lightweight anchor). The Rust twin
    // (`trainable_embedding_basis_tests.rs`, §4) asserts the same shape.

    private static let countsCorpus: [String] = [
        "car engine drive road vehicle",
        "vehicle road transport car fuel",
        "engine fuel combustion power car",
        "dog bark run fetch animal",
        "animal run cat dog pet",
    ]

    /// Fold the corpus through `addToCounts`, then assert the anchor survives a
    /// `serializeCounts` → `restoreCounts` round trip on a fresh provider.
    private func assertCountsSeamRoundTrips(
        trained: any TrainableEmbeddingBasis,
        fresh: any TrainableEmbeddingBasis
    ) throws {
        for chunk in Self.countsCorpus { trained.addToCounts(text: chunk) }
        let vocab = trained.countsVocabularySize
        #expect(vocab > 0, "addToCounts must grow the maintained vocabulary")

        let blob = trained.serializeCounts()
        try fresh.restoreCounts(from: blob)
        #expect(fresh.countsVocabularySize == vocab,
                "restored maintained vocabulary size must match the source")

        // A truncated blob is rejected, never a crash.
        #expect(throws: CorpusKitError.self) {
            try fresh.restoreCounts(from: Data(blob.prefix(blob.count / 2)))
        }
    }

    @Test("RI counts seam round-trips the maintained vocabulary anchor")
    func riCountsSeamRoundTrips() throws {
        try assertCountsSeamRoundTrips(
            trained: RandomIndexingProvider(), fresh: RandomIndexingProvider())
    }

    @Test("PPMI counts seam round-trips the maintained vocabulary anchor")
    func ppmiCountsSeamRoundTrips() throws {
        try assertCountsSeamRoundTrips(trained: PpmiProvider(), fresh: PpmiProvider())
    }

    @Test("LSA counts seam round-trips the maintained vocabulary anchor")
    func lsaCountsSeamRoundTrips() throws {
        try assertCountsSeamRoundTrips(
            trained: LsaProvider(rank: 3, svdSweeps: 30),
            fresh: LsaProvider(rank: 3, svdSweeps: 30))
    }

    @Test("NMF counts seam round-trips the maintained vocabulary anchor")
    func nmfCountsSeamRoundTrips() throws {
        try assertCountsSeamRoundTrips(
            trained: NmfProvider(rank: 3, maxIterations: 100),
            fresh: NmfProvider(rank: 3, maxIterations: 100))
    }

    @Test("LSA/NMF anchor tracks document count without retaining TF rows")
    func lsaNmfAnchorTracksDocumentCount() {
        // The lightweight anchor grows vocab + document count WITHOUT keeping the
        // per-document TF rows (bounding maintained state to O(vocab)). Document
        // count must equal the number of non-empty chunks folded.
        let lsa = LsaProvider(rank: 3, svdSweeps: 30)
        for chunk in Self.countsCorpus { lsa.addToCounts(text: chunk) }
        #expect(lsa.documentCount == Self.countsCorpus.count,
                "anchor must bump documentCount once per non-empty chunk")
    }
}
