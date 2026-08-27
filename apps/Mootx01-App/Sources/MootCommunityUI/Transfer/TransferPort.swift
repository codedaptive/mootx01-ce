import Foundation

// MARK: - TransferPort  (APP-06 — Community Import/Export Workflow)
//
// Feature-local presentation port. Lossless projection of CONTRACT-06 and
// CONTRACT-08.
//
// CONTRACT-06 plan phase: recognized format, candidate counts, conflicts,
// policy exclusions, invalid items, estimated effects, execution permission.
// CONTRACT-06 execution phase: stable job identity, progress, cancellation,
// completion counts, terminal receipt or failure.
// Job vocabulary: queued, running, waiting, completed, failed, cancelled.
// CONTRACT-08: stable identities across refresh/reconnect; bounded typed
// error codes; no raw contents or secrets across the port.
//
// PLAN-BEFORE-MUTATION rule (verbatim from Community 1.1 requirements):
// Execution is structurally unreachable without a daemon plan carrying
// executionPermitted == true. The model must never call executeImport or
// executeExport unless it holds such a plan. Mutation-sensitive test:
// a fake that refuses the plan must yield zero execute-port calls.
//
// FAIL-CLOSED rule (verbatim):
// "When required authority, policy, data, daemon availability, compatibility,
//  or recovery state cannot be proven, the operation does not proceed and does
//  not fall back to a less protected path."
//
// Nothing in this file reaches MootGateway, SQLite, PersistenceKit, LocusKit,
// GeniusLocusKit, or any estate store. All business rules and state transitions
// are daemon-owned. Models render typed daemon state and submit typed requests;
// they never recompute daemon outcomes.
//
// The real gateway adapter (INTEGRATION-02) substitutes at this abstraction;
// until that integration ships, all TransferModel behavior is exercised
// against a fake daemon conformer in CommunityBoundaryTests/Transfer/.

// MARK: - TransferFormatDescriptor

/// CONTRACT-06: Daemon-reported description of a transfer format.
///
/// Requirement 3: plans must surface format recognition status.
/// The `recognized` flag is the daemon's verdict — the model never evaluates
/// format compatibility independently. An unrecognized format must block
/// execution (executionPermitted == false in the plan).
public struct TransferFormatDescriptor: Sendable, Equatable {
    /// Human-readable name of the detected format (e.g. "MOOTx01 Archive v2").
    public let name: String
    /// Whether the daemon recognized this format and can process it.
    /// false → the plan must carry executionPermitted == false.
    public let recognized: Bool

    public init(name: String, recognized: Bool) {
        self.name = name
        self.recognized = recognized
    }
}

// MARK: - TransferPlan

/// CONTRACT-06: The daemon's plan for an import or export operation.
/// Produced before any estate mutation or data leaving the estate.
///
/// PLAN-BEFORE-MUTATION: `executionPermitted` is the structural execution gate.
/// The model must not call executeImport/executeExport unless it holds a plan
/// with `executionPermitted == true`. A plan with executionPermitted == false
/// (unrecognized format, policy refusal, permission loss, etc.) must yield
/// zero execute-port calls.
///
/// Requirement 3: all six fields — format, candidates, conflicts, invalid,
/// policy exclusions, and estimated effect — must be surfaced by the view.
///
/// Policy-ineligible content discipline (requirement 4 / CONTRACT-06):
/// `policyExclusionCount` is NEVER added to `estimatedTransferCount`. The
/// plan carries separate counts so the view cannot accidentally include
/// excluded records in the transfer estimate.
public struct TransferPlan: Sendable, Equatable {
    /// The format the daemon detected and evaluated.
    public let format: TransferFormatDescriptor
    /// Total records the daemon found as transfer candidates before filtering.
    public let candidateCount: Int
    /// Records that conflict with existing estate state.
    public let conflictCount: Int
    /// Records the daemon found malformed or unparseable.
    public let invalidCount: Int
    /// Records excluded by privacy policy, sensitivity, or exportability rules.
    /// Must be surfaced as excluded — NEVER added to estimatedTransferCount
    /// (requirement 4 / policy-ineligible discipline).
    public let policyExclusionCount: Int
    /// Records the daemon estimates will be successfully transferred.
    /// This count does NOT include policyExclusionCount — they are structurally
    /// separate to enforce the policy-ineligible content discipline.
    public let estimatedTransferCount: Int
    /// True only when the daemon grants permission to execute.
    /// The structural PLAN-BEFORE-MUTATION gate: false → zero execute calls.
    public let executionPermitted: Bool
    /// Opaque daemon-issued token, passed back at execution to prove plan
    /// provenance. Prevents execution against a stale or synthetic plan.
    public let planToken: String

