// SpanRerankActivation.swift — GeniusLocusKit
//
// The seams that put the span rerank stage live when an estate's
// `embedding_provider` is `"encoder"` (Encoder Rerank contract sheet §7/§8):
// the CorpusKit `SpanEncoder` becomes the stage's query encoder, the estate's
// SynapseKit `VectorStore` becomes its span-row reader, and the registry row
// in LocusKit `encoder_models` becomes the CorpusKit spec the factory loads.
// `activateSpanEncoder(for:)` (EncoderActivation.swift) composes them.

import Foundation
import CorpusKit
import LocusKit
import SynapseKit

/// CorpusKit `SpanEncoder` as the recall stage's query seam. The encoder
/// applies the model's query prefix, pools and L2-normalises, so the stage's
/// int8 dot product against a stored span is a cosine.
struct SpanEncoderQuerySeam: SpanRerankEncoding {
    let encoder: any SpanEncoder
    var modelID: String { encoder.spec.modelID }
    func encodeQuery(_ text: String) async throws -> [Float] {
        try await encoder.encodeQuery(text)
    }
}

/// SynapseKit's span rows as the span rerank stage reads them (sheet §3 rows,
/// serving generation only). `contentVersion` is the duty's staleness key and
/// is not consulted by recall, so it does not travel.
struct SynapseSpanVectorReader: SpanVectorReading {
    let store: VectorStore
    func spanVectors(itemIDs: [String], modelID: String) async throws -> [String: [SpanRerankVector]] {
        try await store.spanVectors(itemIDs: itemIDs, modelID: modelID).mapValues { rows in
            rows.map {
                SpanRerankVector(index: $0.index, int8: $0.int8, scale: $0.scale,
                                 startWord: $0.startWord, endWord: $0.endWord)
            }
        }
    }
}

extension CorpusKit.EncoderModelSpec {
    /// The `encoder_models` registry row as the encoder contract reads it,
    /// field for field. `isActive` is the registry's own state (which row is
    /// serving) and is not part of the model contract, so it does not travel.
    init(row: LocusKit.EncoderModelRow) {
        self.init(
            modelID: row.modelID,
            modelVersion: row.modelVersion,
            dim: row.dim,
            queryPrefix: row.queryPrefix,
            docPrefix: row.docPrefix,
            pooling: row.pooling == .cls ? .cls : .mean,
            tokenizerHash: row.tokenizerHash,
            windowWords: row.windowWords,
            overlapDivisor: row.overlapDivisor,
            maxSpans: row.maxSpans,
            maxSequence: row.maxSequence
        )
    }
}
