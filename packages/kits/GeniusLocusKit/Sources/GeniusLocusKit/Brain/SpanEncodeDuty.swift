import Foundation
import MootProductIdentity
import CorpusKit
import LocusKit
import OSLog
import SubstrateKernel
import SynapseKit

private let log = Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")

// MARK: - SpanVectorWriter (seam over VectorStore.writeSpanVectors)
//
// The duty writes through a protocol so tests inject a recording writer; the
// production writer is the estate's SynapseKit store, stamping every row with
// the cycle's `now` (the house rule: no clock inside an engine).
internal protocol SpanVectorWriter: Sendable {
    func writeSpanVectors(
        itemID: String,
        modelID: String,
        modelVersion: String,
        spans: [SpanVectorInput]
    ) async throws
}

internal struct VectorStoreSpanWriter: SpanVectorWriter {
    let store: VectorStore
    /// `filed_at` for every span row written by this cycle.
    let filedAt: Date
    func writeSpanVectors(
        itemID: String,
        modelID: String,
        modelVersion: String,
        spans: [SpanVectorInput]
    ) async throws {
        try await store.writeSpanVectors(
            itemID: itemID, modelID: modelID, modelVersion: modelVersion,
            spans: spans, filedAt: filedAt)
    }
}

// MARK: - SpanDrawerItem (lightweight item tuple for the context seam)
//
// The duty only needs id and content from each drawer; returning a full
// LocusKit.Drawer from the context protocol creates unnecessary coupling.
// This lightweight struct is the only thing the seam crosses.

/// Minimal drawer representation for the span-encode context seam.
internal struct SpanDrawerItem: Sendable {
    let id: String
    let content: String
}

// MARK: - SpanEncodeEstateContext (protocol seam for bit-27 read/write)
//
// Wraps the Estate methods the duty needs. Tests inject a mock context so
// the duty's batch logic runs without a real estate.

internal protocol SpanEncodeEstateContext: Sendable {
    /// Return up to `limit` drawer items whose bit 27 (`spanIndexed`) is clear.
    func pendingSpanEncodeBatch(limit: Int) async throws -> [SpanDrawerItem]
    /// Set or clear bit 27 (`spanIndexed`) on one drawer.
    func setSpanIndexed(drawerID: String, indexed: Bool, now: Date) async throws
    /// The drawer's content as stored NOW, or `nil` when the drawer is
    /// missing or tombstoned. Read immediately before the span write so an
    /// erase or content write that landed after the pending snapshot is
    /// honoured (the liveness recheck).
    func liveSpanEncodeContent(drawerID: String) async throws -> String?
}

/// Production adapter wrapping `LocusKit.Estate`.
///
/// `pendingSpanEncodeBatch`: iterates `activeDrawersAfter` and filters locally
/// on the raw bit 27 mask (1 << 27).
///
/// `setSpanIndexed`: calls `estate.setSpanIndexed(drawerId:)`, which sets
/// bit 27 on the row.
internal struct EstateSpanContext: SpanEncodeEstateContext {
    let estate: LocusKit.Estate

    func pendingSpanEncodeBatch(limit: Int) async throws -> [SpanDrawerItem] {
        // Bit 27 = spanIndexed per contract §5 and DrawerOperational.swift layout
        // (the computed accessor is `Drawer.isSpanIndexed`).
        let spanIndexedBit: Int64 = 1 << 27
        var result: [SpanDrawerItem] = []
        var cursor: String? = nil
        while result.count < limit {
            let batch = try await estate.activeDrawersAfter(id: cursor, limit: 200)
            if batch.isEmpty { break }
            for drawer in batch where !drawer.content.isEmpty {
                if drawer.operationalBitmap & spanIndexedBit == 0 {
                    result.append(SpanDrawerItem(id: drawer.id, content: drawer.content))
                    if result.count >= limit { break }
                }
            }
            cursor = batch.last?.id
            if batch.count < 200 { break }
        }
        return result
    }

    func setSpanIndexed(drawerID: String, indexed: Bool, now: Date) async throws {
        // Bit 27 is set here and cleared by the content write and by
        // `EncoderModelStore.activate` (contract sheet §5); the duty never
        // clears it itself.
        guard indexed else { return }
        _ = try await estate.setSpanIndexed(drawerId: drawerID)
    }

