// DrainStatus.swift
//
// A read-only status snapshot for a long-running background drain, plus the
// GeniusLocusKit accessor that assembles the status of every drain the estate
// currently runs.
//
// The substrate reports TWO drains:
//
//   1. "corpus_encode" — CorpusKit's encode drain (BM25 + vector lanes).
//      Since the drain-stage distillation rider (SPEC_DISTILLATION_STORAGE
//      §7.1), each encode job also distills its drawers BEFORE the job is
//      replied, so this stream's frontiers cover capture-path distillation.
//   2. "distillation" — the §7.1 accounting surface: `pending` is the
//      count of active drawers whose representation is NULL or was
//      produced under a stale pipeline contract (the sweep-eligibility
//      predicate measured off the rows themselves — stronger than a
//      queue-depth proxy, and it also covers lazy regeneration after a
//      pipeline-version bump or an in-place content patch). `inFlight` is
//      always 0: eligible rows are either awaiting the hourly
//      distillation signal / a `moot_distill` sweep, or riding an encode
//      job already counted by "corpus_encode". "Fully drained" therefore
//      cannot read true while any row still owes a representation
//      (FINDING_11X_MAINTENANCE_WALK constraint 6).
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

    public init(name: String, pending: Int, inFlight: Int, detail: String? = nil) {
        self.name = name
        self.pending = pending
        self.inFlight = inFlight
        self.detail = detail
    }

    /// True while the drain has outstanding work on either frontier. False
    /// means idle: everything submitted has been processed.
    public var isDraining: Bool { pending + inFlight > 0 }

    /// Stable name of the corpus encode/ingest drain (drain 1 in the header
    /// comment). The single source of truth for the string — `drainStatuses`
    /// and `encodeSettled` both key on it.
    public static let corpusEncodeName = "corpus_encode"

    /// Canonical name of the subject-backfill drain lane (PR-09). The
    /// lane renders ONLY while a subject producer is registered for the
    /// estate (PR-10's Apple miniLLM rider; test stubs) — an
    /// always-present eligibility-count lane would hold the
    /// benchmarker's encode barrier open on healthy estates. When a
    /// rider first ships enabled, the benchmarker's non-gating denylist
    /// must gain this name in the same mission (the distillation-lane
    /// precedent). Dispatcher-side mirrors:
    /// AriaMcpKit `ToolDispatcher.subjectBackfillLaneName` /
    /// `SUBJECT_BACKFILL_LANE_NAME`.
    public static let subjectBackfillName = "subject_backfill"

    /// T5 finisher gate: true when the ENCODE drain is idle (or absent), so a
    /// detached `mootx01 drain` finisher may exit and release the encode
    /// DrainLease, and a stdio serve need not spawn one.
    ///
    /// Deliberately ignores every drain except "corpus_encode" — the T5
    /// finisher's CONTRACT is the encode queue and its DrainLease, nothing
    /// else (PERF_W1_DRAIN_RIDER_2026-07-28 Finding 3 established the gate).
    /// Since DISTILL_SEED_STALL routed the wing-seed hints through the encode
    /// stream, the "distillation" entry also settles under a normal drain
    /// (every enqueued drawer distills via the drain-stage rider before its
    /// job replies); the gate stays encode-only anyway so the finisher's
    /// lease tenure is bounded by its own queue, not by any other lane's
    /// accounting (e.g. a pipeline-version bump that re-opens distillation
    /// eligibility estate-wide without enqueuing anything).
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
    /// Today the only drain is the corpus encode/ingest drain: it reports the
    /// queue depth (pending + in-flight encode jobs) and, as detail, the live
    /// encoded-chunk count so forward progress is visible while the queue
    /// drains. A bare LocusKit estate with no Corpus registered runs no encode
    /// drain, so its list is empty.
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

        // Drain 2 of N: distillation accounting (SPEC §7.1). Present on
        // every estate — distillation is a row-level obligation, not a
        // corpus feature. `pending` is the eligibility-predicate count;
        // rows in the encode queue are also counted here until their
        // drain-stage distillation lands (a truthful double-count for the
        // boolean "is anything still draining?" barrier).
        let estate = try estate(for: handle)
        let undistilled = try await estate.countUndistilled(
            pipelineVersion: DistillationPipelineVersion.current)
        statuses.append(DrainStatus(
            name: "distillation",
            pending: undistilled,
            inFlight: 0,
            detail: "pipeline: \(DistillationPipelineVersion.current)"
        ))

        // Drain 3 of N: subject backfill (PR-09). Rendered ONLY while a
        // subject producer is registered (rider-gated — see
        // `subjectBackfillName`). `pending` is the NULL-only presence
        // debt (`countSubjectDebt`), a row-level eligibility count like
        // the distillation lane's; `in_flight` is 0 — sweeps are
        // synchronous bounded batches, never a queue.
        if let producer = subjectProducers[handle] {
            let debt = try await estate.countSubjectDebt()
            statuses.append(DrainStatus(
                name: DrainStatus.subjectBackfillName,
                pending: debt,
                inFlight: 0,
                detail: "pipeline: \(producer.pipelineVersion)"
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
