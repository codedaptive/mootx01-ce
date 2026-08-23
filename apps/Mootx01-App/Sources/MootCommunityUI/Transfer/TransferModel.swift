import Foundation
import Observation

// MARK: - TransferModel  (APP-06 — Community Import/Export Workflow)
//
// Observable presentation model for APP-06.
// Backed by an injected TransferPort conformer (no singleton, no global writer).
// All mutable state is driven by daemon-supplied values; the model never
// recomputes a business outcome the port did not supply.
//
// Swift 6 strict-concurrency: @MainActor isolates all published mutable state;
// the port is held as `any TransferPort` (Sendable), safe across isolation.
//
// PLAN-BEFORE-MUTATION structural enforcement:
//   executeImport() and executeExport() are no-ops (zero port calls) when the
//   model does not hold a daemon plan with executionPermitted == true.
//   This is not a soft guard — it is a structural gate enforced at the call site
//   before any await, so no race can produce a port call without a valid plan.
//
// Fail-closed discipline enforced throughout:
//   - Cancelled and denied outcomes are stored verbatim; no promotion to success.
//   - Planning failure clears any previously held plan so stale gates cannot pass.
//   - Job IDs are never synthesised; they are stored only when the daemon issues one.
//   - Partial and failed job states are never collapsed to complete success.
//   - Cancellation stage is the daemon's word verbatim (before/during/after commit).

@MainActor
@Observable
public final class TransferModel {

    // MARK: - Import state

    /// Outcome of the most recent source-selection operation.
    /// Nil until `selectImportSource()` completes. Cancelled and denied outcomes
    /// are stored verbatim — not discarded. Requirement 1: source selection is
    /// the first import step; planImport() will not proceed without a `.selected`
    /// outcome here.
    public private(set) var importSourceOutcome: ImportSourceOutcome?

    /// The daemon's most recent import plan.
    /// Nil until `planImport()` returns `.planned`. Cleared on planning failure
    /// so a stale permitted plan cannot gate a new failed attempt.
    ///
    /// PLAN-BEFORE-MUTATION gate: `executeImport()` checks this field and
    /// `importPlan.executionPermitted` before calling the port.
    public private(set) var importPlan: TransferPlan?

    /// The raw outcome of the most recent plan-import call.
    public private(set) var lastImportPlanOutcome: ImportPlanOutcome?

    /// The daemon's response to the most recent execute-import call.
    /// `.submitted` is only set when the daemon confirms — requirement 8.
    public private(set) var lastImportExecuteOutcome: ImportExecutionOutcome?

    /// Stable daemon-issued job ID (CONTRACT-08). Set only on `.submitted`.
    /// The model never synthesises or reassigns this ID.
    public private(set) var importJobID: TransferJobID?

    /// Current job state. Nil until first status load after submission.
    /// Requirement 8: partial and failed states are never collapsed to `.completed`.
    public private(set) var importJobState: TransferJobState?

    /// Outcome of the latest canonical status refresh. A failed or unknown
    /// refresh is kept separately from the last confirmed state so the view
    /// can identify that the displayed progress is stale.
    public private(set) var lastImportJobStatusOutcome: TransferJobStatusOutcome?

    // MARK: - Export state

    /// Outcome of the most recent destination-selection operation.
    /// Requirement 2: destination selection is the first export step.
    public private(set) var exportDestinationOutcome: ExportDestinationOutcome?

    /// Outcome of the most recent scope-selection operation.
    /// Requirement 2: scope selection precedes plan and execution.
    public private(set) var exportScopeOutcome: ExportScopeOutcome?

    /// The daemon's most recent export plan.
    /// Requirement 4: `policyExclusionCount` is never merged into
    /// `estimatedTransferCount` — the plan carries both independently.
    public private(set) var exportPlan: TransferPlan?

    /// The raw outcome of the most recent plan-export call.
    public private(set) var lastExportPlanOutcome: ExportPlanOutcome?

