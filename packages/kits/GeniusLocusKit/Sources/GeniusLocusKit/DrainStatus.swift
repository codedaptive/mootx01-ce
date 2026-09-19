// DrainStatus.swift
//
// A read-only status snapshot for a long-running background drain, plus the
// GeniusLocusKit accessor that assembles the status of every drain the estate
// currently runs.
//
// The substrate reports these drains:
//
//   1. "corpus_encode" — CorpusKit's encode drain (BM25 + vector lanes).
//      The encode rider (room rollup, A2 marker, structural fingerprint
//      lane entry) runs BEFORE each job is replied, so this stream's
//      frontiers cover the rider's work too.
//   2. "dreaming" — the persistent dreaming queue's job depth.
//   3. "subject_backfill" — the subject producer's NULL-only debt, rendered
//      only while a producer is registered.
//   4. "span_encode" — drawers whose bit 27 is clear, rendered only while
//      an encoder is active for the estate.
//   5. "fact_extraction" — drawers whose bit 28 (facts extracted for the
//      active recipe) is clear. Always rendered: a caller settling an
//      estate needs to know extraction is finished even when no extractor
//      is registered, so the detail names the missing extractor instead.
//
// There is no distillation drain: the distilled rendering is computed
// inline at read time (Encoder Rerank contract sheet §9), so no row ever
// owes one.
//
// `drainStatuses(_:)` returns a LIST so future drains append entries with
// no wire reshape.

import CorpusKit
import Foundation
import LocusKit
import SubstrateML

/// The composition-layer encode-speed knob so consumers that import only
/// GeniusLocusKit (VaultKit's PalaceBridge, AriaMcpKit) can name the type and
/// its cases without depending on CorpusKit directly. `.foreground` /
/// `.background` select the drain's embedding QoS (the SPEED axis); write
/// strategy is size-gated separately. Maps 1:1 to `CorpusKit.EncodeSpeed` at the
/// `setEncodeSpeed` boundary below. (A distinct GLK enum — rather than a typealias
/// — is required because Swift forbids using an imported enum's cases in a
/// default argument value unless the defining module is imported by that file.)
public enum EncodeSpeed: Sendable {
    case foreground
    case background
}

/// A read-only status snapshot of one long-running background drain.
public struct DrainStatus: Sendable, Equatable {
    /// Stable identifier for the drain (e.g. `"corpus_encode"`). Lets a status
    /// reader tell drains apart when more than one exists.
    public let name: String

    /// Jobs submitted to the drain but not yet claimed for processing.
    public let pending: Int

    /// Jobs claimed and currently being processed.
    public let inFlight: Int

    /// Optional drain-specific context, human-readable (e.g. the corpus drain
    /// reports `"encoded_chunks: 7218"` so forward progress is visible). Nil
    /// when a drain has no extra detail to report.
    public let detail: String?

    /// Rows the lane settled by REJECTING them (fact extraction: bit 29).
    /// Settled, so never part of `pending`; reported so a caller can see the
    /// rejected corpus. Nil for lanes that have no such outcome.
    public let rejected: Int?

    public init(name: String, pending: Int, inFlight: Int, detail: String? = nil, rejected: Int? = nil) {
        self.name = name
        self.pending = pending
        self.inFlight = inFlight
        self.detail = detail
        self.rejected = rejected
    }

    /// True while the drain has outstanding work on either frontier. False
    /// means idle: everything submitted has been processed.
    public var isDraining: Bool { pending + inFlight > 0 }

    /// Stable name of the corpus encode/ingest drain (drain 1 in the header
    /// comment). The single source of truth for the string — `drainStatuses`
    /// and `encodeSettled` both key on it.
    public static let corpusEncodeName = "corpus_encode"

    /// Canonical name of the dreaming-queue drain lane (2026-08-26). A
    /// GENUINE queue drain: `pending` is the persistent `dreaming` stream's
    /// job depth (recall-event dreaming debt), worked down out-of-band by
    /// the dreamer (in-session, resident daemon, or the T10 detached
    /// finisher). NON-GATING for the benchmarker's encode barrier — the
    /// debt is paid outside the measured session, so a gating lane would
    /// hang every encode barrier on healthy estates
    /// (`barrierNonGatingLanes` gained this name in the same change).
    public static let dreamingName = "dreaming"

    /// Canonical name of the subject-backfill drain lane (PR-09). The
    /// lane renders ONLY while a subject producer is registered for the
    /// estate (PR-10's Apple miniLLM rider; test stubs) — an
    /// always-present eligibility-count lane would hold the
    /// benchmarker's encode barrier open on healthy estates. When a
    /// rider first ships enabled, the benchmarker's non-gating denylist
    /// must gain this name in the same mission. Dispatcher-side mirrors:
    /// AriaMcpKit `ToolDispatcher.subjectBackfillLaneName` /
    /// `SUBJECT_BACKFILL_LANE_NAME`.
    public static let subjectBackfillName = "subject_backfill"

