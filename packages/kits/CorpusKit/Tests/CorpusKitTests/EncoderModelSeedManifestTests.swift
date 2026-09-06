import Foundation
import Testing
@testable import CorpusKitProviders

private struct EncoderModelManifestScalars: Decodable {
    let modelID: String
    let modelVersion: String
    let dim: Int
    let pooling: String
    let queryPrefix: String
    let docPrefix: String
    let windowWords: Int
    let overlapDivisor: Int
    let maxSpans: Int
    let maxSequence: Int
    let tokenizerHash: String

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case modelVersion = "model_version"
        case dim, pooling
        case queryPrefix = "query_prefix"
        case docPrefix = "doc_prefix"
        case windowWords = "window_words"
        case overlapDivisor = "overlap_divisor"
        case maxSpans = "max_spans"
        case maxSequence = "max_sequence"
        case tokenizerHash = "tokenizer_hash"
    }
}

@Suite("EncoderModelSeed manifest parity")
struct EncoderModelSeedManifestTests {
    @Test("every seed scalar matches both checked-in pipeline manifests")
    func seedMatchesAppleAndLinuxManifests() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { repositoryRoot.deleteLastPathComponent() }
        let manifestDirectory = repositoryRoot
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("encoder-models", isDirectory: true)

        for name in ["encoder-models-apple.json", "encoder-models-linux.json"] {
            let manifest = try JSONDecoder().decode(
                EncoderModelManifestScalars.self,
                from: Data(contentsOf: manifestDirectory.appendingPathComponent(name)))
            #expect(manifest.modelID == EncoderModelSeed.modelID, "\(name): model_id")
            #expect(manifest.modelVersion == EncoderModelSeed.modelVersion, "\(name): model_version")
            #expect(manifest.dim == EncoderModelSeed.dim, "\(name): dim")
            #expect(manifest.pooling == EncoderModelSeed.pooling, "\(name): pooling")
            #expect(manifest.queryPrefix == EncoderModelSeed.queryPrefix, "\(name): query_prefix")
            #expect(manifest.docPrefix == EncoderModelSeed.docPrefix, "\(name): doc_prefix")
            #expect(manifest.windowWords == EncoderModelSeed.windowWords, "\(name): window_words")
            #expect(
                manifest.overlapDivisor == EncoderModelSeed.overlapDivisor,
                "\(name): overlap_divisor")
            #expect(manifest.maxSpans == EncoderModelSeed.maxSpans, "\(name): max_spans")
            #expect(manifest.maxSequence == EncoderModelSeed.maxSequence, "\(name): max_sequence")
            #expect(manifest.tokenizerHash == EncoderModelSeed.tokenizerHash, "\(name): tokenizer_hash")
        }
    }
}