    func liveSpanEncodeContent(drawerID: String) async throws -> String? {
        // `drawerById` returns tombstoned rows unfiltered; the tombstone
        // stamp is the erase signal, the (zeroed) content is not consulted.
        guard let drawer = try await estate.drawerById(rowID: drawerID),
              drawer.tombstonedAt == nil else { return nil }
        return drawer.content
    }
}

// MARK: - SpanEncodeBatchResult

/// Outcome of one `SpanEncodeDuty.encodeBatch` invocation.
///
/// Three counters: encoded (span rows written, bit 27 set), skipped (empty
/// content, or the drawer was erased or rewritten between the pending read
/// and the span write — the liveness recheck), failed (error, bit 27 stays
/// clear for retry on the next pump).
public struct SpanEncodeBatchResult: Sendable, Equatable {
    public let encoded: Int
    public let skipped: Int
    public let failed: Int

    public init(encoded: Int, skipped: Int, failed: Int) {
        self.encoded = encoded; self.skipped = skipped; self.failed = failed
    }
}

// MARK: - SpanEncodeDuty

/// Drain duty for the `spanEncode` standing signal (signal 13, REM-ALPHA, 30 s).
///
/// Encodes unindexed drawers into int8 span vectors during REM-ALPHA cycles
/// and sets bit 27 (spanIndexed, contract §5) when the write completes.
///
/// Registered in `DefaultStandingSignals` as signal 13. The duty never blocks
/// the query path; it runs only when the encoder is non-nil. `now` is always
/// a parameter; no `Date()` is called inside.
public enum SpanEncodeDuty {

    /// Default batch size (drawers per signal fire). Mirrors the `encoder_batch`
    /// manifest key's macOS/Linux default (64). iOS default is 16 — callers
    /// read the manifest and pass the appropriate limit.
    public static let defaultBatchSize = 64

    // MARK: - Public entry point (contract signature)

    /// Encode up to `limit` unindexed drawers and write their span vectors.
    ///
    /// Called by `SpanEncodeSignal` on each REM-ALPHA fire. Returns the batch
    /// result for the signal's diagnostic counter.
    ///
    /// - Parameters:
    ///   - estate:   the open estate; `Estate.setSpanIndexed` sets bit 27.
    ///   - encoder:  active `SpanEncoder` (CorpusKit). `nil` → duty skipped.
    ///   - store:    the estate's `VectorStore` (SynapseKit) for span rows.
    ///   - limit:    max drawers per invocation (default `defaultBatchSize`).
    ///   - now:      deterministic clock; no `Date()` inside.
    public static func encodeBatch(
        estate: LocusKit.Estate,
        encoder: (any SpanEncoder)?,
        store: VectorStore,
        limit: Int = defaultBatchSize,
        now: Date
    ) async throws -> SpanEncodeBatchResult {
        let context = EstateSpanContext(estate: estate)
        let writer = VectorStoreSpanWriter(store: store, filedAt: now)
        return try await _encodeBatch(context: context, encoder: encoder, writer: writer, limit: limit, now: now)
    }

    // MARK: - Internal testable core