    /// Canonical name of the span-encode row-debt lane. It is rendered only
    /// while a span encoder is registered for the estate; `pending` is the
    /// count of active, non-empty drawers whose span-indexed bit is clear.
    /// This lane remains non-gating for `encodeSettled` because the detached
    /// corpus finisher does not own the standing span duty.
    public static let spanEncodeName = "span_encode"

    /// Canonical name of the fact-extraction row-debt lane. `pending` is the
    /// runnable, retrying and blocked work owed to the active recipe (bit 28
    /// clear); a rejected source is settled (bits 28 and 29) and is reported
    /// in `rejected`, never in `pending`. Always rendered, extractor
    /// or not: a caller settling an estate (the benchmark bulk build, a
    /// `mootx01 dream` loop) reads this lane to learn whether extraction is
    /// finished, and an absent lane would read as "nothing owed". `in_flight`
    /// is 0 — extraction is a bounded batch inside a dreaming cycle, never a
    /// queued job. Non-gating for `encodeSettled`, like every row-debt lane.
    /// Twin of Rust `DrainStatus::FACT_EXTRACTION_NAME`.
    public static let factExtractionName = "fact_extraction"

    /// T5 finisher gate: true when the ENCODE drain is idle (or absent), so a
    /// detached `mootx01 drain` finisher may exit and release the encode
    /// DrainLease, and a stdio serve need not spawn one.
    ///
    /// Deliberately ignores every drain except "corpus_encode" — the T5
    /// finisher's CONTRACT is the encode queue and its DrainLease, nothing
    /// else (PERF_W1_DRAIN_RIDER_2026-07-28 Finding 3 established the gate).
    /// The gate stays encode-only so the finisher's lease tenure is bounded
    /// by its own queue, not by any other lane's accounting (the subject and
    /// span-encode lanes are row-eligibility counts that can be non-zero
    /// without anything enqueued).
    /// Mirrors Rust `DrainStatus::encode_settled`.
    public static func encodeSettled(_ statuses: [DrainStatus]) -> Bool {
        !statuses.contains { $0.name == corpusEncodeName && $0.isDraining }
    }
}

