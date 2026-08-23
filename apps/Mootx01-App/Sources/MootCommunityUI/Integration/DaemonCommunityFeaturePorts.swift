import Foundation
import MootCommunityGateway
#if os(macOS)
import AppKit
#endif

/// Shared authenticated caller attachment for the Community feature ports.
///
/// The caller exists only while the resident daemon has passed readiness and
/// authentication. Disconnecting clears it atomically, so no feature can keep
/// using a caller from an earlier daemon instance.
public actor CommunityFeatureCallerBox {
    private var caller: (any MootEstateCalling)?

    public init() {}

    public func attach(_ caller: (any MootEstateCalling)?) {
        self.caller = caller
    }

    func call(_ method: String, arguments: [String: JSONValue] = [:]) async -> JSONValue? {
        guard let caller else { return nil }
        let result = await caller.callToolFull(method, arguments: arguments)
        guard !result.isError else { return nil }
        return result.structured
    }
}

// MARK: - Estate lifecycle

public actor DaemonCommunityEstateLifecycleService: CommunityEstateLifecycleServicing {
    private let callerBox: CommunityFeatureCallerBox

    public init(callerBox: CommunityFeatureCallerBox) {
        self.callerBox = callerBox
    }

    public func inspect() async -> CommunityEstateLifecycleState {
        await state("moot_community_estate_inspect")
    }

    public func createEstate(named name: String) async -> CommunityEstateLifecycleState {
        await state("moot_community_estate_create", arguments: ["name": .string(name)])
    }

    public func openEstate(id: UUID) async -> CommunityEstateLifecycleState {
        await state("moot_community_estate_open", arguments: ["estateID": .string(id.uuidString)])
    }

    public func beginMigration(planID: UUID) async -> CommunityEstateLifecycleState {
        await state("moot_community_estate_migrate", arguments: ["planID": .string(planID.uuidString)])
    }

    public func recover(choiceID: String) async -> CommunityEstateLifecycleState {
        await state("moot_community_estate_recover", arguments: ["choiceID": .string(choiceID)])
    }

    public func cancel(operationID: UUID) async -> CommunityEstateLifecycleState {
        await state("moot_community_estate_cancel", arguments: [
            "operationID": .string(operationID.uuidString),
        ])
    }

    private func state(
        _ method: String,
        arguments: [String: JSONValue] = [:]
    ) async -> CommunityEstateLifecycleState {
        guard let object = await callerBox.call(method, arguments: arguments)?.objectValue else {
            return .blocked(reason: "daemon-unavailable-or-malformed")
        }
        return Self.decode(object) ?? .blocked(reason: "malformed-daemon-response")
    }

    private static func decode(_ object: [String: JSONValue]) -> CommunityEstateLifecycleState? {
        switch object["state"]?.stringValue {
        case "checking": return .checking
        case "needsCreation": return .needsCreation
        case "chooseExisting":
            guard let values = object["estates"]?.arrayValue,
                  let estates = all(values, transform: estate) else { return nil }
            return .chooseExisting(estates)
        case "missingKey":
            guard let estateValue = object["estate"],
                  let estate = estate(estateValue),
                  let choiceValues = object["choices"]?.arrayValue,
                  let choices = all(choiceValues, transform: recoveryChoice) else { return nil }
            return .missingKey(estate: estate, choices: choices)
        case "corrupt":
            guard let estateValue = object["estate"],
                  let estate = estate(estateValue),
                  let diagnosis = object["diagnosis"]?.stringValue,
                  let choiceValues = object["choices"]?.arrayValue,
                  let choices = all(choiceValues, transform: recoveryChoice) else { return nil }
            return .corrupt(estate: estate, diagnosis: diagnosis, choices: choices)
        case "incompatible":
            guard let estateValue = object["estate"],
                  let estate = estate(estateValue),
                  let reason = object["reason"]?.stringValue else { return nil }
            return .incompatible(estate: estate, reason: reason)
        case "migrationRequired":
            guard let value = object["plan"], let plan = migrationPlan(value) else { return nil }
            return .migrationRequired(plan)
        case "migrating":
            guard let value = object["progress"], let progress = migrationProgress(value) else { return nil }
            return .migrating(progress)
        case "ready":
            guard let value = object["receipt"], let receipt = estateReceipt(value) else { return nil }
            return .ready(receipt)
        case "cancelled":
            guard let resumable = object["resumable"]?.boolValue else { return nil }
            return .cancelled(resumable: resumable)
        case "blocked":
            guard let reason = object["reason"]?.stringValue else { return nil }
            return .blocked(reason: reason)
        default: return nil
        }
    }

    private static func estate(_ value: JSONValue) -> CommunityEstateSummary? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              let name = object["name"]?.stringValue,
              let schemaVersion = object["schemaVersion"]?.stringValue else { return nil }
        return CommunityEstateSummary(id: id, name: name, schemaVersion: schemaVersion)
    }

    private static func estateReceipt(_ value: JSONValue) -> CommunityEstateReceipt? {
        guard let object = value.objectValue,
              let estateValue = object["estate"],
              let estate = estate(estateValue),
              let receiptID = uuid(object["receiptID"]) else { return nil }
        return CommunityEstateReceipt(estate: estate, receiptID: receiptID)
    }

    private static func migrationPlan(_ value: JSONValue) -> CommunityMigrationPlan? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              let estateValue = object["estate"],
              let estate = estate(estateValue),
              let sourceVersion = object["sourceVersion"]?.stringValue,
              let targetVersion = object["targetVersion"]?.stringValue,
              let expectedEffect = object["expectedEffect"]?.stringValue else { return nil }
        return CommunityMigrationPlan(
            id: id,
            estate: estate,
            sourceVersion: sourceVersion,
            targetVersion: targetVersion,
            expectedEffect: expectedEffect
        )
    }

    private static func migrationProgress(_ value: JSONValue) -> CommunityMigrationProgress? {
        guard let object = value.objectValue,
              let operationID = uuid(object["operationID"]),
              let planValue = object["plan"],
              let plan = migrationPlan(planValue),
              let completedUnits = int(object["completedUnits"]),
              let totalUnits = int(object["totalUnits"]) else { return nil }
        return CommunityMigrationProgress(
            operationID: operationID,
            plan: plan,
            completedUnits: completedUnits,
            totalUnits: totalUnits
        )
    }

    private static func recoveryChoice(_ value: JSONValue) -> CommunityRecoveryChoice? {
        guard let object = value.objectValue,
              let id = object["id"]?.stringValue,
              let title = object["title"]?.stringValue,
              let consequence = object["consequence"]?.stringValue,
              let destructive = object["isDestructive"]?.boolValue else { return nil }
        return CommunityRecoveryChoice(
            id: id,
            title: title,
            consequence: consequence,
            isDestructive: destructive
        )
    }
}

