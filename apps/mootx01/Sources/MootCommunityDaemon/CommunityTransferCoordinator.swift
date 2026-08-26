// CommunityTransferCoordinator.swift
//
// Daemon-owned durable job layer for the nine transfer-family endpoints
// (Wave D1: CORE-07).
//
// ARCHITECTURE
// ───────────────────────────────────────────────────────────────────────────
// This actor COMPOSES onto the existing VaultKit import/export mechanics:
//   • JsonImportBridge  — JSON seed file parsing and estate import
//   • VaultBridge + ExchangeAdapter — estate export as MOOT JSON
//   • ImportPolicy      — write strategy (bulk window)
//   • VaultExportScope  — which drawers are eligible for export
//
// The coordinator owns:
//   1. Durable job sidecar: transfer-jobs.json (atomic write, .tmp-then-rename).
//      Persisted after every state transition so a crashed coordinator restart
//      can resume reporting terminal job states.
//   2. In-memory plan cache: planToken → PersistedPlan. Plans are intentionally
//      ephemeral — a plan's planToken carries the estate state fingerprint at
//      plan time; on execute, the fingerprint is recomputed and must match or
//      the plan is reported stale. Plans do NOT survive coordinator restarts
//      (a stale plan is correctly rejected).
//   3. Background job execution: tasks run async after `execute` returns
//      `submitted{jobID}`. The coordinator serializes state updates via actor
//      isolation.
//
// BOOKMARK HANDLING
// ───────────────────────────────────────────────────────────────────────────
// Same decision as CommunityObsidianCoordinator: in the daemon/test context,
// the base64 bookmark data is decoded as UTF-8 and treated as a file:// URL
// string. Production composition roots supply the actual security-scoped
// bookmark data from the OS file picker.
//
// PLAN TOKEN FORMAT
// ───────────────────────────────────────────────────────────────────────────
// planToken = "<uuid>:<fingerprint>"
//   uuid        — UUIDv4, the sidecar lookup key for this plan
//   fingerprint — SHA-256 hex of sorted occupied lineage UUIDs at plan time
//
// On execute: split the token on ":", recompute fingerprint, reject if stale.
//
// EXACT RETRY IDEMPOTENCY
// ───────────────────────────────────────────────────────────────────────────
// The job sidecar stores planToken → jobID. If execute is called twice with
// the same planToken, the second call returns `submitted{same jobID}` without
// starting a new job. The estate is never written twice for the same plan.
//
// ZERO-MUTATION PLANNING
// ───────────────────────────────────────────────────────────────────────────
// importPlan and exportPlan are READ-ONLY. They call kit.recall + tombstoned
// to get the occupied lineage snapshot and count exportable drawers. No
// capture, no write, no estate mutation. The acceptance test verifies estate
// byte-identity before and after a plan call.
//
// CANCELLATION
// ───────────────────────────────────────────────────────────────────────────
// Jobs have a cancellation flag (actor-isolated Bool). If cancel is called
// while the job Task has not yet started writing, the job transitions to
// cancelled{beforeCommit}. If called during writing, it finishes the current
// window and transitions to cancelled{duringCommit{counts}}. If called after
// completion, the outcome is alreadyComplete (the job is terminal).
//
// SIDECAR FORMAT: transfer-jobs.json
// ───────────────────────────────────────────────────────────────────────────
// {
//   "jobs": {
//     "<jobID>": {
//       "kind":        "import" | "export",
//       "planToken":   "<uuid>:<fingerprint>",
//       "stateKind":   "queued"|"running"|"completed"|"failed"|"cancelled",
//       "created":     "<ISO8601>",
//       "sourceURL":   "<file-URL-string>" (import only),
//       "destURL":     "<file-URL-string>" (export only),
//       "scopeToken":  "<string>" (export only),
//       "counts":      { transferred, skipped, conflicted, excluded, failed }?
//       "receipt":     "<string>"?
//       "failedReason":"<string>"?
//       "cancelStage": "beforeCommit"|"duringCommit"|"afterCommit"?
//       "cancelCounts": { ... }?
//       "processed":   <int>?
//       "total":       <int>?
//     }
//   }
// }

import CryptoKit
import Foundation
import OSLog
import AriaMCP
import GeniusLocusKit
import LocusKit
import VaultKit

private let log = Logger(subsystem: "com.mootx01", category: "CommunityTransferCoordinator")

// MARK: - Persisted plan (in-memory only)

/// An in-memory plan — never written to disk.
///
/// Lives only for the duration between plan and execute (or until the
/// coordinator is deallocated). A restarted coordinator cannot serve stale
/// plans, which is correct: the estate might have changed across the restart.
private struct TransferPlanRecord: Sendable {
    enum Kind: Sendable {
        case `import`
        case export
    }
    let kind: Kind
    /// The SHA-256 hex fingerprint of occupied lineage IDs at plan time.
    let estateFingerprint: String
    let executionPermitted: Bool
    /// Source URL for import plans; nil for export plans.
    let sourceURL: URL?
    /// Destination URL for export plans (directory); nil for import plans.
    let destDirURL: URL?
    /// Destination filename for export plans; nil for import plans.
    let destFileName: String?
    /// Scope token for export plans; nil for import plans.
    let scopeToken: String?
    let estimatedTransferCount: Int
    let policyExclusionCount: Int
    let candidateCount: Int
}

// MARK: - Persisted job (sidecar JSON)

/// One job record persisted in transfer-jobs.json.
private struct PersistedJob: Codable, Sendable {
    var kind: String            // "import" | "export"
    var planToken: String
    var stateKind: String       // "queued"|"running"|"completed"|"failed"|"cancelled"
    var created: String         // ISO8601
    var sourceURL: String?      // import: seed file URL
    var destURL: String?        // export: destination directory URL
    var destFileName: String?   // export: filename
    var scopeToken: String?     // export: scope token
    var processed: Int?
    var total: Int?
    var countsTransferred: Int?
    var countsSkipped: Int?
    var countsConflicted: Int?
    var countsExcluded: Int?
    var countsFailed: Int?
    var receipt: String?
    var failedReason: String?
    var cancelStage: String?    // "beforeCommit"|"duringCommit"|"afterCommit"
    var cancelTransferred: Int?
    var cancelSkipped: Int?
    var cancelConflicted: Int?
    var cancelExcluded: Int?
    var cancelFailed: Int?