    /// The daemon's response to the most recent execute-export call.
    public private(set) var lastExportExecuteOutcome: ExportExecutionOutcome?

    /// Stable daemon-issued export job ID (CONTRACT-08).
    public private(set) var exportJobID: TransferJobID?

    /// Current export job state.
    public private(set) var exportJobState: TransferJobState?

    /// Export counterpart to `lastImportJobStatusOutcome`.
    public private(set) var lastExportJobStatusOutcome: TransferJobStatusOutcome?

    // MARK: - Shared

    /// The outcome of the most recent cancel-job call (import or export).
    public private(set) var lastCancelOutcome: CancelJobOutcome?

    // MARK: - Operation guards

    /// True while any mutating operation (select/plan/execute/cancel) is in
    /// flight. Prevents concurrent submissions; the view must disable controls
    /// while this is true.
    public private(set) var isOperationInFlight = false

    /// True while a job-status load is in flight. Separate from `isOperationInFlight`
    /// so status refreshes don't block user-facing operations.
    public private(set) var isLoadingJobStatus = false

    // MARK: - Port

    /// Injected port. Production: INTEGRATION-02 adapter.
    /// Tests: FakeTransferPort (defined in CommunityBoundaryTests/Transfer/).
    private let port: any TransferPort

    // MARK: - Init

    /// - Parameter port: injected port conformer. Never constructed here;
    ///   always supplied by the call site (no singleton, no global writer).
    public init(port: any TransferPort) {
        self.port = port
    }

    // MARK: - Derived helpers (view-layer convenience; no business logic)

    /// PLAN-BEFORE-MUTATION gate for import execution.
    ///
    /// True only when the model holds a daemon plan with executionPermitted == true.
    /// The view must disable the execute control when this is false.
    public var canExecuteImport: Bool {
        guard let plan = importPlan else { return false }
        return plan.executionPermitted
    }

    /// PLAN-BEFORE-MUTATION gate for export execution.
    public var canExecuteExport: Bool {
        guard let plan = exportPlan else { return false }
        return plan.executionPermitted
    }

    /// True only when the import job state is `.completed`.
    ///
    /// Requirement 8: partial failure, failed, and cancelled states must NOT
    /// produce true here. The model never collapses a non-complete state.
    public var isImportComplete: Bool {
        if case .completed = importJobState { return true }
        return false
    }

    /// True only when the export job state is `.completed`.
    public var isExportComplete: Bool {
        if case .completed = exportJobState { return true }
        return false
    }

    // MARK: - Import flow