    /// Protocol-seam variant; tests inject mock context and writer.
    static func _encodeBatch(
        context: some SpanEncodeEstateContext,
        encoder: (any SpanEncoder)?,
        writer: some SpanVectorWriter,
        limit: Int,
        now: Date
    ) async throws -> SpanEncodeBatchResult {
        guard let encoder else {
            // Encoder nil: log once per call and return immediately. The signal
            // fires every 30 s; one log line per fire meets "log once per estate"
            // for the governor's duty-skipped diagnostic.
            log.warning("spanEncode: encoder is nil — duty skipped, all bits stay clear")
            return SpanEncodeBatchResult(encoded: 0, skipped: 0, failed: 0)
        }

        let pending = try await context.pendingSpanEncodeBatch(limit: limit)
        guard !pending.isEmpty else {
            return SpanEncodeBatchResult(encoded: 0, skipped: 0, failed: 0)
        }

        let spec = encoder.spec
        var encoded = 0, skipped = 0, failed = 0

        // ADR-028 E1: the encoder sees the batch once. Every drawer's spans
        // are planned first and their texts laid end to end in drawer order;
        // one `encodeSpans` call covers them all (the encoder chunks the list
        // itself) and the vectors are dealt back to each drawer by its range.
        // The vectors are exactly what one call per drawer produces; only the
        // number of round trips through the model host changes.
        var plans: [(item: SpanDrawerItem, bounds: [(start: Int, end: Int)], range: Range<Int>)] = []
        var allTexts: [String] = []
        for item in pending {
            guard !item.content.isEmpty, let plan = spanPlan(content: item.content, spec: spec) else {
                skipped += 1
                continue
            }
            let start = allTexts.count
            allTexts.append(contentsOf: plan.texts)
            plans.append((item, plan.bounds, start..<allTexts.count))
        }

        // One batch call. When the batch as a whole fails, every drawer is
        // encoded on its own below, so one bad drawer costs itself, not the
        // batch.
        var batchVectors: [[Float]]? = nil
        if !allTexts.isEmpty {
            do {
                let vectors = try await encoder.encodeSpans(allTexts)
                if vectors.count == allTexts.count {
                    batchVectors = vectors
                } else {
                    log.warning("spanEncode: batch encoder returned \(vectors.count, privacy: .public) vectors for \(allTexts.count, privacy: .public) spans — encoding per drawer")
                }
            } catch {
                log.warning("spanEncode: batch encode failed (\(error, privacy: .public)) — encoding per drawer")
            }
        }

        for plan in plans {
            let item = plan.item
            do {
                let vectors: [[Float]]
                if let batchVectors {
                    vectors = Array(batchVectors[plan.range])
                } else {
                    vectors = try await encoder.encodeSpans(Array(allTexts[plan.range]))
                    precondition(vectors.count == plan.bounds.count,
                        "encoder returned \(vectors.count) vectors for \(plan.bounds.count) spans")
                }
                let inputs = spanInputs(content: item.content, bounds: plan.bounds, vectors: vectors)

                // SECURITY: liveness recheck (destruction contract). The
                // pending snapshot was read before this drawer was encoded;
                // an erase or a content write that landed in between must
                // not be undone by a span write that recreates
                // content-derived rows for a tombstoned drawer, or stamps
                // spans of the old text with a content version the drawer
                // no longer has. Skip when the drawer is gone or tombstoned,
                // or when its current content no longer hashes to the
                // version stamped on the spans; bit 27 stays clear, so a
                // rewritten drawer is re-encoded on the next pump from its
                // current content.
                let encodedVersion = SpanContentVersion.fnv1a64(item.content)
                guard let liveContent = try await context.liveSpanEncodeContent(drawerID: item.id),
                      SpanContentVersion.fnv1a64(liveContent) == encodedVersion else {
                    skipped += 1
                    log.info("spanEncode: drawer=\(item.id, privacy: .public) erased or rewritten during encode — span write skipped")
                    continue
                }

                try await writer.writeSpanVectors(
                    itemID: item.id,
                    modelID: spec.modelID,
                    modelVersion: spec.modelVersion,
                    spans: inputs)

                // Set bit 27 (spanIndexed) through the context's
                // `Estate.setSpanIndexed`.
                try await context.setSpanIndexed(drawerID: item.id, indexed: true, now: now)

                encoded += 1
                log.debug("spanEncode: encoded drawer=\(item.id, privacy: .public) spans=\(inputs.count, privacy: .public)")
            } catch {
                // Per-drawer failure is non-fatal: bit 27 stays clear, drawer
                // retries on next pump. Each drawer's error is isolated — a
                // failure on one does not abort the remaining batch.
                failed += 1
                log.warning("spanEncode: drawer=\(item.id, privacy: .public) error: \(error, privacy: .public)")
            }
        }

        return SpanEncodeBatchResult(encoded: encoded, skipped: skipped, failed: failed)
    }

    // MARK: - Span planning