    public init(
        format: TransferFormatDescriptor,
        candidateCount: Int,
        conflictCount: Int,
        invalidCount: Int,
        policyExclusionCount: Int,
        estimatedTransferCount: Int,
        executionPermitted: Bool,
        planToken: String
    ) {
        self.format = format
        self.candidateCount = candidateCount
        self.conflictCount = conflictCount
        self.invalidCount = invalidCount
        self.policyExclusionCount = policyExclusionCount
        self.estimatedTransferCount = estimatedTransferCount
        self.executionPermitted = executionPermitted
        self.planToken = planToken
    }
}

// MARK: - ImportSourceOutcome

/// CONTRACT-06: Outcome of import source selection.
///
/// Requirement 1: import begins with source selection before any plan or
/// execute call. Cancelled and denied are preserved verbatim; neither
/// triggers a plan call automatically — the caller drives the sequence.
public enum ImportSourceOutcome: Sendable, Equatable {
    /// The user selected a source and the daemon recognised its format.
    case selected(sourceURL: URL, format: TransferFormatDescriptor)
    /// The user dismissed the source picker without selecting.
    case cancelled
    /// Selection was denied (path invalid, authorization refused, etc.).
    case denied(reason: String)
}

// MARK: - ExportDestinationOutcome

/// CONTRACT-06: Outcome of export destination selection.
///
/// Requirement 2: destination selection precedes scope, plan, and execution.
/// Data does not leave the estate until after execution is daemon-accepted.
public enum ExportDestinationOutcome: Sendable, Equatable {
    /// The user selected a destination and the daemon accepted it.
    case selected(destinationURL: URL)
    /// The user dismissed without selecting.
    case cancelled
    /// Selection was denied.
    case denied(reason: String)
}

// MARK: - ExportScopeOutcome

/// CONTRACT-06: Outcome of export scope selection.
///
/// Requirement 2: scope selection precedes plan and execution.
/// The daemon issues a `scopeToken` the model passes back to `planExport`;
/// the model never reinterprets scope semantics independently.
public enum ExportScopeOutcome: Sendable, Equatable {
    /// The user selected a scope; the daemon confirmed candidate count.
    case selected(scopeToken: String, candidateCount: Int, description: String)
    /// The user dismissed the scope picker without selecting.
    case cancelled
}

// MARK: - ImportPlanOutcome

/// CONTRACT-06: The daemon's response to a plan-import request.
///
/// `planned` carries a full TransferPlan including `executionPermitted`.
/// `failed` surfaces a system failure — execution must not proceed.
/// The model must clear any stale plan on `.failed` so stale gates cannot pass.
public enum ImportPlanOutcome: Sendable, Equatable {
    /// The daemon produced a plan. Check `plan.executionPermitted` before executing.
    case planned(TransferPlan)
    /// Planning failed for a system reason. No plan is available for execution.
    case failed(reason: String)
}

// MARK: - ExportPlanOutcome

/// CONTRACT-06: The daemon's response to a plan-export request.
///
/// Requirement 4: the plan's `policyExclusionCount` must never be merged
/// into `estimatedTransferCount` — policy-ineligible records are excluded,
/// not transferred. This is a daemon-side invariant enforced here and
/// verified in the model and view.
public enum ExportPlanOutcome: Sendable, Equatable {
    /// The daemon produced a plan. Check `plan.executionPermitted` before executing.
    case planned(TransferPlan)
    /// Planning failed for a system reason.
    case failed(reason: String)
}

// MARK: - TransferJobID

/// CONTRACT-06 / CONTRACT-08: A stable, opaque job identity.
///
/// Requirement 5: running jobs remain identifiable after navigation or
/// reconnect. The ID is daemon-issued and must never be regenerated or
/// reinterpreted by the model. CONTRACT-08: stable for the job lifetime.
public struct TransferJobID: Sendable, Equatable, Hashable {
    /// Daemon-issued opaque identifier. Stable forever for this job.
    public let id: String

    public init(id: String) {
        self.id = id
    }
}

// MARK: - TransferProgress

/// CONTRACT-06: Progress reported by the daemon for a running job.
///
/// Requirement 5: running jobs show truthful progress. The model renders
/// daemon-supplied counts verbatim — it never synthesizes progress estimates.
public struct TransferProgress: Sendable, Equatable {
    /// Records processed so far in the current job.
    public let processed: Int
    /// Total records in scope for this job (daemon-supplied).
    public let total: Int

    public init(processed: Int, total: Int) {
        self.processed = processed
        self.total = total
    }
}

// MARK: - TransferCounts

