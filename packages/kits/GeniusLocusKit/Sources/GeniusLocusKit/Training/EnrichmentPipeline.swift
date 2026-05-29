// EnrichmentPipeline.swift
//
// Mission GLK-07 — The enrichment pipeline that feeds the GLK-06
// matrix tier and learned weights from the unified audit log.
//
// Conceptual model (engineering cookbook §11 enrichment, §15 daemon
// schedule):
//
// The matrix tier is fed two ways. On the capture path each captured
// row updates F / O incrementally (cookbook §6.1 / §6.3). Out of band,
// the dreaming daemon (cookbook §6.4 / §6.9) walks the audit log to
// fold in temporal causality (T) and to recompute NMF loadings. The
// training daemon adopts the same out-of-band model: it picks up
// where it last left off, folds the new tail of the audit log into
// the matrices, and records a high-water mark so the next pass starts
// from there rather than replaying the whole log every tick.
//
// What the pipeline does NOT do:
//
//   - It does not introduce a new cognition store. Updates are
//     applied through `MatrixTier.applyCapture` and
//     `MatrixCalibrationRegistry.record` — the existing public
//     surfaces from GLK-06.
//   - It does not run NMF on every pass. NMF latent-factor refresh
//     is a per-week task in the cookbook; the training daemon's
//     per-tick work is the cheap F / O / calibration fold. Latent
//     factors are recomputed only when the caller invokes
//     `EnrichmentPipeline.refactorize(...)` explicitly. The training
//     daemon's tick path does not call refactorize on its own.
//   - It does not modify the audit log (the log is the source of
//     truth per I-2 / I-20; the pipeline only reads it).
//
// Determinism. The pipeline accepts `now: Date` and a watermark
// parameter on every entry point; no `Date()` is read inside the
// pipeline so the conformance gate against the Rust mirror compares
// bit-equal output for identical inputs.

import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateTypes

// MARK: - Pass result

/// Outcome of one `EnrichmentPipeline.run(...)` pass. Reported back
/// to the daemon so the per-tick diagnostic emission can describe
/// what the pipeline did without re-deriving the numbers.
public struct EnrichmentPassResult: Sendable, Equatable, Codable {

    /// Number of unified-audit entries the pass actually consumed.
    /// Equals zero for a dormant daemon (the daemon short-circuits
    /// before invoking the pipeline) and equals the size of the
    /// post-watermark tail otherwise.
    public let transitionsConsidered: Int

    /// Number of distinct (fieldPath, bitPosition) cells whose F
    /// counts the pass advanced. Counted from the tier's
    /// `fieldPresence` map shape before vs after the pass.
    public let fCellsTouched: Int

    /// Number of distinct co-occurrence keys the pass advanced (O).
    public let oKeysTouched: Int

    /// Number of distinct temporal-causality keys the pass advanced
    /// (T). Today the pipeline does not derive T cells from the audit
    /// log directly (the cookbook leaves temporal causality to the
    /// dreaming daemon's lagged pair walk), so this remains zero
    /// until that pass is added in a later sub-mission. Carried as a
    /// field so the diagnostic shape is stable across versions.
    public let tKeysTouched: Int

    /// Number of calibration observations the pass recorded across
    /// every model id. Zero until the pipeline learns to extract
    /// claimed-confidence / outcome pairs from the audit log; the
    /// hook is here so the field shape stays Codable-stable.
    public let calibrationObservationsRecorded: Int

    /// Highest HLC the pass actually consumed. Carried back to the
    /// caller as a watermark; passing it back on the next run lets
    /// the pipeline skip already-folded entries cheaply.
    public let highWaterMark: HLC

    public init(transitionsConsidered: Int,
                fCellsTouched: Int,
                oKeysTouched: Int,
                tKeysTouched: Int,
                calibrationObservationsRecorded: Int,
                highWaterMark: HLC) {
        self.transitionsConsidered = transitionsConsidered
        self.fCellsTouched = fCellsTouched
        self.oKeysTouched = oKeysTouched
        self.tKeysTouched = tKeysTouched
        self.calibrationObservationsRecorded = calibrationObservationsRecorded
        self.highWaterMark = highWaterMark
    }