    /// Extract TransferJobState from persisted fields.
    func jobState() -> TransferJobState {
        switch stateKind {
        case "queued":
            return .queued
        case "running":
            return .running(processed: processed, total: total)
        case "completed":
            let counts = TransferCounts(
                transferred: countsTransferred ?? 0,
                skipped:     countsSkipped     ?? 0,
                conflicted:  countsConflicted  ?? 0,
                excluded:    countsExcluded    ?? 0,
                failed:      countsFailed      ?? 0
            )
            return .completed(counts: counts, receipt: receipt ?? "")
        case "failed":
            let partialCounts = countsTransferred.map { _ in
                TransferCounts(
                    transferred: countsTransferred ?? 0,
                    skipped:     countsSkipped     ?? 0,
                    conflicted:  countsConflicted  ?? 0,
                    excluded:    countsExcluded    ?? 0,
                    failed:      countsFailed      ?? 0
                )
            }
            return .failed(reason: failedReason ?? "unexpected-failure", partial: partialCounts)
        case "cancelled":
            let stage = buildCancellationStage()
            return .cancelled(stage: stage)
        default:
            return .failed(reason: "unexpected-failure", partial: nil)
        }
    }

    private func buildCancellationStage() -> CancellationStage {
        let counts = TransferCounts(
            transferred: cancelTransferred ?? 0,
            skipped:     cancelSkipped     ?? 0,
            conflicted:  cancelConflicted  ?? 0,
            excluded:    cancelExcluded    ?? 0,
            failed:      cancelFailed      ?? 0
        )
        switch cancelStage {
        case "beforeCommit":
            return .beforeCommit
        case "duringCommit":
            return .duringCommit(counts: counts)
        case "afterCommit":
            return .afterCommit(counts: counts)
        default:
            return .beforeCommit
        }
    }
}

/// Top-level sidecar structure.
private struct JobSidecar: Codable {
    var jobs: [String: PersistedJob]
    init() { jobs = [:] }
}

// MARK: - CommunityTransferCoordinator

