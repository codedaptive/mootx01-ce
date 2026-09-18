// SpanEncodeBackfill.swift
//
// The span-encode batch function `mootx01 upgrade` runs (ENCODER_RERANK
// CONTRACT §10, §12): for every drawer whose bit 27 (`spanIndexed`) is
// clear, cut the content into spans, encode them with the ACTIVE registry
// model, quantise to int8, write the span rows, set the bit. This is the
// same per-batch sequence the resident's REM-ALPHA `spanEncode` duty
// (`GeniusLocusKit.runSpanEncodeBatch`) performs on a live estate; the
// upgrade runs it here over a CLOSED estate's storage, after the migration
// open has finished, so no kit or daemon has to be alive for the backfill.
//
// Contract names this helper codes against:
//   - `GeniusLocusKit.seedDefaultEncoderModel(in:)`, the one construction
//     site for the seed row; seeds the bundled arctic-embed-s-w60 row when
//     the registry holds no active row (ruling 2026-09-04);
//   - CorpusKit `SpanEncoderFactory.make(spec:modelDirectory:)`,
//     `SpanEncoder.encodeSpans(_:)`, `Spanner.words(_:)`,
//     `Spanner.spans(wordCount:windowWords:overlapDivisor:maxSpans:)`,
//     `EncoderError.modelUnavailable` / `.tokenizerMismatch` (§7);
//   - `ModelDirectoryResolver.encoderModelDirectory(for:dataDirectory:)`
//     (§7, bundling).
//
// Failure contract (§7): no active row, a missing model directory, a vocab
// hash mismatch, or a load failure is a clean skip: recall stays
// lexical-only, the caller prints one line, nothing is written.

import CorpusKit
import CorpusKitProviders
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import SubstrateKernel
import SynapseKit

/// What the backfill did.
enum SpanEncodeReport: Equatable {
    /// `encoder_models` has no active row: lexical-only estate.
    case noActiveModel
    /// An active row exists but the encoder could not be built (directory,
    /// vocab hash, or load); the reason is the one line the caller prints.
    case modelUnavailable(String)
    /// Drawers and span rows written, and how many drawers still owe spans
    /// (0 unless the batch cap stopped the loop).
    case encoded(drawers: Int, spans: Int, remaining: Int)
}

enum SpanEncodeBackfill {

    /// Drawers per encode call: the default `encoder_batch` outside iOS (§7).
    static let batchSize = 64
    static let repairPageSize = 200
    static let spanIndexedBit: Int64 = 1 << 27

