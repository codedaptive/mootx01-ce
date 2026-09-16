// DutyQueue.swift — the patient form of the estate's row-debt duties.
//
// Product mandate (Bob, 2026-09-16): every long-running function passes
// through QueueKit so it is resumable. The duties below were built in their
// impatient form only — the caller ran the batch inline — and a signal's work
// ran inside its `emit` closure with only a receipt reaching the queue. This
// file gives each duty a queued form on the shared per-estate `queue.sqlite`
// (the same PersistenceKit backend the encode and dreaming streams use), one
// stream per duty:
//
//   duty-span-encode      one batch of `runSpanEncodeBatch`
//   duty-subject-backfill one batch of `subjectBackfillSweep`
//   duty-facts-backfill   one pass of `backfillSSCFacts`
//   duty-fact-extraction  one batch of `runFactExtractionBatch`
//   duty-retrain-basis    one `reindexCorpus`
//
// A duty job means "pay one batch of this estate's debt for this duty". The
// debt predicate (bit 27 clear, subject NULL, ssc_facts NULL, bit 28 clear)
// is the cursor: a batch is idempotent, so a job reclaimed after a crash
// simply runs again and the estate converges. The existing inline functions
// are unchanged and remain the impatient path; here they are the batch body
// a claimed job runs.
//
// Producer: `enqueueDuty` sends one job when the estate owes work on that
// duty and this process has not already queued one (single occupancy per
// estate and duty; a duplicate after a restart is harmless because batches
// are idempotent). Drainer: `drainDuty` claims the stream's jobs, runs one
// batch per job, replies done, and re-enqueues while debt remains so the
// stream carries the work forward. `signalTick` enqueues every owed duty and
// drains them after the scheduler tick, so the resident pays debt through
// the queue on its ordinary cadence; `payDutyUntilSettled` is the impatient
// caller's loop (upgrade, dream, impatient import).
//
// Mirrors Rust `coordinator.rs` `enqueue_duty` / `drain_duty` /
// `drain_duties` / `pay_duty_until_settled`.

import Foundation
import LocusKit
import MootProductIdentity
import OSLog
import QueueKit

/// The duties with a queued form. The raw value is the stream suffix and the
/// `duty` extension on every job.
public enum DutyKind: String, CaseIterable, Sendable, Codable {
    case spanEncode = "span-encode"
    case subjectBackfill = "subject-backfill"
    case factsBackfill = "facts-backfill"
    case factExtraction = "fact-extraction"
    case retrainBasis = "retrain-basis"

    /// The QueueKit stream this duty's jobs ride.
    public var streamID: StreamID { StreamID(rawValue: "duty-" + rawValue) }

    /// Duties whose debt the resident pays on its own cadence. The retrain is
    /// requested by the dreaming theta hook and the upgrade, never inferred.
    public static let residentDuties: [DutyKind] = [.spanEncode, .subjectBackfill, .factExtraction]
}

/// What one `drainDuty` call did.
public struct DutyDrainReport: Sendable, Equatable {
    public let kind: DutyKind
    /// Jobs claimed and completed on the duty's stream.
    public let jobsRun: Int
    /// Units the batches paid: drawers encoded, subjects written, facts rows
    /// written, facts filed, or 1 per completed retrain.
    public let unitsPaid: Int
    /// Debt still owed after the drain (0 for the retrain).
    public let remainingDebt: Int
}

/// The job payload: the estate and the duty, so a job read from the queue
/// alone names the work.
struct DutyJobPayload: Codable, Sendable {
    let estateUUID: UUID
    let duty: DutyKind
}

public extension GeniusLocusKit {

    private static var dutyLog: Logger {
        Logger(subsystem: MootProductIdentity.Logging.subsystem, category: "GeniusLocusKit")
    }

    /// Batch sizes per job. The subject figure matches the `dream` finisher
    /// (256 per pass); fact extraction matches the resident's Signal 14 batch.
    private static let dutySubjectBatch = 256
    private static let dutyFactExtractionBatch = 16

    // MARK: - Debt

    /// How much this estate still owes on `kind`. Zero when the duty's
    /// prerequisite (encoder provisioned, subject producer, extractor) is
    /// absent, so a duty with nothing to run is never queued. The facts
    /// backfill has no cheap count and is paid on demand; the retrain is
    /// requested, not inferred.
    func dutyDebt(_ kind: DutyKind, in handle: EstateHandle) async throws -> Int {
        let estate = try estate(for: handle)
        switch kind {
        case .spanEncode:
            let provisioned = (try? await provisionedEmbeddingProvider(for: handle)) == Self.encoderProviderID
            guard provisioned, vectorStores[handle] != nil else { return 0 }
            return try await estate.countSpanIndexDebt()
        case .subjectBackfill:
            guard subjectProducers[handle] != nil else { return 0 }
            return try await estate.countSubjectDebt()
        case .factExtraction:
            guard factExtractors[handle] != nil else { return 0 }
            return try await estate.countFactExtractionDebt()
        case .factsBackfill, .retrainBasis:
            return 0
        }
    }

    // MARK: - Producer

