import Foundation
import MootCommunityUI

// MARK: - FakeTransferPort  (APP-06 boundary tests)
//
// Contract-compatible fake daemon conformer for TransferPort.
// Lives in the test tree; production code never imports or instantiates this.
//
// The real gateway adapter (INTEGRATION-02) substitutes at the same
// TransferPort abstraction in production.
//
// Design: actor so Swift 6 strict concurrency is satisfied without
// @unchecked Sendable. Tests configure via setters; call-log reads are
// awaited after model operations.
//
// PLAN-BEFORE-MUTATION verification: tests inspect `callLog` to confirm zero
// "executeImport" or "executeExport" entries when the plan carries
// executionPermitted == false. The call log is the ground truth for whether
// the port was reached — not model state, which could be set before the call.
//
// UUID/ID provenance: no real estate UUIDs appear here. Synthetic job IDs
// use the reserved synthetic namespace (first 8 characters are the same hex
// digit repeated), which cannot be confused with a real daemon-issued ID.
// Source/destination URLs use local /tmp paths with synthetic filenames.

actor FakeTransferPort: TransferPort {

    // MARK: - Configurable results (set per test via setters)

    private var _importSourceOutcome: ImportSourceOutcome
    private var _importPlanOutcome: ImportPlanOutcome
    private var _importExecutionOutcome: ImportExecutionOutcome

    private var _exportDestinationOutcome: ExportDestinationOutcome
    private var _exportScopeOutcome: ExportScopeOutcome
    private var _exportPlanOutcome: ExportPlanOutcome
    private var _exportExecutionOutcome: ExportExecutionOutcome

    private var _jobStatusOutcome: TransferJobStatusOutcome
    private var _cancelJobOutcome: CancelJobOutcome

    // MARK: - Call log

    /// Ordered record of every port method called during a test.
    /// Use to verify PLAN-BEFORE-MUTATION (zero execute entries when blocked)
    /// and to confirm the correct call sequence.
    private(set) var callLog: [String] = []

    // MARK: - Init

    init(
        importSourceOutcome: ImportSourceOutcome = TransferFakes.defaultImportSource(),
        importPlanOutcome: ImportPlanOutcome = .planned(TransferFakes.permittedPlan()),
        importExecutionOutcome: ImportExecutionOutcome = .submitted(
            jobID: TransferFakes.primaryJobID
        ),
        exportDestinationOutcome: ExportDestinationOutcome = TransferFakes.defaultDestination(),
        exportScopeOutcome: ExportScopeOutcome = TransferFakes.defaultScope(),
        exportPlanOutcome: ExportPlanOutcome = .planned(TransferFakes.permittedPlan()),
        exportExecutionOutcome: ExportExecutionOutcome = .submitted(
            jobID: TransferFakes.primaryJobID
        ),
        jobStatusOutcome: TransferJobStatusOutcome = .status(
            jobID: TransferFakes.primaryJobID,
            state: .running(progress: TransferProgress(processed: 5, total: 10))
        ),
        cancelJobOutcome: CancelJobOutcome = .cancelled(stage: .beforeCommit)
    ) {
        _importSourceOutcome = importSourceOutcome
        _importPlanOutcome = importPlanOutcome
        _importExecutionOutcome = importExecutionOutcome
        _exportDestinationOutcome = exportDestinationOutcome
        _exportScopeOutcome = exportScopeOutcome
        _exportPlanOutcome = exportPlanOutcome
        _exportExecutionOutcome = exportExecutionOutcome
        _jobStatusOutcome = jobStatusOutcome
        _cancelJobOutcome = cancelJobOutcome
    }

    // MARK: - Setters (awaitable from @MainActor tests)

    func setImportSourceOutcome(_ o: ImportSourceOutcome)       { _importSourceOutcome = o }
    func setImportPlanOutcome(_ o: ImportPlanOutcome)           { _importPlanOutcome = o }
    func setImportExecutionOutcome(_ o: ImportExecutionOutcome) { _importExecutionOutcome = o }
    func setExportDestinationOutcome(_ o: ExportDestinationOutcome) { _exportDestinationOutcome = o }
    func setExportScopeOutcome(_ o: ExportScopeOutcome)         { _exportScopeOutcome = o }
    func setExportPlanOutcome(_ o: ExportPlanOutcome)           { _exportPlanOutcome = o }
    func setExportExecutionOutcome(_ o: ExportExecutionOutcome) { _exportExecutionOutcome = o }
    func setJobStatusOutcome(_ o: TransferJobStatusOutcome)     { _jobStatusOutcome = o }
    func setCancelJobOutcome(_ o: CancelJobOutcome)             { _cancelJobOutcome = o }

    // MARK: - TransferPort conformance

    func selectImportSource() async -> ImportSourceOutcome {
        callLog.append("selectImportSource")
        return _importSourceOutcome
    }

    func planImport(sourceURL: URL) async -> ImportPlanOutcome {
        callLog.append("planImport")
        return _importPlanOutcome
    }

    func executeImport(planToken: String) async -> ImportExecutionOutcome {
        // This entry in the call log is the mutation-sensitive test signal.
        // PLAN-BEFORE-MUTATION tests assert this entry is absent when the
        // plan has executionPermitted == false.
        callLog.append("executeImport")
        return _importExecutionOutcome
    }

    func selectExportDestination() async -> ExportDestinationOutcome {
        callLog.append("selectExportDestination")
        return _exportDestinationOutcome
    }

    func selectExportScope() async -> ExportScopeOutcome {
        callLog.append("selectExportScope")
        return _exportScopeOutcome
    }

    func planExport(destinationURL: URL, scopeToken: String) async -> ExportPlanOutcome {
        callLog.append("planExport")
        return _exportPlanOutcome
    }

    func executeExport(planToken: String) async -> ExportExecutionOutcome {
        // Mutation-sensitive: absent from call log when plan blocks execution.
        callLog.append("executeExport")
        return _exportExecutionOutcome
    }

    func loadJobStatus(jobID: TransferJobID) async -> TransferJobStatusOutcome {
        callLog.append("loadJobStatus:\(jobID.id)")
        return _jobStatusOutcome
    }

    func cancelJob(jobID: TransferJobID) async -> CancelJobOutcome {
        callLog.append("cancelJob:\(jobID.id)")
        return _cancelJobOutcome
    }
}

