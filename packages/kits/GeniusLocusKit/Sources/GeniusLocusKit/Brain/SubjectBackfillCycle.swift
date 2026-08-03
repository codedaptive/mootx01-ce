// SubjectBackfillCycle.swift
//
// The subject-backfill rider seam (PR-09) — the drain-rider pattern's
// second product, targeting the subject trio the way the distillation
// sweep targets the distilled quad. SIBLING lane, not a distillation
// sub-stage: the two products have different producers, different
// pipeline-version families, and different regeneration levers (the
// lane-name reservation in PR-04 pre-decided this shape; flagged for
// Bob's review in the PR-09 report).
//
// This mission ships the SEAM ONLY. No producer is registered by
// default in either port: the Apple miniLLM producer is the PR-10
// rider, and the Rust lane stays DARK until a model exists (compiled,
// gated off — the SIMD/tagger dark-lane precedent). Everything
// deterministic — eligibility, ordering, batch bounds, validation,
// versioning, settled-skip — is conformance-covered; producer OUTPUT
// TEXT is never pinned.

import Foundation
import LocusKit

/// A subject producer: turns drawer content into a one-sentence
/// AI-facing subject. Implementations: the PR-10 Apple miniLLM rider;
/// test stubs. The producer's `pipelineVersion` is stored as provenance
/// on every subject it writes (SPEC B-19) and is the regeneration lever.
public protocol SubjectProducer: Sendable {
    /// Provenance tier written to `subject_pipeline_version`
    /// (e.g. `DrawerStore.subjectPipelineMiniLLMV1`).
    var pipelineVersion: String { get }
    /// Produce a subject for `content`. The sweep validates the result
    /// against `SubjectRegister` before writing; inadmissible output is
    /// counted and skipped, never stored.
    func subject(forContent content: String) async throws -> String

    /// The pipeline tiers this producer is allowed to REGENERATE, in
    /// addition to NULL rows (PR-10). The trust ladder is enforced by
    /// construction: a producer lists only tiers BELOW itself — the
    /// Apple miniLLM rider lists the deterministic tiers
    /// (consolidation-v1, seed-v1) and never ai-v1, so filing-AI
    /// subjects are simply never enumerated for it. Default: empty
    /// (NULL-only, the PR-09 behavior).
    var regeneratesPipelines: [String] { get }
}

extension SubjectProducer {
    /// NULL-only by default — regeneration is an explicit opt-in.
    public var regeneratesPipelines: [String] { [] }
}

/// One sweep's outcome. All counts are per-call (bounded by the batch
/// limit), except `remainingDebt` which is the estate-wide presence
/// debt AFTER the sweep — the drain lane's `pending`.
public struct SubjectBackfillReport: Sendable, Equatable {
    /// Subjects written this sweep.
    public let written: Int
    /// Producer outputs rejected by the register contract (skipped;
    /// the rows remain debt and re-enumerate next sweep).
    public let skippedInadmissible: Int
    /// Estate-wide subject debt after the sweep.
    public let remainingDebt: Int
}

extension GeniusLocusKit {

    /// Register (or replace) the subject producer for `handle`. The
    /// `subject_backfill` drain lane renders from the next
    /// `drainStatuses` call on; `subjectBackfillSweep` becomes runnable.
    public func registerSubjectProducer(
        _ producer: any SubjectProducer, for handle: EstateHandle
    ) throws {
        _ = try estate(for: handle)
        subjectProducers[handle] = producer
    }

    /// The registered producer's pipeline version, or nil when no rider
    /// is registered (the default in this mission — PR-10 registers the
    /// Apple producer).
    public func subjectProducerPipeline(for handle: EstateHandle) -> String? {
        subjectProducers[handle]?.pipelineVersion
    }

    /// Run ONE bounded subject-backfill sweep: enumerate up to
    /// `batchLimit` subject-debt rows (deterministic filedAt-then-id
    /// order), produce + validate + write each, and report. Settled-work
    /// skip is structural — written rows leave the debt predicate, so
    /// reruns never revisit them. Refuses when no producer is
    /// registered: the interactive consent-gated backfill (PR-02/04
    /// surface) is the ONLY subject path until a rider exists.
    ///
    /// `now` is the caller's clock (determinism I-6): it stamps every
    /// `subject_at` this sweep writes.
    public func subjectBackfillSweep(
        _ handle: EstateHandle,
        batchLimit: Int = 32,
        now: Date
    ) async throws -> SubjectBackfillReport {
        guard let producer = subjectProducers[handle] else {
            throw GeniusLocusKitError.underlyingEstateFailure(
                reason: "subjectBackfillSweep: no subject producer registered — "
                    + "the rider lane is dark until a model registers (PR-10); "
                    + "use the interactive backfill (missing_subject → setSubject)")
        }
        let estate = try estate(for: handle)
        let batch = try await estate.subjectDebtBatch(
            limit: batchLimit, includingPipelines: producer.regeneratesPipelines)
        var written = 0
        var skipped = 0
        for drawer in batch {
            let candidate = try await producer.subject(forContent: drawer.content)
            guard SubjectRegister.violations(candidate).isEmpty else {
                // Inadmissible output is skipped, never stored — the row
                // stays debt and re-enumerates next sweep (a persistently
                // failing producer shows up as skipped ≈ batch).
                skipped += 1
                continue
            }
            _ = try await estate.setSubjectRepresentation(
                drawerId: drawer.id,
                subject: candidate,
                pipelineVersion: producer.pipelineVersion,
                at: now)
            written += 1
        }
        let remaining = try await estate.countSubjectDebt(
            includingPipelines: producer.regeneratesPipelines)
        return SubjectBackfillReport(
            written: written,
            skippedInadmissible: skipped,
            remainingDebt: remaining)
    }
}