    /// The span plan for one drawer: the word bounds of each span and the
    /// text the encoder sees for it. `nil` when the content has no words or
    /// yields no spans.
    private static func spanPlan(
        content: String,
        spec: EncoderModelSpec
    ) -> (bounds: [(start: Int, end: Int)], texts: [String])? {
        let wordList = Spanner.words(content)
        guard !wordList.isEmpty else { return nil }

        let bounds = Spanner.spans(
            wordCount: wordList.count,
            windowWords: spec.windowWords,
            overlapDivisor: spec.overlapDivisor,
            maxSpans: spec.maxSpans)
        guard !bounds.isEmpty else { return nil }

        // The encoder applies the model's document prefix itself (contract
        // sheet §7: prefixes belong to the contract layer, never to callers).
        let texts = bounds.map { wordList[$0.start..<$0.end].joined(separator: " ") }
        return (bounds, texts)
    }

    /// The span rows for one drawer from its plan and the vectors the encoder
    /// returned for it, quantized to int8.
    private static func spanInputs(
        content: String,
        bounds: [(start: Int, end: Int)],
        vectors: [[Float]]
    ) -> [SpanVectorInput] {
        // Existing rows use FNV-1a 64-bit over UTF-8 content bytes.
        let contentVersion = SpanContentVersion.fnv1a64(content)
        return zip(bounds.enumerated(), vectors).map { (enumBounds, fv) in
            let (idx, span) = enumBounds
            let (q, scale) = Int8Vec.quantize(fv)
            return SpanVectorInput(
                index: UInt32(idx),
                int8: q,
                scale: scale,
                startWord: span.start,
                endWord: span.end,
                contentVersion: contentVersion)
        }
    }

    // MARK: - Inline quantization (until SubstrateKernel.Int8VecOps lands in W1)

    /// Quantize a float32 vector to int8 per contract §4.
    ///
    /// Input MUST be L2-normalised. `scale = max_i |v_i| / 127`
    /// (if max == 0, scale = 1; all-zero input yields all-zero q).
    /// `q_i = clamp(round_half_away_from_zero(v_i / scale), -127, 127)`.
    ///
    /// W1 adds `SubstrateKernel.Int8VecOps.quantize(_:)` with the identical
    /// algorithm. At W1 merge, replace this helper with that call.
    // MARK: - content_version proxy

}

// MARK: - GeniusLocusKit extension (standing signal entry point)

public extension GeniusLocusKit {

    /// Run one `spanEncode` batch against the addressed estate.
    ///
    /// Called by `SpanEncodeSignal` on each REM-ALPHA (30 s) fire. Returns the
    /// encoded count for the signal's diagnostic counter.
    ///
    /// - Parameters:
    ///   - handle:  the open estate.
    ///   - encoder: session's active `SpanEncoder` (nil when no encoder is configured).
    ///   - store:   the estate's `VectorStore`.
    ///   - limit:   max drawers per batch (default `SpanEncodeDuty.defaultBatchSize`).
    ///   - now:     deterministic clock.
    /// - Returns: count of drawers whose span rows were written.
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if the handle is stale.
    /// One `spanEncode` cycle for `handle` (contract sheet §10): the
    /// registered encoder, the estate's VectorStore and the provisioned
    /// `encoder_batch`, resolved here so the resident supplies only the
    /// handle and the clock. No VectorStore registered → nothing to write
    /// → 0. Returns the number of drawers encoded.
    func runSpanEncodeBatch(handle: EstateHandle, now: Date) async throws -> Int {
        guard let store = vectorStores[handle] else { return 0 }
        // No encoder registered (the model was absent or failed to load when
        // the estate opened): attempt activation before walking the bit-27
        // debt, so a model that arrives later is picked up on the next cycle.
        // A failed attempt is the same clean skip as before; the directory
        // probe runs before any model load, so retrying is free.
        if registeredSpanEncoder(for: handle) == nil {
            await activateSpanEncoderIfProvisioned(for: handle)
        }
        let limit = await provisionedEncoderBatch(for: handle)
        return try await runSpanEncodeBatch(
            handle: handle, encoder: registeredSpanEncoder(for: handle),
            store: store, limit: limit, now: now)
    }

    func runSpanEncodeBatch(
        handle: EstateHandle,
        encoder: (any SpanEncoder)?,
        store: VectorStore,
        limit: Int = SpanEncodeDuty.defaultBatchSize,
        now: Date
    ) async throws -> Int {
        let estateObj = try estate(for: handle)
        let result = try await SpanEncodeDuty.encodeBatch(
            estate: estateObj, encoder: encoder, store: store, limit: limit, now: now)
        return result.encoded
    }
}