// MARK: - Import and export

public actor DaemonTransferPort: TransferPort {
    private struct ScopeChoice: Sendable {
        let token: String
        let candidateCount: Int
        let description: String
    }

    private let callerBox: CommunityFeatureCallerBox
    private var importSelection: (url: URL, bookmark: Data)?
    private var exportSelection: (url: URL, bookmark: Data)?

    public init(callerBox: CommunityFeatureCallerBox) {
        self.callerBox = callerBox
    }

    public func selectImportSource() async -> ImportSourceOutcome {
        #if os(macOS)
        let selected: URL? = await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        }
        guard let selected else { return .cancelled }
        guard let bookmark = securityScopedBookmark(selected) else {
            return .denied(reason: "source-authorization-unavailable")
        }
        guard let object = await callerBox.call("moot_community_transfer_import_source", arguments: [
            "bookmark": .string(bookmark.base64EncodedString()),
            "displayName": .string(selected.lastPathComponent),
        ])?.objectValue else { return .denied(reason: "daemon-unavailable-or-malformed") }
        guard object["outcome"]?.stringValue == "selected",
              let formatValue = object["format"],
              let format = Self.format(formatValue) else {
            return .denied(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
        importSelection = (selected, bookmark)
        return .selected(sourceURL: selected, format: format)
        #else
        return .denied(reason: "source-selection-unavailable")
        #endif
    }

    public func planImport(sourceURL: URL) async -> ImportPlanOutcome {
        guard let selection = importSelection, selection.url == sourceURL else {
            return .failed(reason: "source-authorization-unavailable")
        }
        guard let object = await callerBox.call("moot_community_transfer_import_plan", arguments: [
            "bookmark": .string(selection.bookmark.base64EncodedString()),
        ])?.objectValue else { return .failed(reason: "daemon-unavailable-or-malformed") }
        if object["outcome"]?.stringValue == "planned",
           let value = object["plan"], let plan = Self.plan(value) {
            return .planned(plan)
        }
        return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
    }

    public func executeImport(planToken: String) async -> ImportExecutionOutcome {
        guard let object = await callerBox.call("moot_community_transfer_import_execute", arguments: [
            "planToken": .string(planToken),
        ])?.objectValue else { return .failed(reason: "daemon-unavailable-or-malformed") }
        switch object["outcome"]?.stringValue {
        case "submitted":
            guard let id = object["jobID"]?.stringValue, !id.isEmpty else {
                return .failed(reason: "malformed-daemon-response")
            }
            return .submitted(jobID: TransferJobID(id: id))
        case "denied": return .denied(reason: object["reason"]?.stringValue ?? "daemon-refused")
        default: return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }

    public func selectExportDestination() async -> ExportDestinationOutcome {
        #if os(macOS)
        let selected: URL? = await MainActor.run {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "MOOTx01 Export"
            panel.canCreateDirectories = true
            return panel.runModal() == .OK ? panel.url : nil
        }
        guard let selected else { return .cancelled }
        let authorityURL = selected.deletingLastPathComponent()
        guard let bookmark = securityScopedBookmark(authorityURL) else {
            return .denied(reason: "destination-authorization-unavailable")
        }
        guard let object = await callerBox.call("moot_community_transfer_export_destination", arguments: [
            "bookmark": .string(bookmark.base64EncodedString()),
            "fileName": .string(selected.lastPathComponent),
        ])?.objectValue else { return .denied(reason: "daemon-unavailable-or-malformed") }
        guard object["outcome"]?.stringValue == "selected" else {
            return .denied(reason: object["reason"]?.stringValue ?? "daemon-refused")
        }
        exportSelection = (selected, bookmark)
        return .selected(destinationURL: selected)
        #else
        return .denied(reason: "destination-selection-unavailable")
        #endif
    }

    public func selectExportScope() async -> ExportScopeOutcome {
        guard let object = await callerBox.call("moot_community_transfer_export_scopes")?.objectValue,
              let values = object["scopes"]?.arrayValue,
              let choices = all(values, transform: Self.scope),
              !choices.isEmpty else { return .cancelled }
        #if os(macOS)
        let selectedIndex: Int? = await MainActor.run {
            let alert = NSAlert()
            alert.messageText = String(localized: "Choose export scope")
            alert.informativeText = String(localized: "Only daemon-approved, policy-eligible records can be exported.")
            alert.addButton(withTitle: String(localized: "Choose"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
            picker.addItems(withTitles: choices.map(\.description))
            alert.accessoryView = picker
            return alert.runModal() == .alertFirstButtonReturn ? picker.indexOfSelectedItem : nil
        }
        guard let selectedIndex, choices.indices.contains(selectedIndex) else { return .cancelled }
        let choice = choices[selectedIndex]
        return .selected(
            scopeToken: choice.token,
            candidateCount: choice.candidateCount,
            description: choice.description
        )
        #else
        return .cancelled
        #endif
    }

    public func planExport(destinationURL: URL, scopeToken: String) async -> ExportPlanOutcome {
        guard let selection = exportSelection, selection.url == destinationURL else {
            return .failed(reason: "destination-authorization-unavailable")
        }
        guard let object = await callerBox.call("moot_community_transfer_export_plan", arguments: [
            "bookmark": .string(selection.bookmark.base64EncodedString()),
            "fileName": .string(selection.url.lastPathComponent),
            "scopeToken": .string(scopeToken),
        ])?.objectValue else { return .failed(reason: "daemon-unavailable-or-malformed") }
        if object["outcome"]?.stringValue == "planned",
           let value = object["plan"], let plan = Self.plan(value) {
            return .planned(plan)
        }
        return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
    }

    public func executeExport(planToken: String) async -> ExportExecutionOutcome {
        guard let object = await callerBox.call("moot_community_transfer_export_execute", arguments: [
            "planToken": .string(planToken),
        ])?.objectValue else { return .failed(reason: "daemon-unavailable-or-malformed") }
        switch object["outcome"]?.stringValue {
        case "submitted":
            guard let id = object["jobID"]?.stringValue, !id.isEmpty else {
                return .failed(reason: "malformed-daemon-response")
            }
            return .submitted(jobID: TransferJobID(id: id))
        case "denied": return .denied(reason: object["reason"]?.stringValue ?? "daemon-refused")
        default: return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }

    public func loadJobStatus(jobID: TransferJobID) async -> TransferJobStatusOutcome {
        guard let object = await callerBox.call("moot_community_transfer_job_status", arguments: [
            "jobID": .string(jobID.id),
        ])?.objectValue else { return .failed(reason: "daemon-unavailable-or-malformed") }
        switch object["outcome"]?.stringValue {
        case "status":
            guard let returnedID = object["jobID"]?.stringValue,
                  returnedID == jobID.id,
                  let stateValue = object["jobState"],
                  let state = Self.jobState(stateValue) else {
                return .failed(reason: "job-identity-or-payload-mismatch")
            }
            return .status(jobID: jobID, state: state)
        case "notFound": return .notFound
        default: return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }

    public func cancelJob(jobID: TransferJobID) async -> CancelJobOutcome {
        guard let object = await callerBox.call("moot_community_transfer_job_cancel", arguments: [
            "jobID": .string(jobID.id),
        ])?.objectValue else { return .failed(reason: "daemon-unavailable-or-malformed") }
        switch object["outcome"]?.stringValue {
        case "cancelled":
            guard let value = object["stage"], let stage = Self.cancellationStage(value) else {
                return .failed(reason: "malformed-daemon-response")
            }
            return .cancelled(stage: stage)
        case "notFound": return .notFound
        case "alreadyComplete": return .alreadyComplete
        default: return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }

    private static func format(_ value: JSONValue) -> TransferFormatDescriptor? {
        guard let object = value.objectValue,
              let name = object["name"]?.stringValue,
              let recognized = object["recognized"]?.boolValue else { return nil }
        return TransferFormatDescriptor(name: name, recognized: recognized)
    }

    private static func plan(_ value: JSONValue) -> TransferPlan? {
        guard let object = value.objectValue,
              let formatValue = object["format"],
              let format = format(formatValue),
              let candidateCount = int(object["candidateCount"]),
              let conflictCount = int(object["conflictCount"]),
              let invalidCount = int(object["invalidCount"]),
              let exclusionCount = int(object["policyExclusionCount"]),
              let estimatedCount = int(object["estimatedTransferCount"]),
              let permitted = object["executionPermitted"]?.boolValue,
              let token = object["planToken"]?.stringValue,
              !token.isEmpty else { return nil }
        return TransferPlan(
            format: format,
            candidateCount: candidateCount,
            conflictCount: conflictCount,
            invalidCount: invalidCount,
            policyExclusionCount: exclusionCount,
            estimatedTransferCount: estimatedCount,
            executionPermitted: permitted,
            planToken: token
        )
    }

    private static func scope(_ value: JSONValue) -> ScopeChoice? {
        guard let object = value.objectValue,
              let token = object["scopeToken"]?.stringValue,
              !token.isEmpty,
              let count = int(object["candidateCount"]),
              let description = object["description"]?.stringValue else { return nil }
        return ScopeChoice(token: token, candidateCount: count, description: description)
    }

    private static func counts(_ value: JSONValue) -> TransferCounts? {
        guard let object = value.objectValue,
              let transferred = int(object["transferred"]),
              let skipped = int(object["skipped"]),
              let conflicted = int(object["conflicted"]),
              let excluded = int(object["excluded"]),
              let failed = int(object["failed"]) else { return nil }
        return TransferCounts(
            transferred: transferred,
            skipped: skipped,
            conflicted: conflicted,
            excluded: excluded,
            failed: failed
        )
    }

    private static func jobState(_ value: JSONValue) -> TransferJobState? {
        guard let object = value.objectValue else { return nil }
        switch object["state"]?.stringValue {
        case "queued": return .queued
        case "running":
            if let processed = int(object["processed"]), let total = int(object["total"]) {
                return .running(progress: TransferProgress(processed: processed, total: total))
            }
            return .running(progress: nil)
        case "waiting":
            guard let reason = object["reason"]?.stringValue else { return nil }
            return .waiting(reason: reason)
        case "completed":
            guard let value = object["counts"], let counts = counts(value),
                  let receipt = object["receipt"]?.stringValue, !receipt.isEmpty else { return nil }
            return .completed(counts: counts, receipt: receipt)
        case "failed":
            guard let reason = object["reason"]?.stringValue else { return nil }
            let partial = object["partial"].flatMap(counts)
            return .failed(reason: reason, partial: partial)
        case "cancelled":
            guard let value = object["stage"], let stage = cancellationStage(value) else { return nil }
            return .cancelled(stage: stage)
        default: return nil
        }
    }

    private static func cancellationStage(_ value: JSONValue) -> CancellationStage? {
        guard let object = value.objectValue else { return nil }
        switch object["stage"]?.stringValue {
        case "beforeCommit": return .beforeCommit
        case "duringCommit":
            guard let value = object["counts"], let counts = counts(value) else { return nil }
            return .duringCommit(partial: counts)
        case "afterCommit":
            guard let value = object["counts"], let counts = counts(value) else { return nil }
            return .afterCommit(counts: counts)
        default: return nil
        }
    }
}

// MARK: - Review Center

public actor DaemonReviewCenterPort: ReviewCenterPort {
    private let callerBox: CommunityFeatureCallerBox

    public init(callerBox: CommunityFeatureCallerBox) {
        self.callerBox = callerBox
    }

    public func loadDashboard() async -> ReviewDashboardState {
        guard let object = await callerBox.call("moot_community_review_dashboard")?.objectValue,
              let modes = object["modes"]?.arrayValue else {
            return ReviewDashboardState(modeStates: blockedModes("daemon-unavailable-or-malformed"))
        }
        var states: [ReviewSessionKind: ReviewModeStatus] = [:]
        for value in modes {
            guard let mode = value.objectValue,
                  let kindRaw = mode["kind"]?.stringValue,
                  let kind = ReviewSessionKind(rawValue: kindRaw),
                  let status = Self.modeStatus(mode) else {
                return ReviewDashboardState(modeStates: blockedModes("malformed-daemon-response"))
            }
            states[kind] = status
        }
        guard Set(states.keys) == Set(ReviewSessionKind.allCases) else {
            return ReviewDashboardState(modeStates: blockedModes("incomplete-daemon-response"))
        }
        return ReviewDashboardState(modeStates: states)
    }

    public func loadSession(kind: ReviewSessionKind) async -> ReviewSessionResult {
        guard let object = await callerBox.call(
            "moot_community_review_session", arguments: ["kind": .string(kind.rawValue)]
        )?.objectValue else { return .blocked(reason: "daemon-unavailable-or-malformed") }
        if object["outcome"]?.stringValue == "blocked" {
            return .blocked(reason: object["reason"]?.stringValue ?? "daemon-refused")
        }
        guard object["outcome"]?.stringValue == "session",
              let sessionValue = object["session"],
              let session = Self.session(sessionValue) else {
            return .blocked(reason: "malformed-daemon-response")
        }
        guard session.kind == kind else {
            return .blocked(reason: "session-kind-mismatch")
        }
        return .session(session)
    }

    public func applyAction(_ actionID: UUID, in sessionID: UUID) async -> ReviewActionOutcome {
        await actionOutcome("moot_community_review_apply", actionID: actionID, sessionID: sessionID)
    }

    public func reverseAction(_ actionID: UUID, in sessionID: UUID) async -> ReviewActionOutcome {
        await actionOutcome("moot_community_review_reverse", actionID: actionID, sessionID: sessionID)
    }

    public func resolveGroup(
        _ groupID: UUID,
        choiceID: UUID,
        in sessionID: UUID
    ) async -> ReviewActionOutcome {
        guard let object = await callerBox.call("moot_community_review_resolve_duplicate", arguments: [
            "sessionID": .string(sessionID.uuidString),
            "groupID": .string(groupID.uuidString),
            "choiceID": .string(choiceID.uuidString),
        ])?.objectValue else { return .failed("daemon-unavailable-or-malformed") }
        return Self.actionOutcome(object)
    }

    public func completeSession(_ sessionID: UUID) async -> ReviewCompletionResult {
        guard let object = await callerBox.call("moot_community_review_complete", arguments: [
            "sessionID": .string(sessionID.uuidString),
        ])?.objectValue else { return .failed("daemon-unavailable-or-malformed") }
        if object["outcome"]?.stringValue == "completed",
           let receiptValue = object["receipt"],
           let receipt = Self.receipt(receiptValue),
           receipt.sessionID == sessionID {
            return .completed(receipt: receipt)
        }
        if object["outcome"]?.stringValue == "completed" {
            return .failed("session-identity-mismatch")
        }
        return .failed(object["reason"]?.stringValue ?? "malformed-daemon-response")
    }

    private func actionOutcome(
        _ method: String,
        actionID: UUID,
        sessionID: UUID
    ) async -> ReviewActionOutcome {
        guard let object = await callerBox.call(method, arguments: [
            "sessionID": .string(sessionID.uuidString),
            "actionID": .string(actionID.uuidString),
        ])?.objectValue else { return .failed("daemon-unavailable-or-malformed") }
        return Self.actionOutcome(object)
    }

    private func blockedModes(_ reason: String) -> [ReviewSessionKind: ReviewModeStatus] {
        Dictionary(uniqueKeysWithValues: ReviewSessionKind.allCases.map { ($0, .blocked(reason: reason)) })
    }

    private static func modeStatus(_ object: [String: JSONValue]) -> ReviewModeStatus? {
        switch object["status"]?.stringValue {
        case "available": return .available
        case "due": return .due
        case "inProgress":
            guard let id = uuid(object["sessionID"]) else { return nil }
            return .inProgress(sessionID: id)
        case "completed":
            guard let value = object["receipt"], let receipt = receipt(value) else { return nil }
            return .completed(receipt: receipt)
        case "blocked":
            guard let reason = object["reason"]?.stringValue else { return nil }
            return .blocked(reason: reason)
        default: return nil
        }
    }

    private static func session(_ value: JSONValue) -> ReviewSession? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              let kindRaw = object["kind"]?.stringValue,
              let kind = ReviewSessionKind(rawValue: kindRaw),
              let generatedAt = date(object["generatedAt"]),
              let sourceEstateState = object["sourceEstateState"]?.stringValue,
              let sectionValues = object["sections"]?.arrayValue,
              let actionValues = object["actions"]?.arrayValue,
              let duplicateValues = object["duplicateGroups"]?.arrayValue,
              let sections = all(sectionValues, transform: section),
              let actions = all(actionValues, transform: action),
              let groups = all(duplicateValues, transform: duplicateGroup),
              let completion = completionStatus(object["completionStatus"]) else { return nil }
        return ReviewSession(
            id: id,
            kind: kind,
            generatedAt: generatedAt,
            sourceEstateState: sourceEstateState,
            orderedSections: sections,
            proposedActions: actions,
            duplicateGroups: groups,
            completionStatus: completion
        )
    }

    private static func section(_ value: JSONValue) -> ReviewSessionSection? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              let title = object["title"]?.stringValue,
              let values = object["items"]?.arrayValue,
              let items = all(values, transform: item) else { return nil }
        return ReviewSessionSection(id: id, title: title, items: items)
    }

    private static func item(_ value: JSONValue) -> ReviewSessionItem? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              let subject = object["subject"]?.stringValue,
              let detail = object["detail"]?.stringValue else { return nil }
        return ReviewSessionItem(id: id, subject: subject, detail: detail)
    }

    private static func action(_ value: JSONValue) -> ReviewAction? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              let expectedEffect = object["expectedEffect"]?.stringValue,
              let reversible = object["isReversible"]?.boolValue,
              let reversalAvailable = object["reversalAvailable"]?.boolValue else { return nil }
        return ReviewAction(
            id: id,
            expectedEffect: expectedEffect,
            isReversible: reversible,
            reversalAvailable: reversalAvailable
        )
    }

    private static func duplicateGroup(_ value: JSONValue) -> DuplicateGroup? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              let reason = object["reason"]?.stringValue,
              let recordValues = object["recordIDs"]?.arrayValue,
              let choiceValues = object["choices"]?.arrayValue,
              let recordIDs = all(recordValues, transform: uuid),
              let choices = all(choiceValues, transform: choice) else { return nil }
        return DuplicateGroup(
            id: id,
            reason: reason,
            involvedRecordIDs: recordIDs,
            resolutionChoices: choices
        )
    }

    private static func choice(_ value: JSONValue) -> DuplicateResolutionChoice? {
        guard let object = value.objectValue,
              let id = uuid(object["id"]),
              let description = object["description"]?.stringValue else { return nil }
        return DuplicateResolutionChoice(id: id, description: description)
    }

    private static func completionStatus(_ value: JSONValue?) -> ReviewSessionCompletionStatus? {
        guard let object = value?.objectValue else { return nil }
        switch object["state"]?.stringValue {
        case "notStarted": return .notStarted
        case "inProgress": return .inProgress
        case "completed":
            guard let receiptValue = object["receipt"], let receipt = receipt(receiptValue) else { return nil }
            return .completed(receipt: receipt)
        default: return nil
        }
    }

    private static func receipt(_ value: JSONValue) -> ReviewCompletionReceipt? {
        guard let object = value.objectValue,
              let sessionID = uuid(object["sessionID"]),
              let completedAt = date(object["completedAt"]),
              let summary = object["summary"]?.stringValue else { return nil }
        return ReviewCompletionReceipt(sessionID: sessionID, completedAt: completedAt, summary: summary)
    }

    private static func actionOutcome(_ object: [String: JSONValue]) -> ReviewActionOutcome {
        switch object["outcome"]?.stringValue {
        case "applied": return .applied
        case "alreadyApplied": return .alreadyApplied
        case "staleSession": return .staleSession
        case "conflict": return .conflict(object["reason"]?.stringValue ?? "daemon-conflict")
        case "refused": return .refused(object["reason"]?.stringValue ?? "daemon-refused")
        default: return .failed(object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }
}

// MARK: - Obsidian

public actor DaemonObsidianSyncPort: ObsidianSyncPort {
    private let callerBox: CommunityFeatureCallerBox

    public init(callerBox: CommunityFeatureCallerBox) {
        self.callerBox = callerBox
    }

    public func loadStatus() async -> ObsidianSyncStatus {
        guard let object = await callerBox.call("moot_community_obsidian_status")?.objectValue else {
            return .blocked(reason: "daemon-unavailable-or-malformed")
        }
        return Self.status(object) ?? .blocked(reason: "malformed-daemon-response")
    }

    public func loadLastCheckpoint() async -> ObsidianCheckpoint? {
        guard let object = await callerBox.call("moot_community_obsidian_status")?.objectValue else {
            return nil
        }
        return Self.checkpoint(object)
    }

    public func loadAuthorizationState() async -> ObsidianAuthorizationState {
        guard let object = await callerBox.call("moot_community_obsidian_authorization")?.objectValue,
              let state = object["state"]?.stringValue else { return .missing }
        switch state {
        case "valid":
            guard let url = url(object["vaultURL"]), let name = object["displayName"]?.stringValue else {
                return .missing
            }
            return .valid(vaultURL: url, displayName: name)
        case "needsRenewal":
            guard let url = url(object["vaultURL"]),
                  let name = object["displayName"]?.stringValue,
                  let reason = object["reason"]?.stringValue else { return .missing }
            return .needsRenewal(vaultURL: url, displayName: name, reason: reason)
        default: return .missing
        }
    }

    public func selectVault() async -> VaultSelectionOutcome {
        #if os(macOS)
        let selected: URL? = await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            return panel.runModal() == .OK ? panel.url : nil
        }
        guard let selected else { return .cancelled }
        guard let bookmark = try? selected.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return .denied(reason: "vault-authorization-unavailable") }
        guard let object = await callerBox.call("moot_community_obsidian_select_vault", arguments: [
            "bookmark": .string(bookmark.base64EncodedString()),
            "displayName": .string(selected.lastPathComponent),
        ])?.objectValue else { return .denied(reason: "daemon-unavailable-or-malformed") }
        if object["outcome"]?.stringValue == "selected",
           let acceptedURL = url(object["vaultURL"]),
           let name = object["displayName"]?.stringValue {
            return .selected(vaultURL: acceptedURL, displayName: name)
        }
        return .denied(reason: object["reason"]?.stringValue ?? "daemon-refused")
        #else
        return .denied(reason: "vault-selection-unavailable")
        #endif
    }

    public func enableSync() async -> ObsidianEnableOutcome {
        guard let object = await callerBox.call("moot_community_obsidian_enable")?.objectValue else {
            return .failed(reason: "daemon-unavailable-or-malformed")
        }
        switch object["outcome"]?.stringValue {
        case "enabled": return .enabled
        case "refused": return .refused(reason: object["reason"]?.stringValue ?? "daemon-refused")
        default: return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }

    public func disableSync() async -> ObsidianDisablementReport {
        guard let object = await callerBox.call("moot_community_obsidian_disable")?.objectValue else {
            return .failed(reason: "daemon-unavailable-or-malformed")
        }
        switch object["outcome"]?.stringValue {
        case "disabledOnly": return .disabledOnly
        case "disabledAndRemoved": return .disabledAndRemoved
        default: return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }

    public func retrySync() async -> ObsidianRetryOutcome {
        guard let object = await callerBox.call("moot_community_obsidian_retry")?.objectValue else {
            return .failed(reason: "daemon-unavailable-or-malformed")
        }
        switch object["outcome"]?.stringValue {
        case "restarted": return .restarted
        case "refused": return .refused(reason: object["reason"]?.stringValue ?? "daemon-refused")
        default: return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }

    private static func status(_ object: [String: JSONValue]) -> ObsidianSyncStatus? {
        switch object["state"]?.stringValue {
        case "starting": return .starting
        case "scanning": return .scanning
        case "synchronizing":
            let progress: ObsidianSyncProgress?
            if let pending = int(object["pendingCount"]), let total = int(object["totalCount"]) {
                progress = ObsidianSyncProgress(pendingCount: pending, totalCount: total)
            } else { progress = nil }
            return .synchronizing(progress: progress)
        case "idle":
            let checkpoint = Self.checkpoint(object)
            return .idle(checkpoint: checkpoint)
        case "waiting": return .waiting(until: date(object["until"]))
        case "paused": return .paused
        case "interrupted":
            guard let reason = object["reason"]?.stringValue,
                  let retryable = object["retryable"]?.boolValue else { return nil }
            return .interrupted(reason: reason, retryable: retryable)
        case "blocked":
            guard let reason = object["reason"]?.stringValue else { return nil }
            return .blocked(reason: reason)
        case "failed":
            guard let reason = object["reason"]?.stringValue,
                  let retryable = object["retryable"]?.boolValue else { return nil }
            return .failed(reason: reason, retryable: retryable)
        default: return nil
        }
    }

    private static func checkpoint(_ object: [String: JSONValue]) -> ObsidianCheckpoint? {
        guard let timestamp = date(object["checkpointAt"]),
              let count = int(object["recordCount"]) else { return nil }
        return ObsidianCheckpoint(timestamp: timestamp, recordCount: count)
    }
}

// MARK: - LAN

public actor DaemonLANControlPort: LANControlPort {
    private let callerBox: CommunityFeatureCallerBox

    public init(callerBox: CommunityFeatureCallerBox) {
        self.callerBox = callerBox
    }

    public func loadServingStatus() async -> LANServingStatus {
        guard let object = await callerBox.call("moot_community_lan_status")?.objectValue else {
            return .blocked(reason: "daemon-unavailable-or-malformed")
        }
        return Self.status(object) ?? .blocked(reason: "malformed-daemon-response")
    }

    public func loadServingPolicy() async -> LANServingPolicyLoadOutcome {
        guard let response = await callerBox.call("moot_community_lan_policy") else {
            return .blocked(reason: "daemon-unavailable")
        }
        guard let object = response.objectValue,
              let eligible = int(object["eligibleCount"]), eligible >= 0,
              let ineligible = int(object["ineligibleCount"]), ineligible >= 0,
              let description = object["policyDescription"]?.stringValue else {
            return .failed(reason: "malformed-daemon-response")
        }
        return .loaded(LANServingPolicy(
            eligibleCount: eligible,
            ineligibleCount: ineligible,
            policyDescription: description
        ))
    }

    public func startServing() async -> LANStartOutcome {
        guard let object = await callerBox.call("moot_community_lan_start")?.objectValue else {
            return .failed(reason: "daemon-unavailable-or-malformed")
        }
        switch object["outcome"]?.stringValue {
        case "started":
            guard let endpoint = object["endpoint"]?.stringValue,
                  let auth = Self.authentication(object["authentication"]?.stringValue) else {
                return .failed(reason: "malformed-daemon-response")
            }
            return .started(endpoint: endpoint, authState: auth)
        case "denied": return .denied(reason: object["reason"]?.stringValue ?? "daemon-refused")
        default: return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }

    public func stopServing() async -> LANStopOutcome {
        guard let object = await callerBox.call("moot_community_lan_stop")?.objectValue else {
            return .failed(reason: "daemon-unavailable-or-malformed")
        }
        guard object["outcome"]?.stringValue == "stopped" else {
            return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
        return .stopped
    }

    public func refreshEligibility() async -> LANEligibilityUpdateOutcome {
        guard let object = await callerBox.call("moot_community_lan_refresh_eligibility")?.objectValue else {
            return .failed(reason: "daemon-unavailable-or-malformed")
        }
        switch object["outcome"]?.stringValue {
        case "updated":
            guard let eligible = int(object["eligibleCount"]),
                  let ineligible = int(object["ineligibleCount"]) else {
                return .failed(reason: "malformed-daemon-response")
            }
            return .updated(newEligibleCount: eligible, newIneligibleCount: ineligible)
        case "refused": return .refused(reason: object["reason"]?.stringValue ?? "daemon-refused")
        default: return .failed(reason: object["reason"]?.stringValue ?? "malformed-daemon-response")
        }
    }

    private static func status(_ object: [String: JSONValue]) -> LANServingStatus? {
        switch object["state"]?.stringValue {
        case "stopped": return .stopped
        case "starting": return .starting
        case "active":
            guard let endpoint = object["endpoint"]?.stringValue,
                  let auth = authentication(object["authentication"]?.stringValue) else { return nil }
            return .active(endpoint: endpoint, authState: auth)
        case "interrupted":
            guard let reason = object["reason"]?.stringValue else { return nil }
            return .interrupted(reason: reason)
        case "blocked":
            guard let reason = object["reason"]?.stringValue else { return nil }
            return .blocked(reason: reason)
        case "failed":
            guard let reason = object["reason"]?.stringValue else { return nil }
            return .failed(reason: reason)
        default: return nil
        }
    }

    private static func authentication(_ raw: String?) -> LANAuthenticationState? {
        switch raw {
        case "valid": return .valid
        case "expired": return .expired
        case "notObtained": return .notObtained
        default: return nil
        }
    }
}

// MARK: - Strict wire helpers

private func uuid(_ value: JSONValue?) -> UUID? {
    value?.stringValue.flatMap(UUID.init(uuidString:))
}

private func date(_ value: JSONValue?) -> Date? {
    guard let raw = value?.stringValue else { return nil }
    return ISO8601DateFormatter().date(from: raw)
}

private func url(_ value: JSONValue?) -> URL? {
    guard let raw = value?.stringValue else { return nil }
    return URL(string: raw)
}

private func int(_ value: JSONValue?) -> Int? {
    guard let raw = value?.integerValue else { return nil }
    return Int(exactly: raw)
}

#if os(macOS)
private func securityScopedBookmark(_ url: URL) -> Data? {
    try? url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
    )
}
#endif

private func all<T>(_ values: [JSONValue], transform: (JSONValue) -> T?) -> [T]? {
    let converted = values.compactMap(transform)
    return converted.count == values.count ? converted : nil
}