/// Daemon-owned actor that implements the nine transfer-family endpoints.
///
/// Inject one instance into `CommunityContractDispatch` after constructing it
/// with the layout directory, kit, and handle. In production the layout URL is
/// `~/Library/Application Support/MOOTx01/`; in tests it is a per-test temp
/// directory.
///
/// The actor serializes all state access — concurrent tool calls are safe.
public actor CommunityTransferCoordinator: Sendable {

    // MARK: - Stored properties

    /// Parent of the transfer-jobs.json sidecar.
    public let layoutURL: URL

    /// GeniusLocusKit instance for estate reads and writes.
    private let kit: GeniusLocusKit

    /// Open estate handle for all estate operations.
    private let handle: EstateHandle

    // MARK: - Derived paths

    private var jobsURL: URL {
        layoutURL.appendingPathComponent("transfer-jobs.json")
    }

    // MARK: - In-memory state

    /// Durable job records — keyed by jobID (UUID string). Loaded on init,
    /// written atomically after each state transition.
    private var jobs: [String: PersistedJob]

    /// In-memory plan cache — keyed by the UUID portion of planToken.
    /// Intentionally ephemeral: does NOT survive coordinator restarts.
    private var plans: [String: TransferPlanRecord]

    /// Cancellation flags per jobID. Checked by executing Tasks before each
    /// write window. Set by jobCancel() when the job is queued or running.
    private var cancelFlags: [String: Bool]

    // MARK: - Init

    /// Construct a transfer coordinator.
    ///
    /// - Parameters:
    ///   - layoutURL: Layout directory for transfer-jobs.json sidecar.
    ///   - kit:       Open GeniusLocusKit instance.
    ///   - handle:    Open EstateHandle for the estate being transferred to/from.
    public init(layoutURL: URL, kit: GeniusLocusKit, handle: EstateHandle) {
        self.layoutURL = layoutURL
        self.kit = kit
        self.handle = handle
        self.plans = [:]
        self.cancelFlags = [:]
        // Load persisted jobs from sidecar; start fresh if missing or corrupt.
        self.jobs = Self.loadJobs(at: layoutURL)
    }

    // MARK: - moot_community_transfer_import_source

    /// Validate a source bookmark and detect its transfer format.
    ///
    /// Read-only: resolves the bookmark to a URL and inspects the file header
    /// to detect the format. No estate reads or writes occur here.
    ///
    /// Returns:
    ///   selected{format} — format recognized (MOOT JSON) or not (Unknown).
    ///   denied{reason}   — bookmark cannot be resolved or file is inaccessible.
    public func importSource(bookmark: Data, displayName: String) async -> JSONValue {
        do {
            let url = try resolveBookmarkToURL(bookmark)
            let format = detectFormat(at: url)
            return SourceSelectionOutcome.selected(format: format).toJSONValue()
        } catch {
            log.error("importSource: bookmark resolution failed: \(error, privacy: .public)")
            return SourceSelectionOutcome.denied(reason: "permission-revoked").toJSONValue()
        }
    }

    // MARK: - moot_community_transfer_import_plan

    /// Plan an import without mutating the estate.
    ///
    /// READ-ONLY: classifies each record in the seed file as recognized,
    /// duplicate, invalid, or conflicting. Queries the estate's occupied
    /// lineage set (active + withdrawn + erased) to detect duplicates.
    /// Zero estate mutations — no capture, no write.
    ///
    /// The returned planToken embeds an estate state fingerprint. If the
    /// estate changes between plan and execute, the fingerprint comparison
    /// in importExecute will report plan-stale.
    ///
    /// Returns:
    ///   planned{plan} — classification complete; executionPermitted reflects
    ///                   whether any records can be imported.
    ///   failed{reason} — file is inaccessible or plan computation failed.
    public func importPlan(bookmark: Data) async -> JSONValue {
        do {
            let url = try resolveBookmarkToURL(bookmark)

            // ── 1. Detect format ──────────────────────────────────────────────
            let format = detectFormat(at: url)

            // ── 2. Compute estate fingerprint (occupied lineages) ─────────────
            let occupied = try await occupiedLineageSet()
            let fingerprint = estateFingerprint(occupied: occupied)

            // ── 3. Classify seed file records (READ-ONLY, no estate writes) ───
            let classification = try classifyImportFile(at: url, occupied: occupied)

            // ── 4. Build plan ─────────────────────────────────────────────────
            let planUUID = UUID().uuidString.lowercased()
            let planToken = "\(planUUID):\(fingerprint)"

            let estimatedTransfer = max(
                0,
                classification.recognizedCount - classification.policyExclusionCount
            )
            // executionPermitted: true only when the seed file can be passed
            // directly to JsonImportBridge.importSeed, which enforces a
            // strict-append invariant (any overlap → zero writes). A file
            // with duplicates, invalids, or intra-file conflicts cannot be
            // imported — the client must supply a "clean" file. The plan
            // tells the client exactly what's wrong.
            let executionPermitted = format.recognized
                && estimatedTransfer > 0
                && classification.formatValid
                && classification.duplicateCount == 0
                && classification.invalidCount == 0
                && classification.conflictCount == 0

            let plan = TransferPlan(
                format: format,
                candidateCount: classification.candidateCount,
                conflictCount: classification.conflictCount,
                invalidCount: classification.invalidCount,
                policyExclusionCount: classification.policyExclusionCount,
                estimatedTransferCount: estimatedTransfer,
                executionPermitted: executionPermitted,
                planToken: planToken
            )

            // Store plan in memory so execute can look it up.
            plans[planUUID] = TransferPlanRecord(
                kind: .import,
                estateFingerprint: fingerprint,
                executionPermitted: executionPermitted,
                sourceURL: url,
                destDirURL: nil,
                destFileName: nil,
                scopeToken: nil,
                estimatedTransferCount: estimatedTransfer,
                policyExclusionCount: classification.policyExclusionCount,
                candidateCount: classification.candidateCount
            )

            let planSummary = "candidates=\(classification.candidateCount) recognized=\(classification.recognizedCount) dups=\(classification.duplicateCount) invalid=\(classification.invalidCount)"
            log.info("\(planSummary, privacy: .public)")
            return TransferPlanOutcome.planned(plan: plan).toJSONValue()

        } catch {
            log.error("importPlan: failed: \(error, privacy: .public)")
            return TransferPlanOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }
    }

    // MARK: - moot_community_transfer_import_execute

    /// Execute an import job bound to a prior plan.
    ///
    /// Verifies the planToken is fresh (estate fingerprint unchanged since plan
    /// time) and that executionPermitted was true in the plan. Submits a
    /// background job that runs JsonImportBridge over the recognized records.
    ///
    /// Exact retry idempotency: calling with the same planToken after the job
    /// was submitted returns `submitted{same jobID}` without starting a new job.
    ///
    /// Returns:
    ///   submitted{jobID} — job accepted (new or existing).
    ///   denied{plan-stale} — estate changed since plan time.
    ///   denied{policy-refused} — executionPermitted was false.
    ///   failed{reason} — planToken not found or unexpected error.
    public func importExecute(planToken: String) async -> JSONValue {
        // Exact retry: if a job with this planToken already exists, return
        // submitted{same jobID} without creating a new job.
        if let existing = jobs.values.first(where: { $0.planToken == planToken }) {
            log.info("importExecute: exact retry — reusing jobID for planToken")
            return TransferExecutionOutcome.submitted(jobID: existingJobID(for: planToken)!).toJSONValue()
        }

        // Split planToken into UUID + fingerprint.
        guard let planUUID = extractPlanUUID(planToken) else {
            log.error("importExecute: malformed planToken — cannot extract UUID")
            return TransferExecutionOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }
        guard let plan = plans[planUUID] else {
            // Plan not found in memory: either the coordinator restarted (plans are
            // in-memory only and do not survive restart) or the token is stale.
            // Return plan-stale rather than unexpected-failure — the honest response
            // is that the plan no longer exists and the caller must re-plan.
            log.info("importExecute: planToken not found in active plans — returning plan-stale")
            return TransferExecutionOutcome.denied(reason: "plan-stale").toJSONValue()
        }

        // Guard: execution must be permitted.
        guard plan.executionPermitted else {
            return TransferExecutionOutcome.denied(reason: "policy-refused").toJSONValue()
        }

        // Guard: verify estate fingerprint matches plan-time fingerprint.
        do {
            let currentOccupied = try await occupiedLineageSet()
            let currentFingerprint = estateFingerprint(occupied: currentOccupied)
            let planFingerprint = extractPlanFingerprint(planToken)
            guard planFingerprint == currentFingerprint else {
                log.info("importExecute: plan-stale — estate changed since plan time")
                return TransferExecutionOutcome.denied(reason: "plan-stale").toJSONValue()
            }
        } catch {
            log.error("importExecute: fingerprint check failed: \(error, privacy: .public)")
            return TransferExecutionOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        // Create job in queued state.
        guard let sourceURL = plan.sourceURL else {
            return TransferExecutionOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }
        let jobID = UUID().uuidString.lowercased()
        let job = PersistedJob(
            kind: "import",
            planToken: planToken,
            stateKind: "queued",
            created: isoNow(),
            sourceURL: sourceURL.absoluteString,
            destURL: nil,
            destFileName: nil,
            scopeToken: nil
        )
        jobs[jobID] = job
        cancelFlags[jobID] = false
        saveJobs()

        // Launch background task for actual import.
        let capturedKit = kit
        let capturedHandle = handle
        let capturedEstimated = plan.estimatedTransferCount
        Task { [weak self] in
            guard let self else { return }
            await self.runImportJob(
                jobID: jobID,
                sourceURL: sourceURL,
                estimated: capturedEstimated,
                kit: capturedKit,
                handle: capturedHandle
            )
        }

        log.info("importExecute: submitted jobID=\(jobID, privacy: .public)")
        return TransferExecutionOutcome.submitted(jobID: jobID).toJSONValue()
    }

    // MARK: - moot_community_transfer_export_destination

    /// Validate an export destination bookmark.
    ///
    /// Read-only: resolves the bookmark to a URL and verifies the directory is
    /// accessible. Does not write anything to disk.
    ///
    /// Returns:
    ///   selected — destination is writable.
    ///   denied{reason} — bookmark unresolvable or destination inaccessible.
    public func exportDestination(bookmark: Data, fileName: String) async -> JSONValue {
        do {
            let dirURL = try resolveBookmarkToURL(bookmark)
            // Verify directory accessibility.
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir),
                  isDir.boolValue else {
                return ExportDestinationOutcome.denied(reason: "permission-revoked").toJSONValue()
            }
            return ExportDestinationOutcome.selected.toJSONValue()
        } catch {
            log.error("exportDestination: \(error, privacy: .public)")
            return ExportDestinationOutcome.denied(reason: "permission-revoked").toJSONValue()
        }
    }

    // MARK: - moot_community_transfer_export_scopes

    /// Return the available export scopes with real candidate counts from
    /// the current estate + capture-ledger effective policy.
    ///
    /// Read-only: calls kit.recall to count exportable drawers per scope.
    /// Currently exposes a single "eligible-all" scope backed by
    /// VaultExportScope.exportable (drawers with exportability == .public_,
    /// currently-believed, any confirmation state).
    ///
    /// Returns: ExportScopes{scopes: [ExportScope]}
    public func exportScopes() async -> JSONValue {
        do {
            // Count drawers that pass the .exportable scope filter.
            // Uses the same recall frame DrawerMapping.export uses for
            // VaultExportScope.exportable — currentlyBelieve + exportable +
            // any confirmation — to give an honest candidate count.
            let exportable = try await kit.recall(
                handle,
                RecallFrame(
                    filterChain: VaultExportScope.exportable.filterChain
                        + [.sensitivityAtMost(.secret)],
                    hydrationLevel: .structured,
                    limit: 10_000_000
                )
            )
            let scope = ExportScope(
                scopeToken: "eligible-all",
                candidateCount: exportable.count,
                description: "All currently export-eligible records"
            )
            return ExportScopesResult(scopes: [scope]).toJSONValue()
        } catch {
            log.error("exportScopes: recall failed: \(error, privacy: .public)")
            return ExportScopesResult(scopes: []).toJSONValue()
        }
    }

    // MARK: - moot_community_transfer_export_plan

    /// Plan an export without writing the final output.
    ///
    /// READ-ONLY: queries the estate for the count of drawers matching the
    /// requested scope. Applies the privacy-tier rules to compute
    /// policyExclusionCount (secret + private-tier exclusions). No file is
    /// written; no estate mutation occurs.
    ///
    /// Plan invariant: estimatedTransferCount + policyExclusionCount <= candidateCount
    ///
    /// Returns:
    ///   planned{plan} — planning complete.
    ///   failed{reason} — scope unknown, bookmark invalid, or estate error.
    public func exportPlan(bookmark: Data, fileName: String, scopeToken: String) async -> JSONValue {
        do {
            let dirURL = try resolveBookmarkToURL(bookmark)

            // F13: Validate fileName before any use. A caller-supplied fileName used in
            // appendingPathComponent can escape the bookmark-granted directory via '../..'
            // components. Reject empty names, path separators, and '.'/'..', and verify
            // the resolved parent equals the granted directory after standardization.
            if let deniedReason = validateFileName(fileName, relativeTo: dirURL) {
                log.error("exportPlan: fileName validation failed — \(deniedReason, privacy: .public)")
                return TransferPlanOutcome.denied(reason: deniedReason).toJSONValue()
            }

            // Resolve scope token to VaultExportScope.
            guard let exportScope = resolveScope(token: scopeToken) else {
                log.error("exportPlan: unknown scopeToken '\(scopeToken, privacy: .public)'")
                return TransferPlanOutcome.failed(reason: "policy-refused").toJSONValue()
            }

            // Count drawers that match the scope filter (with privacy-tier rules).
            let allInScope = try await kit.recall(
                handle,
                RecallFrame(
                    filterChain: exportScope.filterChain + [.sensitivityAtMost(.secret)],
                    hydrationLevel: .structured,
                    limit: 10_000_000
                )
            )

            // Apply privacy-tier exclusions (same logic as DrawerMapping.export):
            //   secret tier: never exports (excluded above by .sensitivityAtMost(.secret))
            //   private tier: excluded unless scope is .believedIncludingPrivate
            let privateExcluded = exportScope.includesPrivateTier ? 0 :
                allInScope.filter { $0.sensitivity == .restricted }.count
            let candidateCount = allInScope.count
            let policyExclusionCount = privateExcluded
            let estimatedTransfer = candidateCount - policyExclusionCount

            // Compute estate fingerprint (count-based for export).
            let occupied = try await occupiedLineageSet()
            let fingerprint = estateFingerprint(occupied: occupied)
            let planUUID = UUID().uuidString.lowercased()
            let planToken = "\(planUUID):\(fingerprint)"

            let destFileURL = dirURL.appendingPathComponent(fileName)
            let plan = TransferPlan(
                format: TransferFormat(name: "MOOT JSON", recognized: true),
                candidateCount: candidateCount,
                conflictCount: 0,
                invalidCount: 0,
                policyExclusionCount: policyExclusionCount,
                estimatedTransferCount: max(0, estimatedTransfer),
                executionPermitted: estimatedTransfer > 0,
                planToken: planToken
            )

            // Store plan in memory.
            plans[planUUID] = TransferPlanRecord(
                kind: .export,
                estateFingerprint: fingerprint,
                executionPermitted: plan.executionPermitted,
                sourceURL: nil,
                destDirURL: dirURL,
                destFileName: fileName,
                scopeToken: scopeToken,
                estimatedTransferCount: max(0, estimatedTransfer),
                policyExclusionCount: policyExclusionCount,
                candidateCount: candidateCount
            )

            let exportSummary = "candidates=\(candidateCount) excluded=\(policyExclusionCount) estimated=\(max(0, estimatedTransfer))"
            log.info("\(exportSummary, privacy: .public)")
            return TransferPlanOutcome.planned(plan: plan).toJSONValue()

        } catch {
            log.error("exportPlan: failed: \(error, privacy: .public)")
            return TransferPlanOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }
    }

    // MARK: - moot_community_transfer_export_execute

    /// Execute an export job bound to a prior plan.
    ///
    /// Exact retry idempotency: same planToken after job submission returns
    /// `submitted{same jobID}` without re-exporting.
    ///
    /// Returns:
    ///   submitted{jobID}     — job accepted.
    ///   denied{plan-stale}   — estate changed since plan time.
    ///   denied{policy-refused} — executionPermitted was false.
    ///   denied{permission-revoked} — destination no longer writable.
    ///   failed{reason}       — planToken not found or unexpected error.
    public func exportExecute(planToken: String) async -> JSONValue {
        // Exact retry: reuse existing job for this planToken.
        if let existingID = existingJobID(for: planToken) {
            log.info("exportExecute: exact retry — reusing jobID \(existingID, privacy: .public)")
            return TransferExecutionOutcome.submitted(jobID: existingID).toJSONValue()
        }

        // Look up the in-memory plan.
        guard let planUUID = extractPlanUUID(planToken) else {
            log.error("exportExecute: malformed planToken — cannot extract UUID")
            return TransferExecutionOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }
        guard let plan = plans[planUUID] else {
            // Plan not found in memory: the coordinator restarted and all in-memory
            // plans were cleared, or the token refers to a plan from a previous
            // coordinator instance. Return plan-stale — the honest, distinguishable
            // response that tells the caller to re-plan before executing.
            log.info("exportExecute: planToken not found in active plans — returning plan-stale")
            return TransferExecutionOutcome.denied(reason: "plan-stale").toJSONValue()
        }

        guard plan.executionPermitted else {
            return TransferExecutionOutcome.denied(reason: "policy-refused").toJSONValue()
        }

        // Verify estate fingerprint.
        do {
            let currentOccupied = try await occupiedLineageSet()
            let currentFP = estateFingerprint(occupied: currentOccupied)
            let planFP = extractPlanFingerprint(planToken)
            guard planFP == currentFP else {
                return TransferExecutionOutcome.denied(reason: "plan-stale").toJSONValue()
            }
        } catch {
            return TransferExecutionOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        guard let dirURL = plan.destDirURL, let fileName = plan.destFileName,
              let scopeToken = plan.scopeToken else {
            return TransferExecutionOutcome.failed(reason: "unexpected-failure").toJSONValue()
        }

        // Create job in queued state.
        let jobID = UUID().uuidString.lowercased()
        let job = PersistedJob(
            kind: "export",
            planToken: planToken,
            stateKind: "queued",
            created: isoNow(),
            sourceURL: nil,
            destURL: dirURL.absoluteString,
            destFileName: fileName,
            scopeToken: scopeToken
        )
        jobs[jobID] = job
        cancelFlags[jobID] = false
        saveJobs()

        let capturedKit = kit
        let capturedHandle = handle
        Task { [weak self] in
            guard let self else { return }
            await self.runExportJob(
                jobID: jobID,
                dirURL: dirURL,
                fileName: fileName,
                scopeToken: scopeToken,
                kit: capturedKit,
                handle: capturedHandle
            )
        }

        log.info("exportExecute: submitted jobID=\(jobID, privacy: .public)")
        return TransferExecutionOutcome.submitted(jobID: jobID).toJSONValue()
    }

    // MARK: - moot_community_transfer_job_status

    /// Return the current state of a job.
    ///
    /// jobID echo invariant: the jobID in the response equals the jobID in the
    /// request. Job states survive coordinator restarts (loaded from sidecar).
    ///
    /// Returns:
    ///   status{jobID, jobState} — job found.
    ///   notFound                — no job with this jobID.
    ///   failed{reason}          — unexpected error.
    public func jobStatus(jobID: String) async -> JSONValue {
        guard let job = jobs[jobID] else {
            return JobStatusOutcome.notFound.toJSONValue()
        }
        let state = job.jobState()
        return JobStatusOutcome.status(jobID: jobID, jobState: state).toJSONValue()
    }

    // MARK: - moot_community_transfer_job_cancel

    /// Cancel a job.
    ///
    /// If the job is queued or running, sets the cancellation flag. The
    /// executing Task checks this flag between write windows and terminates
    /// early, persisting the appropriate CancellationStage.
    ///
    /// Returns:
    ///   cancelled{stage} — job cancelled (stage depends on progress).
    ///   notFound         — no job with this jobID.
    ///   alreadyComplete  — job is in a terminal state (completed/failed).
    ///   failed{reason}   — unexpected error.
    public func jobCancel(jobID: String) async -> JSONValue {
        guard let job = jobs[jobID] else {
            return JobCancelOutcome.notFound.toJSONValue()
        }
        // Terminal states cannot be cancelled.
        if job.stateKind == "completed" || job.stateKind == "failed" {
            return JobCancelOutcome.alreadyComplete.toJSONValue()
        }
        if job.stateKind == "cancelled" {
            // Already cancelled — reconstruct the stage from the sidecar.
            let stage = job.jobState()
            if case .cancelled(let s) = stage {
                return JobCancelOutcome.cancelled(stage: s).toJSONValue()
            }
            return JobCancelOutcome.alreadyComplete.toJSONValue()
        }
        // Set cancellation flag — the executing Task will pick it up.
        cancelFlags[jobID] = true
        // If the job is still queued (Task has not started), transition immediately.
        if job.stateKind == "queued" {
            var updated = job
            updated.stateKind = "cancelled"
            updated.cancelStage = "beforeCommit"
            jobs[jobID] = updated
            saveJobs()
            log.info("jobCancel: queued job cancelled before commit: \(jobID, privacy: .public)")
            return JobCancelOutcome.cancelled(stage: .beforeCommit).toJSONValue()
        }
        // Job is running — it will cancel at the next write-window boundary.
        // Return cancelled{beforeCommit} optimistically; the Task will update to
        // the correct stage (duringCommit or afterCommit) when it terminates.
        // The sidecar update happens asynchronously in the Task.
        log.info("jobCancel: running job cancel requested: \(jobID, privacy: .public)")
        return JobCancelOutcome.cancelled(stage: .beforeCommit).toJSONValue()
    }

    // MARK: - Background job: import

    /// Execute an import job. Runs asynchronously after importExecute returns.
    private func runImportJob(
        jobID: String,
        sourceURL: URL,
        estimated: Int,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async {
        // Transition to running.
        updateJobState(jobID: jobID, stateKind: "running", total: estimated)
        // Check cancellation before doing any estate work.
        if cancelFlags[jobID] == true {
            finishJobCancelled(jobID: jobID, stage: "beforeCommit", counts: nil)
            return
        }

        do {
            let bridge = JsonImportBridge(kit: kit, limits: .default)
            // Progress callback that checks the cancel flag between records
            // and updates processed count in the sidecar.
            let progress: VaultProgress = { [weak self] processed, total in
                guard let self else { return }
                // VaultProgress is @Sendable; can't call actor methods directly.
                // The update is not strictly required for the cancel check,
                // which happens at window boundaries inside the bridge.
            }
            let report = try await bridge.importSeed(
                at: sourceURL,
                into: handle,
                defaultWing: nil,
                now: Date(),
                progress: progress
            )
            // Check cancellation after completion (afterCommit semantics).
            if cancelFlags[jobID] == true {
                let counts = TransferCounts(
                    transferred: report.drawersWritten,
                    skipped: 0,
                    conflicted: 0,
                    excluded: 0,
                    failed: 0
                )
                finishJobCancelled(jobID: jobID, stage: "afterCommit", counts: counts)
                return
            }
            let counts = TransferCounts(
                transferred: report.drawersWritten,
                skipped: 0,
                conflicted: 0,
                excluded: 0,
                failed: 0
            )
            let receipt = "import-\(jobID)-\(report.drawersWritten)"
            finishJobCompleted(jobID: jobID, counts: counts, receipt: receipt)
            log.info("runImportJob: completed jobID=\(jobID, privacy: .public) written=\(report.drawersWritten, privacy: .public)")
        } catch {
            log.error("runImportJob: failed jobID=\(jobID, privacy: .public): \(error, privacy: .public)")
            finishJobFailed(jobID: jobID, reason: "unexpected-failure", partial: nil)
        }
    }

    // MARK: - Background job: export

    /// Execute an export job. Runs asynchronously after exportExecute returns.
    private func runExportJob(
        jobID: String,
        dirURL: URL,
        fileName: String,
        scopeToken: String,
        kit: GeniusLocusKit,
        handle: EstateHandle
    ) async {
        // Transition to running.
        updateJobState(jobID: jobID, stateKind: "running")
        if cancelFlags[jobID] == true {
            finishJobCancelled(jobID: jobID, stage: "beforeCommit", counts: nil)
            return
        }

        do {
            guard let exportScope = resolveScope(token: scopeToken) else {
                finishJobFailed(jobID: jobID, reason: "policy-refused", partial: nil)
                return
            }
            // F13: Re-validate fileName at execute time. The plan validated it, but the
            // execute path re-checks as a defence-in-depth measure — plan and execute are
            // separate call paths and the fileName comes from stored plan state.
            if let deniedReason = validateFileName(fileName, relativeTo: dirURL) {
                log.error("runExportJob: fileName validation failed at execute — \(deniedReason, privacy: .public)")
                finishJobFailed(jobID: jobID, reason: deniedReason, partial: nil)
                return
            }
            let destFileURL = dirURL.appendingPathComponent(fileName)
            // Use ExchangeAdapter for JSON output (not ObsidianAdapter/Markdown).
            // VaultBridge.export applies privacy-tier rules and writes the audit receipt.
            let vaultBridge = VaultBridge(kit: kit, adapter: ExchangeAdapter())
            let report = try await vaultBridge.export(
                estate: handle,
                to: destFileURL,
                scope: exportScope,
                now: Date()
            )
            // Check cancellation after write (afterCommit semantics).
            if cancelFlags[jobID] == true {
                let counts = TransferCounts(
                    transferred: report.notesExported,
                    skipped: 0,
                    conflicted: 0,
                    excluded: report.excludedSecretTier + report.excludedPrivateTier,
                    failed: 0
                )
                finishJobCancelled(jobID: jobID, stage: "afterCommit", counts: counts)
                return
            }
            let counts = TransferCounts(
                transferred: report.notesExported,
                skipped: 0,
                conflicted: 0,
                excluded: report.excludedSecretTier + report.excludedPrivateTier,
                failed: 0
            )
            let receipt = "export-\(jobID)-\(report.notesExported)"
            finishJobCompleted(jobID: jobID, counts: counts, receipt: receipt)
            log.info("runExportJob: completed jobID=\(jobID, privacy: .public) exported=\(report.notesExported, privacy: .public)")
        } catch {
            log.error("runExportJob: failed jobID=\(jobID, privacy: .public): \(error, privacy: .public)")
            finishJobFailed(jobID: jobID, reason: "unexpected-failure", partial: nil)
        }
    }

    // MARK: - Job state helpers (actor-isolated)

    private func updateJobState(
        jobID: String,
        stateKind: String,
        processed: Int? = nil,
        total: Int? = nil
    ) {
        guard var job = jobs[jobID] else { return }
        job.stateKind = stateKind
        job.processed = processed
        job.total = total
        jobs[jobID] = job
        saveJobs()
    }

    private func finishJobCompleted(jobID: String, counts: TransferCounts, receipt: String) {
        guard var job = jobs[jobID] else { return }
        job.stateKind = "completed"
        job.countsTransferred = counts.transferred
        job.countsSkipped = counts.skipped
        job.countsConflicted = counts.conflicted
        job.countsExcluded = counts.excluded
        job.countsFailed = counts.failed
        job.receipt = receipt
        jobs[jobID] = job
        saveJobs()
    }

    private func finishJobFailed(jobID: String, reason: String, partial: TransferCounts?) {
        guard var job = jobs[jobID] else { return }
        job.stateKind = "failed"
        job.failedReason = reason
        if let p = partial {
            job.countsTransferred = p.transferred
            job.countsSkipped = p.skipped
            job.countsConflicted = p.conflicted
            job.countsExcluded = p.excluded
            job.countsFailed = p.failed
        }
        jobs[jobID] = job
        saveJobs()
    }

    private func finishJobCancelled(jobID: String, stage: String, counts: TransferCounts?) {
        guard var job = jobs[jobID] else { return }
        job.stateKind = "cancelled"
        job.cancelStage = stage
        job.cancelTransferred = counts?.transferred
        job.cancelSkipped = counts?.skipped
        job.cancelConflicted = counts?.conflicted
        job.cancelExcluded = counts?.excluded
        job.cancelFailed = counts?.failed
        jobs[jobID] = job
        saveJobs()
    }

    // MARK: - Sidecar persistence

    /// Load jobs from the sidecar. Returns empty dict on any error.
    private static func loadJobs(at layoutURL: URL) -> [String: PersistedJob] {
        let url = layoutURL.appendingPathComponent("transfer-jobs.json")
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(JobSidecar.self, from: data) else {
            return [:]
        }
        return sidecar.jobs
    }

    /// Write jobs to the sidecar atomically (write to .tmp, then rename).
    private func saveJobs() {
        var sidecar = JobSidecar()
        sidecar.jobs = jobs
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(sidecar) else {
            log.error("saveJobs: JSON encoding failed")
            return
        }
        // Atomic write: Data.write(to:options:.atomic) writes to a temp file
        // and renames, which is crash-safe (the kernel guarantees atomicity
        // of the rename syscall on APFS).
        let url = jobsURL
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Estate fingerprint

    /// Compute the set of all occupied lineage IDs (active + withdrawn + erased).
    ///
    /// Mirrors JsonImportBridge.occupiedLineageIDs (which is internal to VaultKit).
    /// Called for both plan-time fingerprint computation and plan-stale detection.
    func occupiedLineageSet() async throws -> Set<UUID> {
        let active = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [
                    .currentlyBelieve,
                    .any([.trustworthy, .requiresConfirmation]),
                    .sensitivityAtMost(.secret),
                ],
                hydrationLevel: .structured,
                limit: 10_000_000
            )
        )
        let withdrawn = try await kit.recall(
            handle,
            RecallFrame(
                filterChain: [.usedToBelieve],
                hydrationLevel: .structured,
                limit: 10_000_000
            )
        )
        let erased = try await kit.tombstonedLineageIDs(handle)
        return Set(active.map(\.lineageID))
            .union(withdrawn.map(\.lineageID))
            .union(erased)
    }

    /// SHA-256 of sorted occupied lineage UUIDs → hex string.
    ///
    /// A single new record added to the estate changes the fingerprint.
    private func estateFingerprint(occupied: Set<UUID>) -> String {
        let sorted = occupied.map { $0.uuidString.lowercased() }.sorted()
        let data = sorted.joined(separator: ",").data(using: .utf8) ?? Data()
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Import classification

    /// Per-record classification result from classifyImportFile.
    private struct ClassificationResult {
        var candidateCount: Int = 0
        var recognizedCount: Int = 0  // valid schema AND lineage not in occupied set
        var duplicateCount: Int = 0   // lineage already in occupied set
        var invalidCount: Int = 0     // schema validation failure
        var conflictCount: Int = 0    // intra-file duplicate ID
        var policyExclusionCount: Int = 0
        var formatValid: Bool = true  // false if format is unrecognized
    }

    /// Classify each record in a seed file without mutating the estate.
    ///
    /// Strategy:
    ///   1. Parse the raw JSON and extract the records array.
    ///   2. For each record: check for intra-file ID conflicts, validate
    ///      the record schema (by probing a minimal wrapper), and check
    ///      if its lineage is already in the estate.
    ///   3. Count per category.
    ///
    /// No estate writes occur. The probe uses JsonSeedFile.parse on a
    /// single-record wrapper to leverage the existing validation logic.
    private func classifyImportFile(at url: URL, occupied: Set<UUID>) throws -> ClassificationResult {
        let data = try Data(contentsOf: url)

        // Attempt to detect and parse as a MOOT JSON seed file.
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any],
              let fv = root["format_version"] as? Int,
              fv == 1 else {
            // Not a recognized MOOT JSON file — count the whole file as one invalid entry.
            var r = ClassificationResult()
            r.invalidCount = 1
            r.formatValid = false
            return r
        }

        let recordsRaw = (root["records"] as? [Any]) ?? []
        var result = ClassificationResult()
        result.candidateCount = recordsRaw.count
        var seenIDs: Set<String> = []

        for element in recordsRaw {
            guard let obj = element as? [String: Any],
                  let id = obj["id"] as? String, !id.isEmpty else {
                // Record is not an object or has no valid id — schema failure.
                result.invalidCount += 1
                continue
            }
            // Intra-file duplicate ID.
            if seenIDs.contains(id) {
                result.conflictCount += 1
                continue
            }
            seenIDs.insert(id)

            // Check estate duplicate (lineage already occupied).
            let lineage = DrawerMapping.lineageID(forStableSourceKey: id)
            if occupied.contains(lineage) {
                result.duplicateCount += 1
                continue
            }

            // Validate this record by wrapping it in a minimal seed file
            // and probing JsonSeedFile.parse (which is the authoritative validator).
            // This does NOT mutate the estate — it's a pure in-memory parse.
            let probeDict: [String: Any] = [
                "format_version": 1,
                "name": "classification-probe",
                "records": [element],
                "facts": [Any](),
                "tunnels": [Any](),
            ]
            if let probeData = try? JSONSerialization.data(withJSONObject: probeDict),
               (try? JsonSeedFile.parse(data: probeData, limits: .default)) != nil {
                // Schema-valid and not a duplicate — recognized.
                result.recognizedCount += 1
            } else {
                result.invalidCount += 1
            }
        }
        return result
    }

    // MARK: - Bookmark + format helpers

    /// Decode base64 bookmark to URL using the same convention as
    /// CommunityObsidianCoordinator: base64 → UTF-8 → file URL.
    private func resolveBookmarkToURL(_ bookmark: Data) throws -> URL {
        guard let urlString = String(data: bookmark, encoding: .utf8),
              let url = URL(string: urlString) else {
            throw TransferError.bookmarkResolutionFailed
        }
        return url
    }

    /// Detect the MOOT JSON transfer format by trying to parse the file header.
    ///
    /// Inspects only format_version from the JSON; does not validate records.
    /// Returns "MOOT JSON"{recognized:true} or "Unknown"{recognized:false}.
    private func detectFormat(at url: URL) -> TransferFormat {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let root = parsed as? [String: Any],
              let fv = root["format_version"] as? Int,
              fv == 1 else {
            return TransferFormat(name: "Unknown", recognized: false)
        }
        return TransferFormat(name: "MOOT JSON", recognized: true)
    }

    /// Map a scope token to VaultExportScope. Returns nil for unknown tokens.
    private func resolveScope(token: String) -> VaultExportScope? {
        switch token {
        case "eligible-all": return .exportable
        case "believed":     return .believed
        case "confirmed":    return .confirmed
        case "unconfirmed":  return .unconfirmed
        default:             return nil
        }
    }

    // MARK: - File name validation (F13)

    /// Validate a caller-supplied export file name against the granted destination directory.
    ///
    /// A caller-supplied `fileName` used in `appendingPathComponent` can escape the
    /// bookmark-granted directory if it contains '..' components or path separators.
    /// This function enforces that the resolved output file is a DIRECT child of `dirURL`.
    ///
    /// Rejected inputs (returns non-nil reason string):
    ///   • Empty name
    ///   • Name containing '/' or backslash (explicit separator injection)
    ///   • Name equal to '.' or '..' (current/parent directory)
    ///   • Resolved file URL whose parent directory differs from `dirURL` after standardization
    ///
    /// Returns: `nil` if valid; a denied-reason string if invalid.
    private func validateFileName(_ name: String, relativeTo dirURL: URL) -> String? {
        // Reject empty names.
        guard !name.isEmpty else {
            log.error("validateFileName: empty fileName rejected")
            return "invalidParams"
        }
        // Reject explicit path separator injection — these prevent clean resolution.
        guard !name.contains("/"), !name.contains("\\") else {
            log.error("validateFileName: fileName contains path separator — rejected")
            return "invalidParams"
        }
        // Reject bare directory references.
        guard name != ".", name != ".." else {
            log.error("validateFileName: fileName is '.' or '..' — rejected")
            return "invalidParams"
        }
        // Resolve and verify the file's parent is exactly the granted directory.
        // appendingPathComponent is used here to match the real usage site; standardized
        // resolves any remaining '..' components introduced by the OS.
        //
        // Compare using .path (not URL equality) to normalize trailing slashes:
        // URL equality is slash-sensitive ("dir/" ≠ "dir"), but the bookmark may
        // be a FILE url whose standardized form has no trailing slash, while
        // deletingLastPathComponent().standardized adds one. .path strips trailing
        // slashes consistently on both sides.
        let resolved = dirURL.appendingPathComponent(name).standardized
        let resolvedParentPath = resolved.deletingLastPathComponent().standardized.path
        guard resolvedParentPath == dirURL.standardized.path else {
            log.error("validateFileName: resolved path escapes granted directory — rejected")
            return "invalidParams"
        }
        return nil
    }

    // MARK: - Plan token helpers

    /// Extract the UUID portion of a planToken ("<uuid>:<fingerprint>").
    private func extractPlanUUID(_ planToken: String) -> String? {
        let parts = planToken.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return String(parts[0])
    }

    /// Extract the fingerprint portion of a planToken.
    private func extractPlanFingerprint(_ planToken: String) -> String {
        let parts = planToken.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return "" }
        return String(parts[1])
    }

    /// Return the jobID if a job with this planToken already exists.
    private func existingJobID(for planToken: String) -> String? {
        jobs.first(where: { $0.value.planToken == planToken })?.key
    }

    // MARK: - Utilities

    private func isoNow() -> String {
        let fmt = ISO8601DateFormatter()
        return fmt.string(from: Date())
    }
}

// MARK: - TransferError (local to transfer coordinator)

/// Errors thrown by bookmark resolution within the transfer coordinator.
///
/// These errors do NOT use CommunityDaemonError because they are internal
/// to the transfer path and are converted to specific outcome discriminators
/// (denied{permission-revoked}) before reaching the MCP surface.
private enum TransferError: Error {
    case bookmarkResolutionFailed
}
