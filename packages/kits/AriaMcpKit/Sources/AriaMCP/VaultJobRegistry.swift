// VaultJobRegistry.swift
//
// Actor-based registry of in-process vault import and export jobs.
// Held by ToolDispatcher and injected into VaultTools.dispatch() so
// moot_vault_import / moot_vault_export can return a job_id immediately
// and moot_vault_job can poll the result.
//
// Jobs are retained for the process lifetime with no TTL eviction (v1).

import Foundation

// MARK: - Job vocabulary

/// Whether this registry entry tracks a vault import or a vault export.
enum JobKind: String, Sendable {
    case `import`
    case `export`
}

/// The lifecycle state of a vault job.
enum JobStatus: Sendable {
    case running
    case complete
    case failed
}

/// Outcome counts from a completed vault import.
///
/// Field names mirror `ImportReport` in VaultBridge so callers can map
/// directly without a renaming step. The two skip-count fields were added
/// by the vault idempotency + cluster-C fixes and are surfaced in
/// `moot_vault_job` results so an idempotent re-import is observable.
struct ImportResult: Sendable {
    let drawersWritten: Int
    let drawersUpdated: Int
    let itemsSkipped: Int
    let tunnelsCreated: Int
    let fdcClassified: Int
    let fdcUnclassified: Int
    /// Drawers whose content was byte-identical to the existing stored copy
    /// and were therefore skipped without a write (idempotent re-import).
    let drawersSkippedUnchanged: Int
    /// Drawers whose lineage was already tombstoned (erased) and were therefore
    /// skipped to avoid resurrecting a permanently-deleted memory.
    let drawersSkippedTombstoned: Int
}

/// Outcome of a completed vault export: note count and the ISO8601
/// timestamp written to the drift manifest.
struct ExportResult: Sendable {
    let noteCount: Int
    /// ISO8601 timestamp written to the export manifest at job completion.
    let exportedAt: String
}

/// The payload carried by a completed job.
enum JobResult: Sendable {
    case imported(ImportResult)
    case exported(ExportResult)
}

/// One vault job record stored in the registry.
struct VaultJob: Sendable {
    let jobID: String
    let kind: JobKind
    let vaultPath: String
    /// Wall-clock time the job was registered. Used to compute elapsed_s
    /// in moot_vault_job responses. Date() is correct here — start time
    /// is a real-time measurement (not a deterministic computation), the
    /// same precedent as LensTools/VaultTools sampling Date() for manifests.
    let startedAt: Date
    var status: JobStatus
    var result: JobResult?
    var errorMessage: String?
    /// Most recent (processed, total) snapshot from the VaultProgress closure.
    /// Nil until the first progress callback fires. Surfaced by moot_vault_job
    /// while the job is running so callers can observe incremental progress.
    var latestProgress: (processed: Int, total: Int)?
}

// MARK: - Registry

/// Actor-isolated in-process registry for vault import and export jobs.
///
/// A single instance is held by `ToolDispatcher` for the process lifetime.
/// It is injected into `VaultTools.dispatch()` so the async launch tools
/// (`moot_vault_import`, `moot_vault_export`) and the polling tool
/// (`moot_vault_job`) share one authoritative store. Actor isolation makes
/// all mutations and reads thread-safe without additional locking.
actor VaultJobRegistry {

    private var jobs: [String: VaultJob] = [:]

    /// Atomically check the concurrent-job cap and, if capacity allows, register
    /// a new job in the `running` state.
    ///
    /// Performing the count check and the insert in a single actor turn eliminates
    /// the TOCTOU window that existed when callers read `runningJobCount` in one
    /// suspension point and called `register` in a second suspension point. Between
    /// those two turns another concurrent `register` call could slip through the
    /// guard, causing the cap to be exceeded.
    ///
    /// - Parameters:
    ///   - kind: `.import` or `.export`.
    ///   - vaultPath: the filesystem path the new job will work on.
    ///   - maxJobs: the concurrent-job cap to enforce.
    /// - Returns: the new job's UUID string (caller does not generate it).
    /// - Throws: `JSONRPCError(code: .invalidParams, ...)` when already at cap.
    func checkAndRegister(kind: JobKind, vaultPath: String, maxJobs: Int) throws -> String {
        let running = jobs.values.filter { $0.status == .running }.count
        guard running < maxJobs else {
            throw JSONRPCError(
                code: JSONRPCErrorCode.invalidParams,
                message: "too many vault jobs running (\(running)); wait for one to complete before starting another (max \(maxJobs))"
            )
        }
        let jobID = UUID().uuidString
        jobs[jobID] = VaultJob(
            jobID: jobID,
            kind: kind,
            vaultPath: vaultPath,
            startedAt: Date(),
            status: .running
        )
        return jobID
    }

    /// Transition a job to `complete` and attach its result payload.
    ///
    /// - Parameters:
    ///   - jobID: the UUID string that was passed to `register`.
    ///   - result: the import or export outcome.
    func complete(jobID: String, result: JobResult) {
        guard var job = jobs[jobID] else { return }
        job.status = .complete
        job.result = result
        jobs[jobID] = job
    }

    /// Transition a job to `failed` and attach a human-readable error description.
    ///
    /// - Parameters:
    ///   - jobID: the UUID string that was passed to `register`.
    ///   - errorMsg: description of the error for the MCP client.
    func fail(jobID: String, errorMsg: String) {
        guard var job = jobs[jobID] else { return }
        job.status = .failed
        job.errorMessage = errorMsg
        jobs[jobID] = job
    }

    /// Update the progress snapshot for a running job.
    ///
    /// Called from the `VaultProgress` closure passed into import/export bridge
    /// methods. Actor isolation serializes writes automatically — callers outside
    /// the actor use `await capturedRegistry.updateProgress(...)` at the call site;
    /// no explicit `async` keyword is needed on the method declaration.
    ///
    /// - Parameters:
    ///   - jobID: the UUID string that was passed to `register`.
    ///   - processed: notes processed so far.
    ///   - total: total notes in the operation.
    func updateProgress(jobID: String, processed: Int, total: Int) {
        guard var job = jobs[jobID] else { return }
        job.latestProgress = (processed: processed, total: total)
        jobs[jobID] = job
    }

    /// Return the job for `id`, or `nil` when no such job is registered.
    func job(for id: String) -> VaultJob? {
        jobs[id]
    }

}