    /// Queue one job for `kind` on this estate. Returns `true` when a job was
    /// sent, `false` when this process already has one queued or, for the
    /// debt-driven duties, the estate owes nothing.
    @discardableResult
    func enqueueDuty(_ kind: DutyKind, in handle: EstateHandle, now: Date) async throws -> Bool {
        if dutyQueued[handle]?.contains(kind) == true { return false }
        if kind != .factsBackfill && kind != .retrainBasis {
            guard try await dutyDebt(kind, in: handle) > 0 else { return false }
        }
        let (queue, hlcValue) = try await ensureDreamingQueue(for: handle)
        var hlc = hlcValue
        let payload = try JSONEncoder().encode(DutyJobPayload(estateUUID: handle.estateUUID, duty: kind))
        let physMillis = Int64(now.timeIntervalSince1970 * 1000)
        let stamp = hlc.send(now: physMillis)
        dreamingHLCs[handle] = hlc
        let job = Job(
            id: JobID.generate(),
            streamID: kind.streamID,
            submittedAt: stamp,
            priority: 40,
            payload: payload,
            extensions: ["duty": .string(kind.rawValue)])
        try await queue.send(job)
        dutyQueued[handle, default: []].insert(kind)
        return true
    }

    /// Queue every resident duty the estate currently owes. Called from
    /// `signalTick` before the drain so the resident's cadence pays debt
    /// through the queue.
    func enqueueOwedDuties(in handle: EstateHandle, now: Date) async throws {
        for kind in DutyKind.residentDuties {
            _ = try await enqueueDuty(kind, in: handle, now: now)
        }
    }

    // MARK: - Drainer

    /// Claim the jobs on `kind`'s stream, run one batch per job, reply done,
    /// and re-enqueue while debt remains. A batch error completes the job
    /// with concerns and is rethrown after the reply so the queue never holds
    /// a job the process has given up on.
    func drainDuty(_ kind: DutyKind, in handle: EstateHandle, now: Date) async throws -> DutyDrainReport {
        let (queue, _) = try await ensureDreamingQueue(for: handle)
        let batch = try await queue.drain(stream: kind.streamID)
        dutyQueued[handle]?.remove(kind)
        var jobsRun = 0
        var unitsPaid = 0
        for entry in batch {
            do {
                unitsPaid += try await runDutyBatch(kind, in: handle, now: now)
                try await queue.reply(to: entry.job.id, status: .done, artifacts: [])
                jobsRun += 1
            } catch {
                try? await queue.reply(to: entry.job.id, status: .doneWithConcerns, artifacts: [])
                Self.dutyLog.error(
                    "duty \(kind.rawValue, privacy: .public) batch failed (estate \(handle.estateUUID, privacy: .public)): \(String(describing: error), privacy: .public)")
                throw error
            }
        }
        let remaining = try await dutyDebt(kind, in: handle)
        // Carry the work forward: a job that paid something and left debt
        // queues the next batch; a job that paid nothing does not loop.
        if jobsRun > 0, unitsPaid > 0, remaining > 0 {
            _ = try await enqueueDuty(kind, in: handle, now: now)
        }
        return DutyDrainReport(kind: kind, jobsRun: jobsRun, unitsPaid: unitsPaid, remainingDebt: remaining)
    }

    /// Drain the duty streams no standing signal owns, once. Called from
    /// `signalTick` after the scheduler tick; the span-encode and
    /// fact-extraction signals drain their own streams inside their cycle, so
    /// each tick pays exactly one batch per duty as before.
    func drainDuties(in handle: EstateHandle, now: Date,
                     kinds: [DutyKind] = [.subjectBackfill, .factsBackfill, .retrainBasis]) async throws -> [DutyDrainReport] {
        var reports: [DutyDrainReport] = []
        for kind in kinds {
            reports.append(try await drainDuty(kind, in: handle, now: now))
        }
        return reports
    }

    /// The impatient loop: enqueue and drain until the duty owes nothing or a
    /// batch pays nothing. Returns the units paid in total.
    @discardableResult
    func payDutyUntilSettled(_ kind: DutyKind, in handle: EstateHandle, now: Date) async throws -> Int {
        var total = 0
        while true {
            _ = try await enqueueDuty(kind, in: handle, now: now)
            let report = try await drainDuty(kind, in: handle, now: now)
            total += report.unitsPaid
            if report.jobsRun == 0 || report.unitsPaid == 0 { return total }
            if kind == .retrainBasis || kind == .factsBackfill { return total }
            if report.remainingDebt == 0 { return total }
        }
    }

    // MARK: - Batch body

    /// The existing impatient function for `kind`, run once as the body of a
    /// claimed job. Returns the units paid.
    private func runDutyBatch(_ kind: DutyKind, in handle: EstateHandle, now: Date) async throws -> Int {
        switch kind {
        case .spanEncode:
            return try await runSpanEncodeBatch(handle: handle, now: now)
        case .subjectBackfill:
            guard subjectProducers[handle] != nil else { return 0 }
            return try await subjectBackfillSweep(handle, batchLimit: Self.dutySubjectBatch, now: now).written
        case .factsBackfill:
            return try await backfillSSCFacts(handle: handle)
        case .factExtraction:
            return try await runFactExtractionBatch(handle, limit: Self.dutyFactExtractionBatch, now: now).factsFiled
        case .retrainBasis:
            try await reindexCorpus(handle: handle, now: now)
            return 1
        }
    }
}