/// CONTRACT-06: Terminal or partial record counts from a transfer job.
///
/// Requirement 7: completion must show all five count fields — transferred,
/// skipped, conflicted, excluded, and failed. The view must surface every
/// field; omitting any is a false-success path.
///
/// Requirement 8: partial jobs (failed > 0 with transferred > 0) must NOT
/// be summarised as complete success. The model and view read all five fields.
public struct TransferCounts: Sendable, Equatable {
    /// Records successfully transferred (imported or exported).
    public let transferred: Int
    /// Records skipped (already present, not eligible for overwrite, etc.).
    public let skipped: Int
    /// Records that conflicted with existing state and were not transferred.
    public let conflicted: Int
    /// Records excluded by privacy or policy constraints during execution.
    public let excluded: Int
    /// Records that failed to transfer despite the job reaching completion.
    public let failed: Int

    public init(
        transferred: Int,
        skipped: Int,
        conflicted: Int,
        excluded: Int,
        failed: Int
    ) {
        self.transferred = transferred
        self.skipped = skipped
        self.conflicted = conflicted
        self.excluded = excluded
        self.failed = failed
    }
}

// MARK: - CancellationStage

/// CONTRACT-06: The stage at which a job was cancelled.
///
/// Requirement 6 (verbatim): "Cancellation reports whether the job stopped
/// before, during, or after committed work."
///
/// All three cases are structurally distinct — the model never collapses
/// them. `beforeCommit` is the only case that guarantees no estate mutation
/// or export file was written.
public enum CancellationStage: Sendable, Equatable {
    /// The job was cancelled before any estate mutation or export write occurred.
    /// Requirement 4: cancellation at this stage changes nothing.
    case beforeCommit
    /// The job was cancelled while a commit was in progress.
    /// `partial` is the daemon's count of what was committed before stop.
    case duringCommit(partial: TransferCounts)
    /// The job was cancelled after the daemon had already committed work.
    /// `counts` is the daemon's record of what was committed before the cancel.
    case afterCommit(counts: TransferCounts)
}

// MARK: - TransferJobState

/// CONTRACT-06 / Job vocabulary: six typed job states.
///
/// Requirement 5: running jobs show progress (`.running`).
/// Requirement 6: cancellation reports stage (`.cancelled`).
/// Requirement 7: completion shows counts and receipt (`.completed`).
/// Requirement 8: `.failed` with partial counts must NOT be rendered
/// as complete success — all five count fields must be surfaced.
///
/// `.waiting` covers daemon-side interruption, retry-pending, or throttle
/// states — structurally distinct from `.queued` (not yet started) and
/// `.running` (actively processing). The model never collapses two daemon
/// states into one display state.
public enum TransferJobState: Sendable, Equatable {
    /// Submitted to the daemon; not yet started.
    case queued
    /// Actively processing. `progress` is daemon-supplied; nil when the daemon
    /// has not yet emitted record counts for this pass.
    case running(progress: TransferProgress?)
    /// Temporarily paused or waiting for a daemon condition (e.g. rate limit,
    /// retry backoff, or dependency). `reason` is the daemon's explanation.
    case waiting(reason: String)
    /// The job finished. All five count fields in `counts` must be surfaced;
    /// `receipt` is the daemon's stable completion receipt (CONTRACT-08).
    case completed(counts: TransferCounts, receipt: String)
    /// The job failed. `partial` is non-nil when the daemon committed some
    /// work before the failure — this must NOT be reported as complete success
    /// (requirement 8).
    case failed(reason: String, partial: TransferCounts?)
    /// The job was cancelled. `stage` carries the daemon's report of whether
    /// work was committed before cancellation (requirement 6).
    case cancelled(stage: CancellationStage)
}

// MARK: - ImportExecutionOutcome

/// CONTRACT-06: The daemon's response to an execute-import request.
///
/// PLAN-BEFORE-MUTATION: this outcome is only reachable through the model
/// when it held a plan with executionPermitted == true. A `.denied` or
/// `.failed` execution is stored verbatim — the model never promotes either
/// to a submitted state.
public enum ImportExecutionOutcome: Sendable, Equatable {
    /// The daemon accepted the import job. `jobID` is stable (CONTRACT-08).
    case submitted(jobID: TransferJobID)
    /// The daemon denied execution (permission revoked, policy changed, etc.).
    case denied(reason: String)
    /// Execution failed for a system reason.
    case failed(reason: String)
}

// MARK: - ExportExecutionOutcome

/// CONTRACT-06: The daemon's response to an execute-export request.
///
/// Requirement 2: data does not leave the estate until after the daemon
/// accepts and begins executing. A `.denied` or `.failed` result guarantees
/// no export file was written.
public enum ExportExecutionOutcome: Sendable, Equatable {
    /// The daemon accepted the export job. `jobID` is stable (CONTRACT-08).
    case submitted(jobID: TransferJobID)
    /// The daemon denied execution.
    case denied(reason: String)
    /// Execution failed for a system reason.
    case failed(reason: String)
}

// MARK: - TransferJobStatusOutcome