    /// Present the source picker and store the daemon's outcome.
    ///
    /// Requirement 1: source selection is the first import step. Cancelled and
    /// denied outcomes are stored verbatim — the model never discards them or
    /// promotes them to success. No plan call is made here; the caller drives
    /// the sequence.
    public func selectImportSource() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        importSourceOutcome = await port.selectImportSource()
    }

    /// Ask the daemon to plan the import from the previously selected source.
    ///
    /// Fail-closed: only proceeds when `importSourceOutcome` is `.selected`.
    /// A cancelled or denied source leaves `importPlan` nil and makes
    /// `canExecuteImport` false — execution cannot follow.
    ///
    /// On planning failure: `importPlan` is explicitly cleared so a stale
    /// permitted plan from a prior attempt cannot gate this attempt.
    ///
    /// Requirement 3: the returned plan carries all six required fields —
    /// format, candidates, conflicts, invalid, exclusions, estimated effect.
    /// The model stores the plan verbatim without recomputing any field.
    public func planImport() async {
        // Fail-closed: require a daemon-confirmed source URL.
        guard case .selected(let sourceURL, _) = importSourceOutcome else { return }
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.planImport(sourceURL: sourceURL)
        lastImportPlanOutcome = outcome
        switch outcome {
        case .planned(let plan):
            // Store verbatim — the model never adjusts plan fields.
            importPlan = plan
        case .failed:
            // Clear stale plan so a prior permitted plan cannot gate execution.
            importPlan = nil
        }
    }

    /// Submit the import job to the daemon.
    ///
    /// PLAN-BEFORE-MUTATION structural gate: this method produces zero port
    /// calls when `importPlan == nil` or `importPlan.executionPermitted == false`.
    /// The guard is evaluated before any async call, making the gate race-free.
    ///
    /// Fail-closed: `.denied` and `.failed` outcomes store verbatim in
    /// `lastImportExecuteOutcome`; no job ID is recorded and no status load
    /// follows. The model never promotes a denial or failure to a submitted state.
    public func executeImport() async {
        // PLAN-BEFORE-MUTATION: evaluate gate before any await. Zero port calls
        // when the plan is absent or refused. Mutation-sensitive test verifies
        // call log has zero "executeImport" entries in this path.
        guard let plan = importPlan, plan.executionPermitted else { return }
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.executeImport(planToken: plan.planToken)
        lastImportExecuteOutcome = outcome
        if case .submitted(let jobID) = outcome {
            // Stable job ID: stored verbatim from daemon (CONTRACT-08).
            // The model never generates, modifies, or reassigns this ID.
            importJobID = jobID
            // Load initial status so the view immediately shows the job state.
            await _refreshImportJobStatus(jobID: jobID)
        }
        // .denied or .failed: importJobID is not set; no status load.
        // The view reads lastImportExecuteOutcome to surface the daemon's word.
    }

    /// Refresh import job state using the stable daemon-issued job ID.
    ///
    /// Requirement 5: the same stable job ID is used after navigation or
    /// reconnect — the model never synthesises a new ID or changes the stored one.
    /// CONTRACT-08: the ID is stable for the lifetime of the job.
    public func refreshImportJobStatus() async {
        guard let jobID = importJobID else { return }
        await _refreshImportJobStatus(jobID: jobID)
    }

    private func _refreshImportJobStatus(jobID: TransferJobID) async {
        guard !isLoadingJobStatus else { return }
        isLoadingJobStatus = true
        defer { isLoadingJobStatus = false }
        let outcome = await port.loadJobStatus(jobID: jobID)
        lastImportJobStatusOutcome = outcome
        switch outcome {
        case .status(let returnedID, let state) where returnedID == jobID:
            // Store daemon state verbatim. `.failed` and `.cancelled` are never
            // collapsed to `.completed` (requirement 8).
            importJobState = state
        case .status:
            lastImportJobStatusOutcome = .failed(reason: "job-identity-mismatch")
        case .notFound:
            // Job expired or unknown — preserve last known state so the view
            // does not flash to nil. The call log confirms the port was called.
            break
        case .failed:
            // System failure — preserve last known state.
            break
        }
    }

    /// Cancel the in-progress import job.
    ///
    /// Requirement 4: when no job has been submitted (`importJobID == nil`),
    /// this method is a structural no-op — zero port calls, zero state mutation.
    /// The mutation-sensitive test verifies the call log is empty in this path.
    ///
    /// Requirement 6: the cancellation stage is the daemon's word verbatim.
    /// The model stores it in `importJobState` as `.cancelled(stage:)` without
    /// collapsing before/during/after-commit into a single case.
    public func cancelImportJob() async {
        // Requirement 4: no job → no port call. This guard is the structural
        // proof that pre-execution cancel has no effect on the estate.
        guard let jobID = importJobID else { return }
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.cancelJob(jobID: jobID)
        lastCancelOutcome = outcome
        switch outcome {
        case .cancelled(let stage):
            // Requirement 6: surface stage verbatim — three distinct cases.
            importJobState = .cancelled(stage: stage)
        case .alreadyComplete:
            // Job completed before cancel arrived; reload to surface terminal state.
            await _refreshImportJobStatus(jobID: jobID)
        case .notFound, .failed:
            // Preserve last known state. The view reads lastCancelOutcome for detail.
            break
        }
    }

    // MARK: - Export flow

    /// Present the destination picker and store the daemon's outcome.
    ///
    /// Requirement 2: destination selection precedes scope, plan, and execution.
    /// No data leaves the estate until execution is daemon-accepted.
    public func selectExportDestination() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        exportDestinationOutcome = await port.selectExportDestination()
    }

    /// Present the scope picker and store the daemon's outcome.
    ///
    /// Requirement 2: scope selection precedes plan and execution.
    /// The daemon issues a `scopeToken` the model passes back in `planExport`.
    public func selectExportScope() async {
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        exportScopeOutcome = await port.selectExportScope()
    }

    /// Ask the daemon to plan the export.
    ///
    /// Fail-closed: only proceeds when both `exportDestinationOutcome` is
    /// `.selected` and `exportScopeOutcome` is `.selected`. A cancelled or
    /// denied destination or scope leaves `exportPlan` nil.
    ///
    /// Requirement 4 (policy-ineligible content discipline): the returned plan's
    /// `policyExclusionCount` is structurally separate from `estimatedTransferCount`.
    /// The model stores the plan verbatim — it never merges the two counts.
    public func planExport() async {
        // Fail-closed: require both destination and scope to be daemon-confirmed.
        guard
            case .selected(let destURL) = exportDestinationOutcome,
            case .selected(let scopeToken, _, _) = exportScopeOutcome
        else { return }
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.planExport(destinationURL: destURL, scopeToken: scopeToken)
        lastExportPlanOutcome = outcome
        switch outcome {
        case .planned(let plan):
            exportPlan = plan
        case .failed:
            // Clear stale plan (same discipline as import planning failure).
            exportPlan = nil
        }
    }

    /// Submit the export job to the daemon.
    ///
    /// PLAN-BEFORE-MUTATION structural gate: zero port calls without a permitted
    /// plan. Requirement 2: no data leaves the estate without daemon acceptance.
    ///
    /// Fail-closed: `.denied` or `.failed` leaves `exportJobID` nil and the
    /// estate unchanged. The model never promotes either outcome to `.submitted`.
    public func executeExport() async {
        guard let plan = exportPlan, plan.executionPermitted else { return }
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.executeExport(planToken: plan.planToken)
        lastExportExecuteOutcome = outcome
        if case .submitted(let jobID) = outcome {
            exportJobID = jobID
            await _refreshExportJobStatus(jobID: jobID)
        }
    }

    /// Refresh export job state using the stable daemon-issued job ID.
    public func refreshExportJobStatus() async {
        guard let jobID = exportJobID else { return }
        await _refreshExportJobStatus(jobID: jobID)
    }

    private func _refreshExportJobStatus(jobID: TransferJobID) async {
        guard !isLoadingJobStatus else { return }
        isLoadingJobStatus = true
        defer { isLoadingJobStatus = false }
        let outcome = await port.loadJobStatus(jobID: jobID)
        lastExportJobStatusOutcome = outcome
        if case .status(let returnedID, let state) = outcome, returnedID == jobID {
            exportJobState = state
        } else if case .status = outcome {
            lastExportJobStatusOutcome = .failed(reason: "job-identity-mismatch")
        }
    }

    /// Cancel the in-progress export job.
    ///
    /// Requirement 4: no job → no port call (structural no-op).
    /// Requirement 6: cancellation stage stored verbatim.
    public func cancelExportJob() async {
        guard let jobID = exportJobID else { return }
        guard !isOperationInFlight else { return }
        isOperationInFlight = true
        defer { isOperationInFlight = false }
        let outcome = await port.cancelJob(jobID: jobID)
        lastCancelOutcome = outcome
        switch outcome {
        case .cancelled(let stage):
            exportJobState = .cancelled(stage: stage)
        case .alreadyComplete:
            await _refreshExportJobStatus(jobID: jobID)
        case .notFound, .failed:
            break
        }
    }
}
