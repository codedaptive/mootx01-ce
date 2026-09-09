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
/// serving generation only). `contentVersion` crosses the seam so strict
/// transcript recall can reject stale source spans.
struct SynapseSpanVectorReader: SpanVectorReading {
    let store: VectorStore
    func spanVectors(itemIDs: [String], modelID: String) async throws -> [String: [SpanRerankVector]] {
        try await store.spanVectors(itemIDs: itemIDs, modelID: modelID).mapValues { rows in
            rows.map {
                SpanRerankVector(index: $0.index, int8: $0.int8, scale: $0.scale,
                                 startWord: $0.startWord, endWord: $0.endWord,
                                 contentVersion: $0.contentVersion)
            }
        }
    }

    /// The strict read lane is intentionally not part of `SpanVectorReading`:
    /// generic rerank continues to use its tolerant protocol seam, while
    /// strict transcript rerank receives malformed-row evidence and a serving
    /// generation receipt from the concrete Synapse authority.
    func strictSpanVectorSnapshot(
        itemIDs: [String], modelID: String
    ) async throws -> StrictSynapseSpanRerankSnapshot {
        let snapshot = try await store.strictSpanVectorSnapshot(itemIDs: itemIDs, modelID: modelID)
        return StrictSynapseSpanRerankSnapshot(
            receipt: snapshot,
            rows: snapshot.rows.mapValues { rows in
                rows.map {
                    SpanRerankVector(index: $0.index, int8: $0.int8, scale: $0.scale,
                                     startWord: $0.startWord, endWord: $0.endWord,
                                     contentVersion: $0.contentVersion)
                }
            })
    }

    func revalidatesStrictSpanVectorSnapshot(
        _ snapshot: StrictSynapseSpanRerankSnapshot
    ) async throws -> Bool {
        try await store.revalidatesStrictSpanVectorSnapshot(snapshot.receipt)
    }
}

/// Strict-only bridge receipt. Kept below the generic `SpanVectorReading`
/// protocol so test and host implementations retain tolerant behavior.
struct StrictSynapseSpanRerankSnapshot: Sendable {
    let receipt: StrictSpanVectorSnapshot
    let rows: [String: [SpanRerankVector]]

    var malformedRows: [StrictSpanVectorMalformedRow] { receipt.malformedRows }
    var servingGeneration: Int64 { receipt.servingGeneration }
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
