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
//      the deterministic / named-model / FDC (stateless) cases — never crashes.
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
}