// MARK: - TransferFakes — synthetic test data factory
//
// All identifiers belong to the reserved synthetic namespace:
// - Job IDs: first 8 chars are the same hex digit repeated (e.g. "aaaaaaaa-")
// - File paths: /tmp/synthetic-* names that cannot be real estate paths

enum TransferFakes {

    // MARK: - Stable synthetic job IDs (CONTRACT-08)

    /// Primary synthetic job ID — used when tests need a single stable ID.
    static let primaryJobID = TransferJobID(id: "aaaaaaaa-import-primary")
    /// Secondary synthetic job ID — used when tests need a second distinct ID.
    static let secondaryJobID = TransferJobID(id: "bbbbbbbb-export-primary")

    // MARK: - Synthetic URLs

    /// Synthetic import source — local /tmp path, never a real estate path.
    static let defaultSourceURL = URL(
        fileURLWithPath: "/tmp/synthetic-import-aaaaaaaa.moot"
    )
    /// Synthetic export destination — local /tmp path.
    static let defaultDestURL = URL(
        fileURLWithPath: "/tmp/synthetic-export-aaaaaaaa.moot"
    )

    // MARK: - Format descriptors

    static func recognizedFormat(
        name: String = "MOOTx01 Archive"
    ) -> TransferFormatDescriptor {
        TransferFormatDescriptor(name: name, recognized: true)
    }

    static func unrecognizedFormat(
        name: String = "Unknown Format"
    ) -> TransferFormatDescriptor {
        TransferFormatDescriptor(name: name, recognized: false)
    }

    // MARK: - Source / destination / scope outcomes

    static func defaultImportSource(
        format: TransferFormatDescriptor? = nil
    ) -> ImportSourceOutcome {
        .selected(
            sourceURL: defaultSourceURL,
            format: format ?? recognizedFormat()
        )
    }

    static func defaultDestination() -> ExportDestinationOutcome {
        .selected(destinationURL: defaultDestURL)
    }

    static func defaultScope(
        count: Int = 50
    ) -> ExportScopeOutcome {
        .selected(
            scopeToken: "scope-aaaaaaaa-synthetic",
            candidateCount: count,
            description: "Synthetic export scope: all public records"
        )
    }

    // MARK: - Plans

    /// A plan the daemon permits for execution.
    static func permittedPlan(
        candidates: Int = 20,
        conflicts: Int = 0,
        invalid: Int = 0,
        exclusions: Int = 0,
        estimated: Int = 20,
        token: String = "plan-token-aaaaaaaa"
    ) -> TransferPlan {
        TransferPlan(
            format: recognizedFormat(),
            candidateCount: candidates,
            conflictCount: conflicts,
            invalidCount: invalid,
            policyExclusionCount: exclusions,
            estimatedTransferCount: estimated,
            executionPermitted: true,
            planToken: token
        )
    }

    /// A plan the daemon refuses — executionPermitted == false.
    /// The model must not call executeImport/executeExport when holding this plan.
    static func refusedPlan(
        format: TransferFormatDescriptor? = nil,
        candidates: Int = 10,
        exclusions: Int = 0
    ) -> TransferPlan {
        TransferPlan(
            format: format ?? unrecognizedFormat(),
            candidateCount: candidates,
            conflictCount: 0,
            invalidCount: candidates,  // all malformed for unrecognized format
            policyExclusionCount: exclusions,
            estimatedTransferCount: 0,
            executionPermitted: false,
            planToken: "refused-plan-aaaaaaaa"
        )
    }

    // MARK: - Counts

    /// A complete-success transfer: all transferred, nothing skipped/failed.
    static func successCounts(transferred: Int = 20) -> TransferCounts {
        TransferCounts(
            transferred: transferred,
            skipped: 0,
            conflicted: 0,
            excluded: 0,
            failed: 0
        )
    }

    /// Partial counts for mid-job scenarios.
    static func partialCounts(
        transferred: Int = 10,
        skipped: Int = 2,
        conflicted: Int = 1,
        excluded: Int = 3,
        failed: Int = 4
    ) -> TransferCounts {
        TransferCounts(
            transferred: transferred,
            skipped: skipped,
            conflicted: conflicted,
            excluded: excluded,
            failed: failed
        )
    }
}
