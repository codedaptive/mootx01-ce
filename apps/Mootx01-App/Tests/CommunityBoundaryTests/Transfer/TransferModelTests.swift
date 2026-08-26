import Foundation
import MootCommunityUI
import Testing

// MARK: - TransferModelTests  (APP-06 boundary tests)
//
// Covers all eight required observable behaviors from the Community 1.1
// APP-06 requirements, plus every item in the completion evidence list.
//
// All tests exercise TransferModel through FakeTransferPort — no live estate,
// no gateway, no daemon, no DB access.
//
// FALSE-SUCCESS DISCIPLINE: where the port returns a non-success outcome,
// the test asserts the model surfaces that exact outcome and NEVER a success
// variant. Partial failure must not be surfaced as complete success.
//
// PLAN-BEFORE-MUTATION discipline (mutation-sensitive tests): tests that
// configure a refused plan (executionPermitted == false) inspect the call log
// to verify zero "executeImport" or "executeExport" port entries. The
// absence from the call log proves no mutation path was attempted.
//
// Completion evidence coverage (all items required by the spec):
//   empty input               → importPlanWithZeroCandidates
//   supported input           → permittedPlanAllowsExecution, completeSuccessAllCounts
//   unsupported format        → unsupportedFormatRefusesPlanExecutionPermission
//                               + planWithRefusedPermissionYieldsZeroImportExecuteCalls
//   malformed input           → malformedInputShownInPlanInvalidCount
//   conflicts                 → conflictsShownInPlanConflictCount
//   privacy exclusions        → privacyExclusionsShownInPlanExclusionCount
//                               + exportPlanExclusionCountNeverAddedToEstimated
//   permission loss           → planWithRefusedPermissionYieldsZeroImportExecuteCalls
//                               + planWithRefusedPermissionYieldsZeroExportExecuteCalls
//   cancellation              → cancelImportBeforeJobSubmissionIsNoOp
//                               + cancellationBeforeCommitReportsCorrectStage
//   interruption              → runningJobWaitingStateIsDistinctFromQueued
//   resume/status refresh     → jobIDIsStableAfterNavigationAndRefresh
//   partial failure           → partialFailureJobIsNotComplete
//                               + failedJobWithPartialCountsIsNotComplete
//   complete success          → completeSuccessAllCounts
//   export preview            → exportPlanExclusionCountNeverAddedToEstimated

@Suite("Transfer model behavior")
@MainActor
struct TransferModelTests {

    // MARK: - Behavior 1: Import begins with source selection and daemon plan before estate mutation

    @Test("selectImportSource records daemon outcome verbatim")
    func selectImportSourceRecordsDaemonOutcome() async throws {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)

        await model.selectImportSource()