extension GeniusLocusKit {
    /// Status of every long-running drain the estate addressed by `handle`
    /// currently runs, for AI/operator monitoring (the `moot_drain_status`
    /// tool and the `mootx01 query drain_status` CLI surface).
    ///
    /// The lanes, in report order: `corpus_encode` (queue depth plus the live
    /// encoded-chunk count as detail; present only when a Corpus is
    /// registered), `dreaming` (present only when the queue is mounted),
    /// `subject_backfill` and `span_encode` (row debt; present only while
    /// their rider is registered), and `fact_extraction` (row debt owed to
    /// the active recipe; always present so a caller can settle an estate on
    /// it). A bare LocusKit estate with no Corpus registered runs no encode
    /// drain, so its list carries only the always-present lanes.
    ///
    /// Read-only: assembles the report by OBSERVING each drain's frontiers; it
    /// never claims, drains, or mutates, so it is safe to poll while drains run.
    ///
    /// - Throws: `GeniusLocusKitError.estateNotOpen` if `handle` is stale.
    public func drainStatuses(_ handle: EstateHandle) async throws -> [DrainStatus] {
        // Validate the handle up front so a stale handle surfaces estateNotOpen
        // rather than silently returning an empty list — an empty list means
        // "this estate runs no drains", which must not be confused with "this
        // handle is dead".
        _ = try estate(for: handle)

        var statuses: [DrainStatus] = []

        // Drain 1 of N: the corpus encode/ingest drain. Present only when a
        // Corpus is registered for this estate (a provisioned/wired GLK estate).
        if let corpus = corpusKits[handle] {
            let depth = try await corpus.ingestQueueDepth()
            let encodedChunks = try await corpus.count()
            statuses.append(DrainStatus(
                name: DrainStatus.corpusEncodeName,
                pending: depth.pending,
                inFlight: depth.inFlight,
                detail: "encoded_chunks: \(encodedChunks)"
            ))
        }

        // No distillation lane: the distilled rendering is computed inline at
        // read time (Encoder Rerank contract sheet §9), so no row owes one.
        let estate = try estate(for: handle)

        // Drain 3 of N: the dreaming queue (2026-08-26). Rendered only when
        // the queue is MOUNTED (a fresh estate with no external-origin recall
        // has no queue — absent ≠ 0, same honesty rule as the corpus lane).
        // `in_flight` is 0: the queue's claim window is inside the dreamer's
        // own drain call, not observable from a non-claiming peek.
        if let dreamingPending = await dreamingQueuePendingCount(for: handle) {
            statuses.append(DrainStatus(
                name: DrainStatus.dreamingName,
                pending: dreamingPending,
                inFlight: 0,
                detail: "stream: dreaming"
            ))
        }

        // Drain 4 of N: subject backfill (PR-09). Rendered ONLY while a
        // subject producer is registered (rider-gated — see
        // `subjectBackfillName`). `pending` is the NULL-only presence
        // debt (`countSubjectDebt`), a row-level eligibility count like
        // the distillation lane's; `in_flight` is 0 — sweeps are
        // synchronous bounded batches, never a queue.
        if let producer = subjectProducers[handle] {
            let debt = try await estate.countSubjectDebt(
                includingPipelines: producer.regeneratesPipelines,
                refusedBy: producer.pipelineVersion)
            let refused = try await estate.countSubjectRefused(pipelineVersion: producer.pipelineVersion)
            statuses.append(DrainStatus(
                name: DrainStatus.subjectBackfillName,
                pending: debt,
                inFlight: 0,
                detail: "pipeline: \(producer.pipelineVersion), refused: \(refused)"
            ))
        }

        // Drain 4 of N: span encode. This is row debt, not the corpus queue.
        // Rendered whenever the estate's embedding provider is the encoder,
        // loaded or not: a settle loop must see the debt even while no
        // encoder is registered, otherwise an estate with every drawer owed
        // reads as idle. The detail says which it is.
        let encoder = spanEncoders[handle]
        let encoderProvisioned =
            (try? await provisionedEmbeddingProvider(for: handle)) == Self.encoderProviderID
        if encoder != nil || encoderProvisioned {
            let debt = try await estate.countSpanIndexDebt()
            statuses.append(DrainStatus(
                name: DrainStatus.spanEncodeName,
                pending: debt,
                inFlight: 0,
                detail: encoder.map { "model: \($0.spec.modelID)" } ?? "encoder not loaded"
            ))
        }

        // With the master preference off nothing is owed: the lane reads
        // idle and says why, so a settle loop on an estate that turned
        // extraction off (the Rust artifact build) finishes.
        if (try? await provisionedPreference(.factExtraction, for: handle)) == .off {
            statuses.append(DrainStatus(
                name: DrainStatus.factExtractionName, pending: 0, inFlight: 0,
                detail: "fact_extraction off"))
        } else {
            let facts = try await factExtractionWorkStatus(handle, now: Date())
            statuses.append(DrainStatus(
                name: DrainStatus.factExtractionName,
                pending: facts.runnable + facts.retrying + facts.blocked,
                inFlight: facts.inFlight,
                detail: facts.detail,
                rejected: facts.rejected
            ))
        }

        // Drain 4 of N: span encode. This is row debt, not the corpus queue.
        // Rendered whenever the estate's embedding provider is the encoder,
        // loaded or not: a settle loop must see the debt even while no
        // encoder is registered, otherwise an estate with every drawer owed
        // reads as idle. The detail says which it is.
        let encoder = spanEncoders[handle]
        let encoderProvisioned =
            (try? await provisionedEmbeddingProvider(for: handle)) == Self.encoderProviderID
        if encoder != nil || encoderProvisioned {
            let debt = try await estate.countSpanIndexDebt()
            statuses.append(DrainStatus(
                name: DrainStatus.spanEncodeName,
                pending: debt,
                inFlight: 0,
                detail: encoder.map { "model: \($0.spec.modelID)" } ?? "encoder not loaded"
            ))
        }

        // With the master preference off nothing is owed: the lane reads
        // idle and says why, so a settle loop on an estate that turned
        // extraction off (the Rust artifact build) finishes.
        if (try? await provisionedPreference(.factExtraction, for: handle)) == .off {
            statuses.append(DrainStatus(
                name: DrainStatus.factExtractionName, pending: 0, inFlight: 0,
                detail: "fact_extraction off"))
        } else {
            let facts = try await factExtractionWorkStatus(handle, now: Date())
            statuses.append(DrainStatus(
                name: DrainStatus.factExtractionName,
                pending: facts.runnable + facts.retrying + facts.blocked,
                inFlight: facts.inFlight,
                detail: facts.detail,
                rejected: facts.rejected
            ))
        }

        return statuses
    }

    /// Set the encode SPEED (drain QoS) for the estate's corpus drain, mapping
    /// the `mode` arg of an import (`foreground` / `background`) onto the
    /// Corpus's `encodeSpeed`. No-op when no Corpus is registered (a bare
    /// estate has no encode drain). Affects embed task groups spawned after this
    /// call. Mirrors Rust `EstateCoordinator::set_encode_speed`.
    public func setEncodeSpeed(_ speed: EncodeSpeed, for handle: EstateHandle) async {
        // Map the GLK-facing enum onto CorpusKit's at the composition boundary.
        let corpusSpeed: CorpusKit.EncodeSpeed = (speed == .background) ? .background : .foreground
        await corpusKits[handle]?.setEncodeSpeed(corpusSpeed)
    }
}