/// CONTRACT-06 / CONTRACT-08: The daemon's response to a job-status query.
///
/// Requirement 5: identifiable after navigation or reconnect using the same
/// stable job ID. `status` carries the daemon-confirmed `jobID` plus the
/// current `state`, allowing the model to verify identity on reconnect.
/// CONTRACT-08: `notFound` is a bounded typed error — never a raw string.
public enum TransferJobStatusOutcome: Sendable, Equatable {
    /// The daemon returned current state for the queried job.
    case status(jobID: TransferJobID, state: TransferJobState)
    /// The daemon does not recognise this job ID (expired or never existed).
    case notFound
    /// The status query failed for a system reason.
    case failed(reason: String)
}

// MARK: - CancelJobOutcome

/// CONTRACT-06: The daemon's response to a cancel-job request.
///
/// Requirement 6: cancellation reports stage at which the job stopped.
/// `alreadyComplete` covers jobs that finished before the cancel reached the
/// daemon — no spurious state mutation must occur in this case.
public enum CancelJobOutcome: Sendable, Equatable {
    /// The daemon cancelled the job and reports the exact stage.
    case cancelled(stage: CancellationStage)
    /// The job ID is unknown to the daemon.
    case notFound
    /// The job completed before the cancel arrived; no mutation occurred.
    case alreadyComplete
    /// The cancel request failed for a system reason.
    case failed(reason: String)
}

// MARK: - TransferPort

/// Feature-local presentation port for APP-06 Community Import/Export.
/// Lossless projection of CONTRACT-06 and CONTRACT-08.
///
/// The real gateway adapter (INTEGRATION-02) substitutes at this abstraction.
/// Models receive a conformer through injection — no global/singleton writer.
///
/// FAIL-CLOSED: when daemon state cannot be proven, the operation does not
/// proceed and does not fall back to a less-protected path. The port
/// communicates failure through typed outcomes, never through silent no-ops.
///
/// PLAN-BEFORE-MUTATION: execution methods (`executeImport`, `executeExport`)
/// are only called by the model when it holds a daemon plan with
/// `executionPermitted == true`. The model enforces this structurally
/// (mutation-sensitive: zero execute calls when plan refuses permission).
public protocol TransferPort: Sendable {

    // MARK: Import flow

    /// Present a source picker and return the daemon's evaluation of the
    /// selected source, including format recognition.
    ///
    /// Requirement 1: source selection is the first import step. A cancelled
    /// or denied outcome must not trigger a plan call.
    func selectImportSource() async -> ImportSourceOutcome

    /// Ask the daemon to plan the import from the given source URL.
    ///
    /// The plan carries `executionPermitted` — the structural execution gate.
    /// An unrecognized format must yield a plan with executionPermitted == false.
    func planImport(sourceURL: URL) async -> ImportPlanOutcome

    /// Submit an import job to the daemon.
    ///
    /// PLAN-BEFORE-MUTATION: the model only calls this when it holds a plan
    /// with executionPermitted == true. `planToken` proves plan provenance.
    func executeImport(planToken: String) async -> ImportExecutionOutcome

    // MARK: Export flow

    /// Present a destination picker and return the daemon's acceptance.
    ///
    /// Requirement 2: destination selection precedes scope, plan, and execution.
    /// No data leaves the estate until execution is daemon-accepted.
    func selectExportDestination() async -> ExportDestinationOutcome

    /// Present a scope picker and return the daemon's scope token plus counts.
    ///
    /// Requirement 2: scope selection precedes plan and execution. The daemon
    /// issues a `scopeToken` the model passes to `planExport`.
    func selectExportScope() async -> ExportScopeOutcome

    /// Ask the daemon to plan the export.
    ///
    /// Requirement 4 (policy-ineligible discipline): conformers must ensure
    /// `plan.policyExclusionCount` is never added to `plan.estimatedTransferCount`.
    /// Policy-ineligible content is excluded, not transferred.
    func planExport(destinationURL: URL, scopeToken: String) async -> ExportPlanOutcome

    /// Submit an export job to the daemon.
    ///
    /// PLAN-BEFORE-MUTATION: only callable by the model when it holds a plan
    /// with executionPermitted == true. No data leaves the estate otherwise.
    func executeExport(planToken: String) async -> ExportExecutionOutcome

    // MARK: Shared job management (CONTRACT-08 stable identities)

    /// Load the current state of a job by its stable ID.
    ///
    /// Requirement 5: job state is recoverable after navigation or reconnect
    /// using the same daemon-issued stable job ID. CONTRACT-08: the returned
    /// `jobID` in the status matches the queried ID when found.
    func loadJobStatus(jobID: TransferJobID) async -> TransferJobStatusOutcome

    /// Request the daemon to cancel a running or queued job.
    ///
    /// Requirement 6: the outcome carries the daemon's stage report verbatim.
    /// The model must surface the stage without collapsing distinct cases.
    func cancelJob(jobID: TransferJobID) async -> CancelJobOutcome
}