    /// Encode every drawer whose bit 27 is clear under the active model.
    ///
    /// `storage` is a connection over an estate whose LocusKit and SynapseKit
    /// schemas are current (the upgrade step opened it through GeniusLocusKit
    /// and the migration catalog first) with `VectorStore.schemaDeclaration`
    /// opened on it by the caller, so the span rows' replace-by-delete finds
    /// the declared primary key; the `DrawerStore` created below declares the
    /// LocusKit schema itself. `dataDirectory` is the mootx01 data
    /// directory the model resolver searches first (the 1.2 download slot);
    /// `now` stamps the span rows' `filed_at`.
    static func run(storage: any Storage, dataDirectory: URL, now: Date) async throws -> SpanEncodeReport {
        let registry = EncoderModelStore(storage: storage)
        // The maintenance open seeds the registry through activation once the
        // manifest names the encoder; this call keeps the backfill correct
        // over its own storage (a CE 1.0.x estate whose key this upgrade step
        // wrote after the open) and is idempotent otherwise.
        _ = try await GeniusLocusKit.seedDefaultEncoderModel(in: registry)
        guard let row = try await registry.active() else { return .noActiveModel }
        guard let modelDirectory = ModelDirectoryResolver.encoderModelDirectory(
            for: row.modelID, dataDirectory: dataDirectory)
        else {
            return .modelUnavailable("no model directory for \(row.modelID)")
        }
        let spec = CorpusKit.EncoderModelSpec(
            modelID: row.modelID, modelVersion: row.modelVersion, dim: row.dim,
            queryPrefix: row.queryPrefix, docPrefix: row.docPrefix,
            pooling: row.pooling == .mean ? .mean : .cls,
            tokenizerHash: row.tokenizerHash, windowWords: row.windowWords,
            overlapDivisor: row.overlapDivisor, maxSpans: row.maxSpans, maxSequence: row.maxSequence)
        let encoder: any SpanEncoder
        do {
            encoder = try await SpanEncoderFactory.make(spec: spec, modelDirectory: modelDirectory)
        } catch {
            return .modelUnavailable("\(error)")
        }

        let drawers = try await DrawerStore(storage: storage)
        let vectors = VectorStore(storage: storage)
        var drawersDone = 0
        var spansWritten = 0

        // Pre-release builds stamped upgrade-produced rows with the drawer's
        // SHA content_hash while the resident and strict reader use FNV-1a64.
        // Those rows already carry bit 27, so the ordinary debt scan cannot
        // discover them. Walk indexed drawers in bounded pages and replace
        // only missing, malformed, or stale serving-generation span sets.
        var repairCursor: String? = nil
        while true {
            let page = try await drawers.activeDrawersAfterStrict(id: repairCursor, limit: repairPageSize)
            guard !page.isEmpty else { break }
            let indexed = page.filter {
                !$0.content.isEmpty && $0.operationalBitmap & spanIndexedBit != 0
            }
            if !indexed.isEmpty {
                let snapshot = try await vectors.strictSpanVectorSnapshot(
                    itemIDs: indexed.map(\.id), modelID: row.modelID)
                let malformedIDs = Set(snapshot.malformedRows.map(\.itemID))
                for drawer in indexed {
                    guard SpanContentVersion.requiresRepair(
                        content: drawer.content,
                        expectedDimension: spec.dim,
                        maxSpans: spec.maxSpans,
                        rows: snapshot.rows[drawer.id, default: []],
                        hasMalformedRows: malformedIDs.contains(drawer.id)
                    ) else { continue }
                    spansWritten += try await encode(
                        drawer: drawer, spec: spec, encoder: encoder, vectors: vectors,
                        modelID: row.modelID, modelVersion: row.modelVersion, now: now)
                    drawersDone += 1
                }
            }
            let shortPage = page.count < repairPageSize
            repairCursor = page.last?.id
            if shortPage { break }
        }

        var cursor: String? = nil
        while true {
            let batch = try await drawers.spanIndexDebtBatch(limit: batchSize, afterDrawerID: cursor)
            guard !batch.isEmpty else { break }
            for drawer in batch {
                spansWritten += try await encode(
                    drawer: drawer, spec: spec, encoder: encoder, vectors: vectors,
                    modelID: row.modelID, modelVersion: row.modelVersion, now: now)
                _ = try await drawers.setSpanIndexed(drawerId: drawer.id)
                drawersDone += 1
            }
            cursor = batch.last?.id
        }
        let remaining = try await drawers.countSpanIndexDebt()
        return .encoded(drawers: drawersDone, spans: spansWritten, remaining: remaining)
    }

    private static func encode(
        drawer: Drawer,
        spec: CorpusKit.EncoderModelSpec,
        encoder: any SpanEncoder,
        vectors: VectorStore,
        modelID: String,
        modelVersion: String,
        now: Date
    ) async throws -> Int {
        let words = Spanner.words(drawer.content)
        let bounds = Spanner.spans(
            wordCount: words.count, windowWords: spec.windowWords,
            overlapDivisor: spec.overlapDivisor, maxSpans: spec.maxSpans)
        let texts = bounds.map { words[$0.start..<$0.end].joined(separator: " ") }
        let floats = try await encoder.encodeSpans(texts)
        var inputs: [SpanVectorInput] = []
        inputs.reserveCapacity(floats.count)
        let contentVersion = SpanContentVersion.fnv1a64(drawer.content)
        for (index, vector) in floats.enumerated() {
            let (q, scale) = Int8Vec.quantize(vector)
            inputs.append(SpanVectorInput(
                index: UInt32(index), int8: q, scale: scale,
                startWord: bounds[index].start, endWord: bounds[index].end,
                contentVersion: contentVersion))
        }
        try await vectors.writeSpanVectors(
            itemID: drawer.id, modelID: modelID, modelVersion: modelVersion,
            spans: inputs, filedAt: now)
        return inputs.count
    }
}