        let outcome = try #require(
            model.importSourceOutcome,
            "importSourceOutcome must be set after selectImportSource"
        )
        if case .selected(_, let format) = outcome {
            #expect(format.recognized == true,
                    "Recognized format must be surfaced verbatim from daemon")
        } else {
            Issue.record("Expected .selected outcome, got \(outcome)")
        }
        let log = await fake.callLog
        #expect(log.contains("selectImportSource"))
    }

    @Test("planImport stores daemon plan after source selection")
    func planImportStoresDaemonPlan() async throws {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        let plan = try #require(
            model.importPlan,
            "importPlan must be set after planImport with a selected source"
        )
        #expect(plan.candidateCount == 20)
        #expect(plan.executionPermitted == true)
        let log = await fake.callLog
        #expect(log.contains("planImport"))
    }

    @Test("planImport is skipped when source was cancelled — no plan call")
    func planImportSkippedOnCancelledSource() async {
        // Requirement 1: daemon plan only follows a successful source selection.
        // A cancelled source must not trigger a plan call.
        let fake = FakeTransferPort(
            importSourceOutcome: .cancelled
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        // No plan, no port plan call.
        #expect(model.importPlan == nil,
                "Plan must not be set when source selection was cancelled")
        let log = await fake.callLog
        #expect(!log.contains("planImport"),
                "planImport port method must not be called after a cancelled source selection")
    }

    // MARK: - Behavior 2: Export begins with destination/scope selection and daemon plan

    @Test("selectExportDestination and selectExportScope precede planExport")
    func exportRequiresDestinationAndScopeBeforePlan() async throws {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)

        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()

        let plan = try #require(
            model.exportPlan,
            "exportPlan must be set after both destination and scope are selected"
        )
        #expect(plan.executionPermitted == true)
        let log = await fake.callLog
        #expect(log.contains("selectExportDestination"))
        #expect(log.contains("selectExportScope"))
        #expect(log.contains("planExport"))
    }

    @Test("planExport is skipped when destination was cancelled — no plan call")
    func planExportSkippedOnCancelledDestination() async {
        // Requirement 2: no plan without a confirmed destination.
        let fake = FakeTransferPort(
            exportDestinationOutcome: .cancelled
        )
        let model = TransferModel(port: fake)

        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()

        #expect(model.exportPlan == nil,
                "Export plan must not be set when destination was cancelled")
        let log = await fake.callLog
        #expect(!log.contains("planExport"),
                "planExport port method must not be called without a confirmed destination")
    }

    @Test("planExport is skipped when scope was cancelled — no plan call")
    func planExportSkippedOnCancelledScope() async {
        let fake = FakeTransferPort(
            exportScopeOutcome: .cancelled
        )
        let model = TransferModel(port: fake)

        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()

        #expect(model.exportPlan == nil)
        let log = await fake.callLog
        #expect(!log.contains("planExport"))
    }

    // MARK: - Behavior 3: Plans show recognized format, candidate totals, conflicts,
    //                      invalid entries, privacy exclusions, expected results

    @Test("import plan with zero candidates is surfaced accurately")
    func importPlanWithZeroCandidates() async throws {
        // Completion evidence: empty input
        let fake = FakeTransferPort(
            importPlanOutcome: .planned(TransferFakes.permittedPlan(
                candidates: 0,
                estimated: 0
            ))
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        let plan = try #require(model.importPlan)
        #expect(plan.candidateCount == 0,
                "Zero-candidate plan must be surfaced accurately — not inflated")
        #expect(plan.estimatedTransferCount == 0)
        // executionPermitted may still be true for an empty-but-recognized import.
        #expect(plan.format.recognized == true)
    }

    @Test("unsupported format plan shows unrecognized format and blocks execution")
    func unsupportedFormatRefusesPlanExecutionPermission() async throws {
        // Completion evidence: unsupported format
        let fake = FakeTransferPort(
            importPlanOutcome: .planned(TransferFakes.refusedPlan(
                format: TransferFakes.unrecognizedFormat(name: "Proprietary v3"),
                candidates: 5
            ))
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        let plan = try #require(model.importPlan)
        #expect(plan.format.recognized == false,
                "Unrecognized format must be surfaced — not promoted to recognized")
        #expect(plan.executionPermitted == false,
                "Unrecognized format must block execution permission")
        #expect(plan.format.name == "Proprietary v3")
    }

    @Test("malformed input is shown in plan invalidCount")
    func malformedInputShownInPlanInvalidCount() async throws {
        // Completion evidence: malformed input
        let fake = FakeTransferPort(
            importPlanOutcome: .planned(TransferFakes.permittedPlan(
                candidates: 15,
                invalid: 6,
                estimated: 9
            ))
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        let plan = try #require(model.importPlan)
        #expect(plan.invalidCount == 6,
                "Malformed record count must be surfaced verbatim")
        #expect(plan.candidateCount == 15)
        // Estimated does not include invalid records.
        #expect(plan.estimatedTransferCount == 9)
    }

    @Test("conflicts shown in plan conflictCount")
    func conflictsShownInPlanConflictCount() async throws {
        // Completion evidence: conflicts
        let fake = FakeTransferPort(
            importPlanOutcome: .planned(TransferFakes.permittedPlan(
                candidates: 20,
                conflicts: 4,
                estimated: 16
            ))
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        let plan = try #require(model.importPlan)
        #expect(plan.conflictCount == 4,
                "Conflict count must be surfaced — not suppressed")
        #expect(plan.candidateCount == 20)
        #expect(plan.estimatedTransferCount == 16)
    }

    @Test("privacy exclusions shown in plan policyExclusionCount")
    func privacyExclusionsShownInPlanExclusionCount() async throws {
        // Completion evidence: privacy exclusions
        let fake = FakeTransferPort(
            importPlanOutcome: .planned(TransferFakes.permittedPlan(
                candidates: 30,
                exclusions: 8,
                estimated: 22
            ))
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        let plan = try #require(model.importPlan)
        #expect(plan.policyExclusionCount == 8,
                "Privacy exclusion count must be surfaced as excluded")
        #expect(plan.estimatedTransferCount == 22,
                "estimatedTransferCount must not include policyExclusionCount")
        // Structural guard: adding exclusions to estimated would give 30.
        #expect(plan.estimatedTransferCount + plan.policyExclusionCount == 30,
                "The two counts are structurally separate — their sum is not estimated alone")
    }

    @Test("export plan policyExclusionCount is never added to estimatedTransferCount")
    func exportPlanExclusionCountNeverAddedToEstimated() async throws {
        // Completion evidence: export previews never display policy-ineligible content as included
        // Requirement 4 (policy-ineligible content discipline).
        let fake = FakeTransferPort(
            exportPlanOutcome: .planned(TransferFakes.permittedPlan(
                candidates: 50,
                exclusions: 15,
                estimated: 35
            ))
        )
        let model = TransferModel(port: fake)

        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()

        let plan = try #require(model.exportPlan)
        // The structural invariant: excluded + estimated = candidates.
        #expect(plan.policyExclusionCount == 15,
                "Policy-excluded count must be surfaced separately")
        #expect(plan.estimatedTransferCount == 35,
                "estimatedTransferCount must exclude policy-ineligible records")
        #expect(
            plan.estimatedTransferCount != plan.estimatedTransferCount + plan.policyExclusionCount,
            "Policy-ineligible count must not be merged into the transfer estimate"
        )
    }

    // MARK: - PLAN-BEFORE-MUTATION: mutation-sensitive tests
    // (a fake that refuses the plan must yield zero execute calls)

    @Test("plan with refused permission yields zero import execute calls")
    func planWithRefusedPermissionYieldsZeroImportExecuteCalls() async {
        // Completion evidence: permission loss + unsupported format
        // Mutation-sensitive: port.executeImport must never be called.
        let fake = FakeTransferPort(
            importPlanOutcome: .planned(TransferFakes.refusedPlan())
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        // Verify the plan is held but refused.
        #expect(model.importPlan?.executionPermitted == false,
                "Model must hold the refused plan without promoting it")

        // Now attempt execution — model must not call the port.
        await model.executeImport()

        let log = await fake.callLog
        #expect(!log.contains("executeImport"),
                "executeImport port method must not be called when plan.executionPermitted == false")
        // The job ID must not be set — no mutation occurred.
        #expect(model.importJobID == nil,
                "No job ID must be set when plan refused execution permission")
    }

    @Test("plan with refused permission yields zero export execute calls")
    func planWithRefusedPermissionYieldsZeroExportExecuteCalls() async {
        // Mutation-sensitive: port.executeExport must never be called.
        let fake = FakeTransferPort(
            exportPlanOutcome: .planned(TransferFakes.refusedPlan())
        )
        let model = TransferModel(port: fake)

        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()

        await model.executeExport()

        let log = await fake.callLog
        #expect(!log.contains("executeExport"),
                "executeExport port method must not be called when plan.executionPermitted == false")
        #expect(model.exportJobID == nil)
    }

    @Test("no plan at all yields zero import execute calls")
    func noPlanYieldsZeroImportExecuteCalls() async {
        // Mutation-sensitive: no plan → no port execute call.
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)

        // Skip selectImportSource/planImport — execute with no held plan.
        await model.executeImport()

        let log = await fake.callLog
        #expect(!log.contains("executeImport"),
                "executeImport must not be called without a held plan")
        #expect(model.importJobID == nil)
    }

    @Test("permitted plan allows import execution and records job ID")
    func permittedPlanAllowsImportExecution() async throws {
        // Completion evidence: supported input
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()

        let jobID = try #require(
            model.importJobID,
            "importJobID must be set after daemon accepts the import job"
        )
        #expect(jobID == TransferFakes.primaryJobID,
                "Job ID must match daemon-issued ID verbatim (CONTRACT-08)")
        let log = await fake.callLog
        #expect(log.contains("executeImport"),
                "executeImport must be called when plan permits execution")
    }

    // MARK: - Behavior 4: User can cancel before execution without changing estate

    @Test("cancel import before job submission is a no-op — zero port cancel calls")
    func cancelImportBeforeJobSubmissionIsNoOp() async {
        // Requirement 4: cancellation before execution changes nothing.
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)

        // No job submitted — model has no importJobID.
        await model.cancelImportJob()

        let log = await fake.callLog
        #expect(!log.contains { $0.hasPrefix("cancelJob") },
                "cancelJob port method must not be called when no job has been submitted")
        // No last cancel outcome — the model did nothing.
        #expect(model.lastCancelOutcome == nil)
    }

    @Test("cancel export before job submission is a no-op")
    func cancelExportBeforeJobSubmissionIsNoOp() async {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)

        await model.cancelExportJob()

        let log = await fake.callLog
        #expect(!log.contains { $0.hasPrefix("cancelJob") })
        #expect(model.lastCancelOutcome == nil)
    }

    // MARK: - Behavior 5: Running jobs show truthful progress and survive reconnect

    @Test("running job shows daemon-supplied progress verbatim")
    func runningJobShowsDaemonProgress() async throws {
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .running(progress: TransferProgress(processed: 7, total: 20))
            )
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()  // loads initial status

        if case .running(let progress) = model.importJobState {
            let p = try #require(progress, "Progress must be non-nil for a running job")
            #expect(p.processed == 7, "processed count must be daemon-supplied verbatim")
            #expect(p.total == 20, "total count must be daemon-supplied verbatim")
        } else {
            Issue.record("Expected .running state, got \(String(describing: model.importJobState))")
        }
    }

    @Test("job ID is stable after navigation and refresh — CONTRACT-08")
    func jobIDIsStableAfterNavigationAndRefresh() async throws {
        // Requirement 5: job identity survives navigation/reconnect.
        // The model must use the same stored job ID for the refresh call,
        // not synthesise a new one.
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .running(progress: TransferProgress(processed: 12, total: 20))
            )
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()

        let initialJobID = try #require(model.importJobID)

        // Simulate navigation: refresh status using the same stable job ID.
        await model.refreshImportJobStatus()

        let refreshedJobID = try #require(model.importJobID)
        #expect(initialJobID == refreshedJobID,
                "Job ID must not change after refresh — CONTRACT-08 stable identity")

        let log = await fake.callLog
        // loadJobStatus called at least twice: once at submit, once at refresh.
        #expect(log.filter { $0.hasPrefix("loadJobStatus") }.count >= 2,
                "loadJobStatus must be called on refresh using the same stable ID")
    }

    @Test("failed import refresh exposes stale status instead of silently preserving authority")
    func failedImportRefreshIsSurfaced() async throws {
        let fake = FakeTransferPort(jobStatusOutcome: .status(
            jobID: TransferFakes.primaryJobID,
            state: .running(progress: TransferProgress(processed: 4, total: 10))
        ))
        let model = TransferModel(port: fake)
        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()
        let lastConfirmed = model.importJobState

        await fake.setJobStatusOutcome(.failed(reason: "daemon-restarting"))
        await model.refreshImportJobStatus()

        #expect(model.importJobState == lastConfirmed)
        #expect(model.lastImportJobStatusOutcome == .failed(reason: "daemon-restarting"))
    }

    @Test("unknown export job is surfaced while preserving the last confirmed state")
    func unknownExportJobIsSurfaced() async throws {
        let fake = FakeTransferPort(
            exportExecutionOutcome: .submitted(jobID: TransferFakes.secondaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.secondaryJobID,
                state: .queued
            )
        )
        let model = TransferModel(port: fake)
        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()
        await model.executeExport()

        await fake.setJobStatusOutcome(.notFound)
        await model.refreshExportJobStatus()

        #expect(model.exportJobState == .queued)
        #expect(model.lastExportJobStatusOutcome == .notFound)
    }

    @Test("mismatched job identity cannot replace confirmed progress")
    func mismatchedJobIdentityIsRefused() async throws {
        let fake = FakeTransferPort(jobStatusOutcome: .status(
            jobID: TransferFakes.primaryJobID,
            state: .running(progress: TransferProgress(processed: 2, total: 10))
        ))
        let model = TransferModel(port: fake)
        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()
        let lastConfirmed = model.importJobState

        await fake.setJobStatusOutcome(.status(
            jobID: TransferFakes.secondaryJobID,
            state: .completed(counts: TransferFakes.successCounts(), receipt: "wrong-job")
        ))
        await model.refreshImportJobStatus()

        #expect(model.importJobState == lastConfirmed)
        #expect(model.lastImportJobStatusOutcome == .failed(reason: "job-identity-mismatch"))
    }

    @Test("waiting job state is surfaced as distinct from queued")
    func runningJobWaitingStateIsDistinctFromQueued() async throws {
        // Completion evidence: interruption (daemon-reported waiting state)
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .waiting(reason: "rate-limit-backoff")
            )
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()

        if case .waiting(let reason) = model.importJobState {
            #expect(reason == "rate-limit-backoff",
                    "Waiting reason must be daemon-supplied verbatim")
        } else {
            Issue.record("Expected .waiting state, got \(String(describing: model.importJobState))")
        }
        // Structural guard: waiting != queued
        if case .queued = model.importJobState {
            Issue.record("Waiting state must not collapse to queued")
        }
    }

    // MARK: - Behavior 6: Cancellation reports stage

    @Test("cancellation before commit reports .beforeCommit stage")
    func cancellationBeforeCommitReportsCorrectStage() async throws {
        // Requirement 6: stage surfaced verbatim — no collapsing.
        // Completion evidence: cancellation (before any committed work)
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .running(progress: nil)
            ),
            cancelJobOutcome: .cancelled(stage: .beforeCommit)
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()
        await model.cancelImportJob()

        if case .cancelled(let stage) = model.importJobState {
            #expect(stage == .beforeCommit,
                    "Cancel-before-commit must report .beforeCommit — no estate mutation")
        } else {
            Issue.record("Expected .cancelled state, got \(String(describing: model.importJobState))")
        }
    }

    @Test("cancellation during commit reports partial counts")
    func cancellationDuringCommitReportsPartialCounts() async throws {
        // Requirement 6: mid-commit cancellation reports daemon-supplied partial counts.
        let partial = TransferFakes.partialCounts(transferred: 6, failed: 2)
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .running(progress: nil)
            ),
            cancelJobOutcome: .cancelled(stage: .duringCommit(partial: partial))
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()
        await model.cancelImportJob()

        if case .cancelled(let stage) = model.importJobState,
           case .duringCommit(let counts) = stage {
            #expect(counts.transferred == 6)
            #expect(counts.failed == 2)
        } else {
            Issue.record("Expected .cancelled(.duringCommit) state")
        }
    }

    @Test("cancellation after commit reports committed counts")
    func cancellationAfterCommitReportsCommittedCounts() async throws {
        // Requirement 6: post-commit cancellation reports what was committed.
        let committed = TransferCounts(
            transferred: 18, skipped: 1, conflicted: 0, excluded: 1, failed: 0
        )
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .running(progress: nil)
            ),
            cancelJobOutcome: .cancelled(stage: .afterCommit(counts: committed))
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()
        await model.cancelImportJob()

        if case .cancelled(let stage) = model.importJobState,
           case .afterCommit(let counts) = stage {
            #expect(counts.transferred == 18)
            #expect(counts.excluded == 1)
        } else {
            Issue.record("Expected .cancelled(.afterCommit) state")
        }
    }

    // MARK: - Behavior 7: Completion shows all counts + stable receipt

    @Test("complete success surfaces all five counts and receipt")
    func completeSuccessAllCounts() async throws {
        // Completion evidence: complete success
        let receipt = "receipt-aaaaaaaa-synthetic"
        let counts = TransferFakes.successCounts(transferred: 20)
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .completed(counts: counts, receipt: receipt)
            )
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()

        if case .completed(let c, let r) = model.importJobState {
            #expect(c.transferred == 20, "transferred count must be daemon-supplied verbatim")
            #expect(c.skipped == 0)
            #expect(c.conflicted == 0)
            #expect(c.excluded == 0)
            #expect(c.failed == 0)
            #expect(r == receipt, "Receipt must be daemon-issued verbatim (CONTRACT-08)")
        } else {
            Issue.record("Expected .completed state, got \(String(describing: model.importJobState))")
        }
        // isImportComplete convenience flag
        #expect(model.isImportComplete,
                "isImportComplete must be true when job state is .completed")
    }

    @Test("completion with failed records surfaces all five count fields")
    func completionWithFailedRecordsSurfacesAllCounts() async throws {
        // Requirement 7: all five fields must be present even when some fail.
        let counts = TransferCounts(
            transferred: 14, skipped: 2, conflicted: 1, excluded: 3, failed: 5
        )
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .completed(counts: counts, receipt: "receipt-bbbbbbbb")
            )
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()

        if case .completed(let c, _) = model.importJobState {
            #expect(c.transferred == 14)
            #expect(c.skipped == 2)
            #expect(c.conflicted == 1)
            #expect(c.excluded == 3)
            #expect(c.failed == 5)
        } else {
            Issue.record("Expected .completed state")
        }
    }

    // MARK: - Behavior 8: Partial or failed jobs are never summarized as complete success

    @Test("partial failure job is not reported as complete success")
    func partialFailureJobIsNotComplete() async {
        // Completion evidence: partial failure
        // Requirement 8: partial failure (transferred > 0 AND failed > 0) must NOT
        // be surfaced as complete success. isImportComplete must be false.
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .failed(
                    reason: "network-interrupted",
                    partial: TransferCounts(
                        transferred: 10, skipped: 0, conflicted: 0, excluded: 0, failed: 5
                    )
                )
            )
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()

        // The job is in a failed state — must not be complete.
        #expect(!model.isImportComplete,
                "A failed job with partial counts must not be reported as complete success")
        // The failed state is surfaced, not collapsed.
        if case .failed(let reason, let partial) = model.importJobState {
            #expect(reason == "network-interrupted")
            #expect(partial?.transferred == 10,
                    "Partial committed counts must be surfaced for a failed job")
            #expect(partial?.failed == 5)
        } else {
            Issue.record("Expected .failed state, got \(String(describing: model.importJobState))")
        }
    }

    @Test("failed job with no partial counts is not reported as complete success")
    func failedJobWithNoPartialCountsIsNotComplete() async {
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .failed(reason: "permission-revoked", partial: nil)
            )
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()

        #expect(!model.isImportComplete,
                "A failed job must never be reported as complete success")
        if case .failed(let reason, let partial) = model.importJobState {
            #expect(reason == "permission-revoked")
            #expect(partial == nil,
                    "nil partial counts must be preserved — not synthesised")
        } else {
            Issue.record("Expected .failed state")
        }
    }

    @Test("cancelled-after-commit job is not reported as complete success")
    func cancelledAfterCommitIsNotComplete() async {
        let committed = TransferCounts(
            transferred: 5, skipped: 0, conflicted: 2, excluded: 0, failed: 3
        )
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .running(progress: nil)
            ),
            cancelJobOutcome: .cancelled(stage: .afterCommit(counts: committed))
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()
        await model.cancelImportJob()

        #expect(!model.isImportComplete,
                "Cancelled-after-commit must not be reported as complete success")
        if case .cancelled(let stage) = model.importJobState,
           case .afterCommit(let counts) = stage {
            #expect(counts.transferred == 5)
            #expect(counts.failed == 3)
        } else {
            Issue.record("Expected .cancelled(.afterCommit) state")
        }
    }

    @Test("cancelled-during-commit job is not reported as complete success")
    func cancelledDuringCommitIsNotComplete() async {
        let partial = TransferCounts(
            transferred: 3, skipped: 0, conflicted: 0, excluded: 0, failed: 1
        )
        let fake = FakeTransferPort(
            importExecutionOutcome: .submitted(jobID: TransferFakes.primaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.primaryJobID,
                state: .running(progress: nil)
            ),
            cancelJobOutcome: .cancelled(stage: .duringCommit(partial: partial))
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()
        await model.cancelImportJob()

        #expect(!model.isImportComplete,
                "Cancelled-during-commit must not be reported as complete success")
    }

    // MARK: - Export completion evidence

    @Test("export complete success surfaces all five counts and receipt")
    func exportCompleteSuccessAllCounts() async throws {
        let receipt = "export-receipt-aaaaaaaa-synthetic"
        let counts = TransferCounts(
            transferred: 35, skipped: 0, conflicted: 0, excluded: 0, failed: 0
        )
        let fake = FakeTransferPort(
            exportExecutionOutcome: .submitted(jobID: TransferFakes.secondaryJobID),
            jobStatusOutcome: .status(
                jobID: TransferFakes.secondaryJobID,
                state: .completed(counts: counts, receipt: receipt)
            )
        )
        let model = TransferModel(port: fake)

        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()
        await model.executeExport()

        if case .completed(let c, let r) = model.exportJobState {
            #expect(c.transferred == 35)
            #expect(c.failed == 0)
            #expect(r == receipt)
        } else {
            Issue.record("Expected .completed state, got \(String(describing: model.exportJobState))")
        }
        #expect(model.isExportComplete)
    }

    @Test("export denied does not set job ID or advance to active state")
    func exportDeniedDoesNotSetJobID() async {
        // Completion evidence: permission loss during execution
        let fake = FakeTransferPort(
            exportExecutionOutcome: .denied(reason: "policy-changed")
        )
        let model = TransferModel(port: fake)

        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()
        await model.executeExport()

        if case .denied(let r) = model.lastExportExecuteOutcome {
            #expect(r == "policy-changed",
                    "Denied reason must be daemon-supplied verbatim")
        } else {
            Issue.record("Expected .denied execute outcome")
        }
        #expect(model.exportJobID == nil,
                "No job ID must be set when daemon denied the export")
        #expect(!model.isExportComplete,
                "A denied export must not be reported as complete")
    }

    // MARK: - Planning failure — stale plan cleared

    @Test("planning failure clears stale import plan so execution is blocked")
    func planningFailureClearsStalePlan() async {
        // If planning fails, any previously held plan must be cleared.
        // This prevents a stale permitted plan from gating a new failed attempt.
        let fake = FakeTransferPort(
            importPlanOutcome: .failed(reason: "daemon-unavailable")
        )
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        #expect(model.importPlan == nil,
                "importPlan must be nil after planning fails — stale plan cleared")
        #expect(!model.canExecuteImport,
                "canExecuteImport must be false when no plan is held")

        // Confirm zero execute calls after failed planning.
        await model.executeImport()
        let log = await fake.callLog
        #expect(!log.contains("executeImport"),
                "executeImport must not be called when no plan is held after failure")
    }

    // MARK: - canExecuteImport / canExecuteExport guards (view-layer helpers)

    @Test("canExecuteImport is false at init and after refused plan")
    func canExecuteImportFalseWithoutPlan() async {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)

        // At init: no plan → false.
        #expect(!model.canExecuteImport,
                "canExecuteImport must be false at model init (no plan)")

        // After refused plan: plan held but executionPermitted == false → false.
        await fake.setImportPlanOutcome(.planned(TransferFakes.refusedPlan()))
        await model.selectImportSource()
        await model.planImport()
        #expect(!model.canExecuteImport,
                "canExecuteImport must be false when plan.executionPermitted == false")
    }

    @Test("canExecuteImport is true only after daemon issues a permitted plan")
    func canExecuteImportTrueWithPermittedPlan() async {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)

        await model.selectImportSource()
        await model.planImport()

        #expect(model.canExecuteImport,
                "canExecuteImport must be true when plan.executionPermitted == true")
    }

    // MARK: - FIX 3: Plan / execute / cancel outcome surfacing

    // The views cannot be directly tested in this harness (no SwiftUI runtime).
    // These tests verify the model exposes outcome fields in the form the views
    // consume: the field is non-nil after a failure, and user-visible reason strings
    // are derivable (non-nil, non-empty).

    @Test("FIX 3: import plan failure exposed in lastImportPlanOutcome with reason")
    func importPlanFailureExposedForView() async throws {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)
        await fake.setImportPlanOutcome(.failed(reason: "vault-locked"))

        await model.selectImportSource()
        await model.planImport()

        let outcome = try #require(model.lastImportPlanOutcome,
                                   "lastImportPlanOutcome must be set after a failed plan")
        if case .failed(let reason) = outcome {
            #expect(!reason.isEmpty, "plan failure reason must be non-empty for the view to surface")
            #expect(reason == "vault-locked")
        } else {
            Issue.record("Expected .failed import plan outcome, got \(outcome)")
        }
        // Plan must have been cleared on failure (stale-gate discipline).
        #expect(model.importPlan == nil,
                "importPlan must be nil after planning failure")
    }

    @Test("FIX 3: export plan failure exposed in lastExportPlanOutcome with reason")
    func exportPlanFailureExposedForView() async throws {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)
        await fake.setExportPlanOutcome(.failed(reason: "permission-revoked"))

        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()

        let outcome = try #require(model.lastExportPlanOutcome)
        if case .failed(let reason) = outcome {
            #expect(!reason.isEmpty)
            #expect(reason == "permission-revoked")
        } else {
            Issue.record("Expected .failed export plan outcome, got \(outcome)")
        }
        #expect(model.exportPlan == nil)
    }

    @Test("FIX 3: import execute denial exposed in lastImportExecuteOutcome — the permission-loss-at-execute case")
    func importExecuteDenialExposedForView() async throws {
        // This is the permission-loss-at-execute case: plan was permitted at planning
        // time but the daemon revoked permission before execution. The button currently
        // looks like it did nothing — FIX 3 makes the view surface this state.
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)
        await fake.setImportExecutionOutcome(.denied(reason: "permission-revoked-at-execute"))

        await model.selectImportSource()
        await model.planImport()  // plan is permitted
        await model.executeImport()  // daemon denies at execute time

        let outcome = try #require(model.lastImportExecuteOutcome,
                                   "lastImportExecuteOutcome must be set after a denied execute")
        if case .denied(let reason) = outcome {
            #expect(!reason.isEmpty, "denial reason must be non-empty for the view to surface")
            #expect(reason == "permission-revoked-at-execute")
        } else {
            Issue.record("Expected .denied import execute outcome, got \(outcome)")
        }
        // No job ID must be produced — fail-closed.
        #expect(model.importJobID == nil,
                "importJobID must not be set after a denied execute")
    }

    @Test("FIX 3: import execute failure exposed in lastImportExecuteOutcome")
    func importExecuteFailureExposedForView() async throws {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)
        await fake.setImportExecutionOutcome(.failed(reason: "system-error"))

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()

        let outcome = try #require(model.lastImportExecuteOutcome)
        if case .failed(let reason) = outcome {
            #expect(!reason.isEmpty)
            #expect(reason == "system-error")
        } else {
            Issue.record("Expected .failed import execute outcome, got \(outcome)")
        }
        #expect(model.importJobID == nil)
    }

    @Test("FIX 3: export execute denial exposed in lastExportExecuteOutcome")
    func exportExecuteDenialExposedForView() async throws {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)
        await fake.setExportExecutionOutcome(.denied(reason: "export-policy-blocked"))

        await model.selectExportDestination()
        await model.selectExportScope()
        await model.planExport()
        await model.executeExport()

        let outcome = try #require(model.lastExportExecuteOutcome)
        if case .denied(let reason) = outcome {
            #expect(!reason.isEmpty)
            #expect(reason == "export-policy-blocked")
        } else {
            Issue.record("Expected .denied export execute outcome, got \(outcome)")
        }
        #expect(model.exportJobID == nil)
    }

    @Test("FIX 3: cancel failure exposed in lastCancelOutcome with reason")
    func cancelFailureExposedForView() async throws {
        // A failed cancel currently looks like success (job state unchanged, no feedback).
        // FIX 3 makes the view surface this near the cancel button.
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)
        await fake.setCancelJobOutcome(.failed(reason: "cancel-request-failed"))

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()
        await model.cancelImportJob()

        let outcome = try #require(model.lastCancelOutcome,
                                   "lastCancelOutcome must be set after a failed cancel")
        if case .failed(let reason) = outcome {
            #expect(!reason.isEmpty, "cancel failure reason must be non-empty for the view to surface")
            #expect(reason == "cancel-request-failed")
        } else {
            Issue.record("Expected .failed cancel outcome, got \(outcome)")
        }
    }

    @Test("FIX 3: cancel notFound exposed in lastCancelOutcome")
    func cancelNotFoundExposedForView() async throws {
        let fake = FakeTransferPort()
        let model = TransferModel(port: fake)
        await fake.setCancelJobOutcome(.notFound)

        await model.selectImportSource()
        await model.planImport()
        await model.executeImport()
        await model.cancelImportJob()

        let outcome = try #require(model.lastCancelOutcome)
        #expect(outcome == .notFound,
                "lastCancelOutcome must be .notFound when the daemon reports the job unknown")
    }
}