    /// A "no-op" pass — used to describe a tick where the gate was
    /// closed and no enrichment work was attempted.
    public static let empty = EnrichmentPassResult(
        transitionsConsidered: 0,
        fCellsTouched: 0,
        oKeysTouched: 0,
        tKeysTouched: 0,
        calibrationObservationsRecorded: 0,
        highWaterMark: .zero
    )
}

// MARK: - Pipeline

/// The enrichment pipeline. A value type because there is no
/// per-pipeline state — the watermark is held by the caller (the
/// training daemon) so the same pipeline can be reused across estates
/// or across daemon instances without entanglement.
public struct EnrichmentPipeline: Sendable, Equatable {

    public init() {}

    // MARK: Run

    /// Fold the post-`highWaterMark` tail of the audit log into the
    /// supplied matrix tier. Returns the watermark the next call should
    /// pass in. `inout` for both the tier and the calibration registry
    /// because the pipeline updates them in place — the caller owns
    /// both stores; the pipeline only reaches in to apply the cookbook
    /// surfaces.
    ///
    /// The pipeline mirrors `MatrixTier.rebuild`'s row-bundling logic:
    /// the audit log carries one entry per (rowID, fieldPath, hlc),
    /// and a single captured row's bitmap fields must be bundled
    /// together so the co-occurrence walk over one capture sees all
    /// of that row's fingerprint fields. This is the same algorithm
    /// `rebuild` uses; we duplicate it here rather than depend on it
    /// so the rebuild path stays a pure "replay every entry" routine
    /// while the enrichment path stays a "fold the tail" routine.
    @discardableResult
    public func run(
        log: UnifiedAuditLog,
        tier: inout MatrixTier,
        calibration: inout MatrixCalibrationRegistry,
        highWaterMark: HLC = .zero
    ) -> EnrichmentPassResult {
        let entries = log.entries(since: highWaterMark)
        if entries.isEmpty {
            // Carry the existing watermark forward unchanged. The
            // caller is free to keep ticking; a no-op pass costs only
            // the empty fold.
            return EnrichmentPassResult(
                transitionsConsidered: 0,
                fCellsTouched: 0,
                oKeysTouched: 0,
                tKeysTouched: 0,
                calibrationObservationsRecorded: 0,
                highWaterMark: highWaterMark
            )
        }

        let beforeFCount = tier.fieldPresence.count
        let beforeOCount = tier.coOccurrence.count
        let beforeTCount = tier.temporalCausality.count

        // Bundle entries by (tier, rowID, hlc) so the co-occurrence
        // walk sees every fingerprint field together. Mirrors
        // MatrixTier.rebuild — see file header for why we duplicate
        // rather than depend.
        struct RowKey: Hashable {
            let tier: AuditTier
            let rowID: UUID
            let hlc: HLC
        }
        var bitmapBundle: [RowKey: [(String, UInt64)]] = [:]
        var valueBundle: [RowKey: [MatrixValueCoord]] = [:]
        var bundleSign: [RowKey: Int64] = [:]
        var transitionsConsidered = 0
        var maxHLC = highWaterMark

        for entry in entries {
            if entry.hlc > maxHLC { maxHLC = entry.hlc }
            let key = RowKey(tier: entry.tier,
                             rowID: entry.rowID,
                             hlc: entry.hlc)

            let sign: Int64
            switch entry.verb {
            case .capture:
                sign = +1
                transitionsConsidered += 1
            case .expunge:
                sign = -1
                transitionsConsidered += 1
            case .mutate, .reanchor:
                // Counted toward transitions so the audit-log fold
                // shows progress, but mutate / reanchor do not fold
                // into F directly — the matrix tier's incremental
                // path captures the before/after delta on the live
                // capture surface, not here. We still advance the
                // watermark so a subsequent pass does not reconsider
                // them.
                transitionsConsidered += 1
                continue
            case .withdraw:
                // Soft tombstone: decrement liveRowCount through
                // applyCapture(delta: -1) over an empty bitmap field
                // list. Mirrors MatrixTier.rebuild's treatment.
                tier.applyCapture(
                    bitmapFields: [], valueFields: [],
                    hlc: entry.hlc, delta: -1)
                transitionsConsidered += 1
                continue
            case .recall, .propose, .associate, .learn,
                 .dreamCompact, .migrate,
                 // Federation grant-lifecycle / key-custody verbs
                 // (GLK-03) record grant and key events at the
                 // federation layer; they do not fold into matrix state,
                 // so they skip without counting alongside the other
                 // read-only and derived verbs.
                 .grantIssued, .grantRevoked, .keyDecayed, .physicalKeyDecayed:
                // Read-only and derived verbs: skip without counting.
                // They do not change matrix state per the gate's
                // transition partition. Enumerated rather than caught
                // by `default:` so a future verb added to
                // `UnifiedAuditVerb` raises a compile error here and
                // forces a conscious classification.
                continue
            }

            switch entry.afterValue {
            case .bitmap(let v):
                var arr = bitmapBundle[key] ?? []
                arr.append((entry.fieldPath, v))
                bitmapBundle[key] = arr
            default:
                var arr = valueBundle[key] ?? []
                arr.append(MatrixValueCoord(fieldPath: entry.fieldPath,
                                            value: entry.afterValue))
                valueBundle[key] = arr
            }
            bundleSign[key] = sign
        }

        // Apply bundles in HLC order so the tier's `lastHLC` advances
        // monotonically. Bitmap-bearing bundles flush first because
        // any row that carried both bitmap and value fields will be
        // drained by the bitmap pass and the value-only pass guards
        // against double-applying via `bundleSign` removal.
        let bitmapKeys = bitmapBundle.keys.sorted { $0.hlc < $1.hlc }
        for k in bitmapKeys {
            guard let sign = bundleSign[k] else { continue }
            let bm = bitmapBundle[k] ?? []
            let vs = valueBundle[k] ?? []
            tier.applyCapture(
                bitmapFields: bm,
                valueFields: vs,
                hlc: k.hlc,
                delta: sign)
            bitmapBundle.removeValue(forKey: k)
            valueBundle.removeValue(forKey: k)
            bundleSign.removeValue(forKey: k)
        }
        let valueKeys = valueBundle.keys.sorted { $0.hlc < $1.hlc }
        for k in valueKeys {
            guard let sign = bundleSign[k] else { continue }
            tier.applyCapture(
                bitmapFields: [],
                valueFields: valueBundle[k] ?? [],
                hlc: k.hlc,
                delta: sign)
        }

        // Calibration suppression. The audit log does not yet carry
        // claimed-confidence / outcome pairs in a structured shape the
        // pipeline can mine — that wiring is part of the Brain layer's
        // verb-body work. The calibration registry passes through
        // unchanged. The hook stays here so the daemon's diagnostic
        // shape (and the conformance vectors) remain stable when the
        // structured pairs land.
        _ = calibration

        let fDelta = max(0, tier.fieldPresence.count - beforeFCount)
        let oDelta = max(0, tier.coOccurrence.count - beforeOCount)
        let tDelta = max(0, tier.temporalCausality.count - beforeTCount)

        return EnrichmentPassResult(
            transitionsConsidered: transitionsConsidered,
            fCellsTouched: fDelta,
            oKeysTouched: oDelta,
            tKeysTouched: tDelta,
            calibrationObservationsRecorded: 0,
            highWaterMark: maxHLC
        )
    }

    // MARK: Refactorize

    /// Recompute the NMF latent factors over the supplied dense
    /// co-occurrence matrix. Out-of-band by design — the daemon's
    /// tick path does not call this; consumers that want refreshed
    /// loadings call it on their own schedule (cookbook says weekly).
    /// Wrapping `MatrixNMF.factorize` here keeps every training-daemon
    /// caller pointed at one entry-point.
    public func refactorize(
        oDense: [Double],
        rows: Int,
        cols: Int,
        k: Int,
        seed: UInt64 = 0xC0FFEE_BABE_BEEF
    ) -> MatrixNMFFactorization {
        MatrixNMF.factorize(
            o: oDense, rows: rows, cols: cols, k: k, seed: seed
        )
    }
}
