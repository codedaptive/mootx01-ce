// CommunityTransferTests.swift
//
// Wave D1: CORE-07 transfer endpoint tests.
//
// Tests the nine transfer tools registered through CommunityContractDispatch
// against a real in-memory estate (GeniusLocusKit + InMemoryStorage) and
// real temp directories so no on-disk estate state persists between tests.
//
// ACCEPTANCE COVERAGE (per CORE-07 spec):
//
//   D1-T1   nine transfer tools appear in communityToolList when coordinator is injected
//   D1-T2   transfer tools absent from list when coordinator is nil (B1-R16 gate)
//   D1-T3   importSource returns selected{format:"MOOT JSON"} for a valid seed file
//   D1-T4   importPlan classifies mixed file (valid+duplicate+invalid) correctly, zero estate mutation
//   D1-T5   importPlan estimatedTransferCount+policyExclusionCount <= candidateCount (invariant)
//   D1-T6   importExecute commits exactly estimatedTransferCount records
//   D1-T7   exportScopes returns scopes with real candidate counts
//   D1-T8   exportPlan count invariant + no estate mutation (plan-only)
//   D1-T9   exportExecute writes MOOT JSON output file; output is parseable
//   D1-T10  stale plan (mutate estate between plan and execute) → plan-stale
//   D1-T11  jobStatus stable across new coordinator instance (survives restart)
//   D1-T12  cancel before commit → cancelled or alreadyComplete
//   D1-T13  exact planToken re-submit → same jobID, no duplicate estate work
//   D1-T14  malformed/unknown argument fields fail closed (error thrown)
//   D1-T15  contract shape validation (outcome discriminator present on every response)
//   D1-T16  export excludes policy-ineligible (.private_) drawers from eligible-all scope
//
// Method: RED → GREEN. Tests authored against the contract spec; the
// CommunityTransferCoordinator makes them green.

import Testing
import Foundation
@testable import MootCommunityDaemon
import AriaMCP
import LocusKit
import GeniusLocusKit
import VaultKit
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Test infrastructure

/// Per-test scratch with an in-memory estate + real temp layout and dest directories.
private struct TransferScratch {
    let layoutURL: URL
    let destDirURL: URL
    let kit: GeniusLocusKit
    let handle: EstateHandle

    init() async throws {
        layoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("d1-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: layoutURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        destDirURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("d1-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destDirURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "transfer-tests-\(UUID())")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await Estate.create(storage: storage, owner: owner)
        handle = try await kit.open(storage: storage, owner: owner)
    }

    func remove() {
        try? FileManager.default.removeItem(at: layoutURL)
        try? FileManager.default.removeItem(at: destDirURL)
    }

    /// Construct a transfer coordinator backed by this estate.
    func makeCoordinator() -> CommunityTransferCoordinator {
        CommunityTransferCoordinator(layoutURL: layoutURL, kit: kit, handle: handle)
    }

    /// Construct a CommunityContractDispatch wired with a transfer coordinator.
    func makeDispatch(coordinator: CommunityTransferCoordinator? = nil) -> CommunityContractDispatch {
        let coord = coordinator ?? makeCoordinator()
        return CommunityContractDispatch(
            state: CommunityProviderState(
                instanceIdentifier: UUID(),
                estateIdentifier: UUID()
            ),
            lifecycle: nil,
            capture: nil,
            review: nil,
            obsidian: nil,
            transfer: coord
        )
    }

    /// Write a minimal valid MOOT JSON seed file with `recordCount` records.
    ///
    /// Each record has a unique id and all required fields. Passing explicit `ids`
    /// pins the record IDs (for duplicate-detection tests).
    func writeSeedFile(
        recordCount: Int,
        prefix: String = "rec",
        ids: [String]? = nil
    ) throws -> URL {
        let url = layoutURL.appendingPathComponent("\(prefix)-seed-\(UUID().uuidString).json")
        var records: [[String: Any]] = []
        for i in 0..<recordCount {
            let id = ids?[i] ?? "\(prefix)-\(i)-\(UUID().uuidString)"
            records.append([
                "id": id,
                "content": "Transfer test record \(i) for \(prefix)",
                "event_time": "2026-01-01T00:00:00Z",
                "room": "inbox",
                "kind": "prose",
                "sensitivity": "normal",
                "exportability": "private",
            ])
        }
        let doc: [String: Any] = [
            "format_version": 1,
            "name": "test-seed-\(prefix)",
            "records": records,
            "facts": [] as [Any],
            "tunnels": [] as [Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: doc)
        try data.write(to: url)
        return url
    }

    /// Write a seed file mixing valid, duplicate, and invalid records.
    ///
    /// - Parameters:
    ///   - validCount: complete records with all required fields
    ///   - invalidCount: records missing the required "room" field
    ///   - duplicateIDs: IDs to include as duplicates (same ids already in estate)
    func writeMixedSeedFile(
        validCount: Int,
        invalidCount: Int,
        duplicateIDs: [String] = []
    ) throws -> URL {
        var records: [[String: Any]] = []
        // Valid records (all required fields present).
        for i in 0..<validCount {
            records.append([
                "id": "valid-\(i)-\(UUID().uuidString)",
                "content": "Valid content \(i)",
                "event_time": "2026-01-01T00:00:00Z",
                "room": "inbox",
                "kind": "prose",
                "sensitivity": "normal",
                "exportability": "private",
            ])
        }
        // Duplicate records: same IDs as records previously committed to the estate.
        for dupID in duplicateIDs {
            records.append([
                "id": dupID,
                "content": "Duplicate content (same id as estate record)",
                "event_time": "2026-01-01T00:00:00Z",
                "room": "inbox",
                "kind": "prose",
                "sensitivity": "normal",
                "exportability": "private",
            ])
        }
        // Invalid records (missing required "room" field → fails schema validation).
        for i in 0..<invalidCount {
            records.append([
                "id": "invalid-\(i)-\(UUID().uuidString)",
                "content": "Invalid — missing room field",
                "event_time": "2026-01-01T00:00:00Z",
                "kind": "prose",
                "sensitivity": "normal",
                "exportability": "private",
                // "room" intentionally absent
            ])
        }
        let doc: [String: Any] = [
            "format_version": 1,
            "name": "mixed-seed",
            "records": records,
            "facts": [] as [Any],
            "tunnels": [] as [Any],
        ]
        let url = layoutURL.appendingPathComponent("mixed-\(UUID().uuidString).json")
        let data = try JSONSerialization.data(withJSONObject: doc)
        try data.write(to: url)
        return url
    }
}

// MARK: - JSON extraction helpers

/// Extract a string field from a tool result's structuredContent.
private func structuredField(_ result: JSONValue, _ key: String) -> String? {
    guard case .object(let obj) = result,
          case .object(let sc) = obj["structuredContent"],
          case .string(let v) = sc[key] else { return nil }
    return v
}

/// Assert content array is a non-empty text frame (wire shape invariant).
private func assertContentFrame(_ result: JSONValue) -> Bool {
    guard case .object(let obj) = result,
          case .array(let content) = obj["content"],
          !content.isEmpty,
          case .object(let frame) = content[0],
          case .string("text") = frame["type"],
          case .string = frame["text"] else { return false }
    return true
}

/// Extract the nested "plan" dict from a planned outcome.
private func extractPlan(_ result: JSONValue) -> JSONValue? {
    guard case .object(let obj) = result,
          case .object(let sc) = obj["structuredContent"],
          let plan = sc["plan"] else { return nil }
    return plan
}

/// Extract planToken from an importPlan or exportPlan result.
///
/// The planToken lives at result.structuredContent.plan.planToken.
private func extractPlanToken(_ result: JSONValue) -> String? {
    guard let plan = extractPlan(result),
          case .object(let p) = plan,
          case .string(let token) = p["planToken"] else { return nil }
    return token
}

/// Extract jobID from a submitted execution result.
private func extractJobID(_ result: JSONValue) -> String? {
    guard case .object(let obj) = result,
          case .object(let sc) = obj["structuredContent"],
          case .string(let id) = sc["jobID"] else { return nil }
    return id
}

/// Count drawers in the estate using RecallFrame. Used for mutation-detection assertions.
private func estateDrawerCount(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws -> Int {
    let drawers = try await kit.recall(
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
    return drawers.count
}

/// Poll a job until it reaches a terminal state (completed/failed/cancelled) or timeout.
///
/// Returns the terminal state string, or nil on timeout.
private func pollJobToCompletion(
    coord: CommunityTransferCoordinator,
    jobID: String,
    maxAttempts: Int = 100
) async -> String? {
    for _ in 0..<maxAttempts {
        try? await Task.sleep(for: .milliseconds(100))
        let statusResult = await coord.jobStatus(jobID: jobID)
        if case .object(let obj) = statusResult,
           case .object(let sc) = obj["structuredContent"],
           case .object(let js) = sc["jobState"],
           case .string(let state) = js["state"],
           state == "completed" || state == "failed" || state == "cancelled" {
            return state
        }
    }
    return nil
}

// MARK: - Tests

@Suite("CommunityTransfer (CORE-07)")
struct CommunityTransferTests {

    // MARK: - D1-T1: nine transfer tools in communityToolList

    @Test("D1-T1: nine transfer tools appear in communityToolList when coordinator is injected")
    func transferToolsInList() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let dispatch = scratch.makeDispatch()
        let names = Set(dispatch.communityToolList.map { $0.name })
        let expected: Set<String> = [
            "moot_community_transfer_import_source",
            "moot_community_transfer_import_plan",
            "moot_community_transfer_import_execute",
            "moot_community_transfer_export_destination",
            "moot_community_transfer_export_scopes",
            "moot_community_transfer_export_plan",
            "moot_community_transfer_export_execute",
            "moot_community_transfer_job_status",
            "moot_community_transfer_job_cancel",
        ]
        for name in expected {
            #expect(names.contains(name), "Missing transfer tool: \(name)")
        }
        #expect(expected.isSubset(of: names))
    }

    // MARK: - D1-T2: transfer tools absent without coordinator

    @Test("D1-T2: transfer tools absent from communityToolList when coordinator is nil")
    func transferToolsGated() async throws {
        // Build dispatch WITHOUT a transfer coordinator (A1b init path: no transfer).
        let dispatch = CommunityContractDispatch(
            state: CommunityProviderState(
                instanceIdentifier: UUID(),
                estateIdentifier: UUID()
            )
        )
        let names = Set(dispatch.communityToolList.map { $0.name })
        let transferNames = [
            "moot_community_transfer_import_source",
            "moot_community_transfer_import_plan",
            "moot_community_transfer_import_execute",
            "moot_community_transfer_export_destination",
            "moot_community_transfer_export_scopes",
            "moot_community_transfer_export_plan",
            "moot_community_transfer_export_execute",
            "moot_community_transfer_job_status",
            "moot_community_transfer_job_cancel",
        ]
        for name in transferNames {
            #expect(!names.contains(name), "Tool \(name) should not appear without coordinator")
        }
    }

    // MARK: - D1-T3: importSource recognizes a valid MOOT JSON seed file

    @Test("D1-T3: importSource returns selected{MOOT JSON} for a valid seed file")
    func importSourceRecognized() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()
        let seedURL = try scratch.writeSeedFile(recordCount: 3)
        let bookmark = Data(seedURL.absoluteString.utf8)
        let result = await coord.importSource(bookmark: bookmark, displayName: "test-seed")
        #expect(assertContentFrame(result))
        #expect(structuredField(result, "outcome") == "selected",
                "Expected selected, got: \(String(describing: structuredField(result, "outcome")))")
        guard case .object(let obj) = result,
              case .object(let sc) = obj["structuredContent"],
              case .object(let fmt) = sc["format"],
              case .bool(let recognized) = fmt["recognized"] else {
            Issue.record("format.recognized field missing"); return
        }
        #expect(recognized == true)
        guard case .string(let fmtName) = fmt["name"] else {
            Issue.record("format.name missing"); return
        }
        #expect(fmtName == "MOOT JSON")
    }

    // MARK: - D1-T4: importPlan classifies mixed file correctly, zero estate mutation

    @Test("D1-T4: importPlan classifies mixed file (valid+dup+invalid); zero estate mutation")
    func importPlanClassifiesMixedFile() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // Seed the estate with 2 records by executing a clean import first.
        // Those record IDs become duplicates when re-planned via the mixed file.
        let dupID0 = "dup-\(UUID().uuidString)"
        let dupID1 = "dup-\(UUID().uuidString)"
        let cleanSeed = try scratch.writeSeedFile(recordCount: 2, prefix: "seed4",
                                                   ids: [dupID0, dupID1])
        let seedPlan = await coord.importPlan(bookmark: Data(cleanSeed.absoluteString.utf8))
        guard let seedToken = extractPlanToken(seedPlan) else {
            Issue.record("planToken missing from seed plan"); return
        }
        let seedExec = await coord.importExecute(planToken: seedToken)
        guard let seedJobID = extractJobID(seedExec) else {
            Issue.record("jobID missing from seed exec"); return
        }
        guard let seedState = await pollJobToCompletion(coord: coord, jobID: seedJobID) else {
            Issue.record("Seed import timed out"); return
        }
        #expect(seedState == "completed")

        let countBefore = try await estateDrawerCount(scratch.kit, scratch.handle)

        // Write mixed file: 3 valid new + 2 duplicates (already in estate) + 1 invalid.
        let mixedURL = try scratch.writeMixedSeedFile(
            validCount: 3,
            invalidCount: 1,
            duplicateIDs: [dupID0, dupID1]
        )
        let result = await coord.importPlan(bookmark: Data(mixedURL.absoluteString.utf8))
        #expect(assertContentFrame(result))
        #expect(structuredField(result, "outcome") == "planned",
                "Expected planned, got: \(String(describing: structuredField(result, "outcome")))")

        guard let plan = extractPlan(result), case .object(let p) = plan else {
            Issue.record("plan field missing"); return
        }

        // candidateCount = 6 total records (3 valid + 2 dup + 1 invalid).
        if case .integer(let cand) = p["candidateCount"] {
            #expect(Int(cand) == 6, "Expected candidateCount=6, got \(cand)")
        }

        // Plan invariant: estimatedTransfer + policyExclusion <= candidateCount.
        if case .integer(let est) = p["estimatedTransferCount"],
           case .integer(let excl) = p["policyExclusionCount"],
           case .integer(let cand) = p["candidateCount"] {
            #expect(est + excl <= cand, "Invariant violated: est+excl=\(est+excl) > cand=\(cand)")
        }

        // executionPermitted must be false: file has duplicates and/or invalids.
        if case .bool(let permitted) = p["executionPermitted"] {
            #expect(permitted == false, "executionPermitted should be false for mixed file")
        }

        // ZERO ESTATE MUTATION: importPlan is read-only.
        let countAfter = try await estateDrawerCount(scratch.kit, scratch.handle)
        #expect(countAfter == countBefore,
                "Estate mutated during importPlan: before=\(countBefore), after=\(countAfter)")
    }

    // MARK: - D1-T5: plan invariant holds for a clean file

    @Test("D1-T5: importPlan invariant estimatedTransfer+exclusion <= candidateCount (clean file)")
    func importPlanInvariantHolds() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()
        let seedURL = try scratch.writeSeedFile(recordCount: 5)
        let result = await coord.importPlan(bookmark: Data(seedURL.absoluteString.utf8))
        #expect(structuredField(result, "outcome") == "planned")
        guard let plan = extractPlan(result), case .object(let p) = plan else {
            Issue.record("plan missing"); return
        }
        if case .integer(let est) = p["estimatedTransferCount"],
           case .integer(let excl) = p["policyExclusionCount"],
           case .integer(let cand) = p["candidateCount"] {
            #expect(est + excl <= cand)
            #expect(Int(est) == 5, "Expected 5 in estimatedTransferCount, got \(est)")
        }
        if case .bool(let permitted) = p["executionPermitted"] {
            #expect(permitted == true, "Clean file should be executionPermitted=true")
        }
    }

    // MARK: - D1-T6: importExecute commits exactly estimatedTransferCount records

    @Test("D1-T6: importExecute commits exactly estimatedTransferCount records")
    func importExecuteCommitsExactCount() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        let seedURL = try scratch.writeSeedFile(recordCount: 4, prefix: "import-t6")
        let planResult = await coord.importPlan(bookmark: Data(seedURL.absoluteString.utf8))
        #expect(structuredField(planResult, "outcome") == "planned")
        guard let planToken = extractPlanToken(planResult) else {
            Issue.record("planToken missing"); return
        }

        let countBefore = try await estateDrawerCount(scratch.kit, scratch.handle)

        let execResult = await coord.importExecute(planToken: planToken)
        #expect(structuredField(execResult, "outcome") == "submitted")
        guard let jobID = extractJobID(execResult) else {
            Issue.record("jobID missing from submitted response"); return
        }

        guard let finalState = await pollJobToCompletion(coord: coord, jobID: jobID) else {
            Issue.record("Import job timed out"); return
        }
        #expect(finalState == "completed", "Import job ended in \(finalState)")

        let countAfter = try await estateDrawerCount(scratch.kit, scratch.handle)
        #expect(countAfter - countBefore == 4,
                "Expected +4 records, got +\(countAfter - countBefore)")
    }

    // MARK: - D1-T7: exportScopes returns candidate counts

    @Test("D1-T7: exportScopes returns non-empty scopes with real candidateCounts")
    func exportScopesReturnsRealCounts() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        _ = try await scratch.kit.capture(
            scratch.handle,
            CaptureFrame(
                content: "Exportable record for scope test",
                channel: .typed, room: "inbox",
                latticeAnchor: .udc("001"),
                addedBy: "test", embeddingModelID: "test",
                exportability: .public_
            )
        )

        let result = await coord.exportScopes()
        #expect(assertContentFrame(result))
        guard case .object(let obj) = result,
              case .object(let sc) = obj["structuredContent"],
              case .array(let scopes) = sc["scopes"] else {
            Issue.record("scopes field missing"); return
        }
        #expect(!scopes.isEmpty, "At least one scope expected")
        let hasPositiveCount = scopes.contains { scope in
            guard case .object(let s) = scope,
                  case .integer(let count) = s["candidateCount"] else { return false }
            return count >= 1
        }
        #expect(hasPositiveCount, "At least one scope should have candidateCount >= 1")
    }

    // MARK: - D1-T8: exportPlan is read-only, plan invariant holds

    @Test("D1-T8: exportPlan is read-only; plan invariant holds")
    func exportPlanIsReadOnly() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        _ = try await scratch.kit.capture(
            scratch.handle,
            CaptureFrame(
                content: "Exportable for plan test",
                channel: .typed, room: "inbox",
                latticeAnchor: .udc("001"),
                addedBy: "test", embeddingModelID: "test",
                exportability: .public_
            )
        )
        let countBefore = try await estateDrawerCount(scratch.kit, scratch.handle)
        let dirBookmark = Data(scratch.destDirURL.absoluteString.utf8)
        let result = await coord.exportPlan(
            bookmark: dirBookmark, fileName: "export-t8.json", scopeToken: "eligible-all"
        )
        #expect(assertContentFrame(result))
        #expect(structuredField(result, "outcome") == "planned")

        if let plan = extractPlan(result), case .object(let p) = plan,
           case .integer(let est) = p["estimatedTransferCount"],
           case .integer(let excl) = p["policyExclusionCount"],
           case .integer(let cand) = p["candidateCount"] {
            #expect(est + excl <= cand)
        }

        let countAfter = try await estateDrawerCount(scratch.kit, scratch.handle)
        #expect(countAfter == countBefore,
                "Estate mutated during exportPlan: before=\(countBefore), after=\(countAfter)")
    }

    // MARK: - D1-T9: exportExecute writes MOOT JSON output file

    @Test("D1-T9: exportExecute writes a parseable MOOT JSON output file")
    func exportExecuteWritesFile() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        _ = try await scratch.kit.capture(
            scratch.handle,
            CaptureFrame(
                content: "Exportable content for export test",
                channel: .typed, room: "inbox",
                latticeAnchor: .udc("001"),
                addedBy: "test", embeddingModelID: "test",
                exportability: .public_
            )
        )

        let dirBookmark = Data(scratch.destDirURL.absoluteString.utf8)
        let fileName = "estate-export-\(UUID().uuidString).json"

        let planResult = await coord.exportPlan(
            bookmark: dirBookmark, fileName: fileName, scopeToken: "eligible-all"
        )
        #expect(structuredField(planResult, "outcome") == "planned")
        guard let planToken = extractPlanToken(planResult) else {
            Issue.record("planToken missing"); return
        }

        let execResult = await coord.exportExecute(planToken: planToken)
        #expect(structuredField(execResult, "outcome") == "submitted")
        guard let jobID = extractJobID(execResult) else {
            Issue.record("jobID missing"); return
        }

        guard let finalState = await pollJobToCompletion(coord: coord, jobID: jobID) else {
            Issue.record("Export job timed out"); return
        }
        #expect(finalState == "completed", "Export ended in \(finalState)")

        let outputURL = scratch.destDirURL.appendingPathComponent(fileName)
        #expect(FileManager.default.fileExists(atPath: outputURL.path),
                "Output file not found at \(outputURL.path)")
        let data = try Data(contentsOf: outputURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed != nil, "Output is not valid JSON")
        let hasStructure = parsed?["entries"] != nil
            || parsed?["records"] != nil
            || parsed?["format_version"] != nil
        #expect(hasStructure, "Output JSON missing expected MOOT JSON keys")
    }

    // MARK: - D1-T10: stale plan rejected

    @Test("D1-T10: stale plan (estate mutated after plan) → denied{plan-stale}")
    func stalePlanRejected() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        let seedURL = try scratch.writeSeedFile(recordCount: 2, prefix: "stale-t10")
        let planResult = await coord.importPlan(bookmark: Data(seedURL.absoluteString.utf8))
        #expect(structuredField(planResult, "outcome") == "planned")
        guard let planToken = extractPlanToken(planResult) else {
            Issue.record("planToken missing"); return
        }

        // Mutate the estate → fingerprint changes → plan becomes stale.
        _ = try await scratch.kit.capture(
            scratch.handle,
            CaptureFrame(
                content: "New record to invalidate plan fingerprint",
                channel: .typed, room: "inbox",
                latticeAnchor: .udc("001"),
                addedBy: "test", embeddingModelID: "test"
            )
        )

        let execResult = await coord.importExecute(planToken: planToken)
        #expect(structuredField(execResult, "outcome") == "denied",
                "Expected denied, got \(String(describing: structuredField(execResult, "outcome")))")
        #expect(structuredField(execResult, "reason") == "plan-stale",
                "Expected plan-stale, got \(String(describing: structuredField(execResult, "reason")))")
    }

    // MARK: - D1-T11: jobStatus stable across coordinator restart

    @Test("D1-T11: jobStatus survives coordinator restart (reads from sidecar)")
    func jobStatusSurvivesRestart() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord1 = scratch.makeCoordinator()

        let seedURL = try scratch.writeSeedFile(recordCount: 2, prefix: "restart-t11")
        let planResult = await coord1.importPlan(bookmark: Data(seedURL.absoluteString.utf8))
        guard let planToken = extractPlanToken(planResult) else {
            Issue.record("planToken missing"); return
        }
        let execResult = await coord1.importExecute(planToken: planToken)
        guard let jobID = extractJobID(execResult) else {
            Issue.record("jobID missing"); return
        }
        guard let _ = await pollJobToCompletion(coord: coord1, jobID: jobID) else {
            Issue.record("Job timed out on first coordinator"); return
        }

        // Create a NEW coordinator backed by the SAME layoutURL.
        let coord2 = scratch.makeCoordinator()

        let statusResult = await coord2.jobStatus(jobID: jobID)
        #expect(structuredField(statusResult, "outcome") == "status",
                "Expected status, got \(String(describing: structuredField(statusResult, "outcome")))")

        guard case .object(let statusObj) = statusResult,
              case .object(let statusSC) = statusObj["structuredContent"],
              case .string(let echoedJobID) = statusSC["jobID"] else {
            Issue.record("jobID not echoed in status response"); return
        }
        #expect(echoedJobID == jobID, "jobID echo invariant violated")

        guard case .object(let js) = statusSC["jobState"],
              case .string(let state) = js["state"] else {
            Issue.record("jobState.state missing"); return
        }
        #expect(state == "completed" || state == "failed",
                "Expected terminal state from sidecar, got \(state)")
    }

    // MARK: - D1-T12: cancel before commit

    @Test("D1-T12: cancel immediately after submission → cancelled or alreadyComplete")
    func cancelBeforeCommit() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        let seedURL = try scratch.writeSeedFile(recordCount: 1, prefix: "cancel-t12")
        let planResult = await coord.importPlan(bookmark: Data(seedURL.absoluteString.utf8))
        guard let planToken = extractPlanToken(planResult) else {
            Issue.record("planToken missing"); return
        }
        let execResult = await coord.importExecute(planToken: planToken)
        guard let jobID = extractJobID(execResult) else {
            Issue.record("jobID missing"); return
        }
        // Cancel immediately after submission.
        let cancelResult = await coord.jobCancel(jobID: jobID)
        let cancelOutcome = structuredField(cancelResult, "outcome")
        // The job may have completed before the cancel arrived (fast path with 1 record).
        #expect(
            cancelOutcome == "cancelled" || cancelOutcome == "alreadyComplete",
            "Unexpected cancel outcome: \(String(describing: cancelOutcome))"
        )
    }

    // MARK: - D1-T13: exact planToken re-submit → same jobID

    @Test("D1-T13: exact planToken re-submit returns same jobID (idempotency)")
    func exactPlanTokenResubmitIdempotent() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()
        let seedURL = try scratch.writeSeedFile(recordCount: 2, prefix: "retry-t13")
        let planResult = await coord.importPlan(bookmark: Data(seedURL.absoluteString.utf8))
        guard let planToken = extractPlanToken(planResult) else {
            Issue.record("planToken missing"); return
        }
        let result1 = await coord.importExecute(planToken: planToken)
        guard let jobID1 = extractJobID(result1) else {
            Issue.record("First execute: jobID missing"); return
        }
        let result2 = await coord.importExecute(planToken: planToken)
        guard let jobID2 = extractJobID(result2) else {
            Issue.record("Second execute: jobID missing"); return
        }
        #expect(jobID1 == jobID2, "Idempotency violated: \(jobID1) != \(jobID2)")
    }

    // MARK: - D1-T14: unknown fields fail closed

    @Test("D1-T14: unknown argument fields are rejected with an error (fail-closed)")
    func unknownFieldsFailClosed() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let dispatch = scratch.makeDispatch()

        await #expect(throws: (any Error).self) {
            _ = try await dispatch.dispatch(
                name: "moot_community_transfer_import_source",
                arguments: .object([
                    "bookmark": .string("dGVzdA=="),
                    "displayName": .string("test"),
                    "HACK": .string("injected"),
                ])
            )
        }

        await #expect(throws: (any Error).self) {
            _ = try await dispatch.dispatch(
                name: "moot_community_transfer_import_plan",
                arguments: .object([
                    "bookmark": .string("dGVzdA=="),
                    "INJECTED": .string("evil"),
                ])
            )
        }

        await #expect(throws: (any Error).self) {
            _ = try await dispatch.dispatch(
                name: "moot_community_transfer_import_execute",
                arguments: .object([
                    "planToken": .string("abc:def"),
                    "extra": .string("extra"),
                ])
            )
        }

        await #expect(throws: (any Error).self) {
            _ = try await dispatch.dispatch(
                name: "moot_community_transfer_job_status",
                arguments: .object([
                    "jobID": .string("some-id"),
                    "UNKNOWN": .string("x"),
                ])
            )
        }

        await #expect(throws: (any Error).self) {
            _ = try await dispatch.dispatch(
                name: "moot_community_transfer_export_scopes",
                arguments: .object(["unexpectedField": .string("value")])
            )
        }
    }

    // MARK: - D1-T15: contract shape validation

    @Test("D1-T15: all transfer endpoints return {content, structuredContent} with outcome field")
    func contractShapeValid() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()
        let dirBookmark = Data(scratch.destDirURL.absoluteString.utf8)

        let seedURL = try scratch.writeSeedFile(recordCount: 1)
        let seedBookmark = Data(seedURL.absoluteString.utf8)

        let sourceResult = await coord.importSource(bookmark: seedBookmark, displayName: "test")
        #expect(assertContentFrame(sourceResult), "importSource response shape invalid")
        #expect(structuredField(sourceResult, "outcome") != nil, "importSource outcome missing")

        let planResult = await coord.importPlan(bookmark: seedBookmark)
        #expect(assertContentFrame(planResult), "importPlan response shape invalid")
        #expect(structuredField(planResult, "outcome") != nil, "importPlan outcome missing")

        let destResult = await coord.exportDestination(bookmark: dirBookmark, fileName: "test.json")
        #expect(assertContentFrame(destResult), "exportDestination response shape invalid")
        #expect(structuredField(destResult, "outcome") != nil, "exportDestination outcome missing")

        let scopesResult = await coord.exportScopes()
        #expect(assertContentFrame(scopesResult), "exportScopes response shape invalid")

        let exportPlanResult = await coord.exportPlan(
            bookmark: dirBookmark, fileName: "test.json", scopeToken: "eligible-all"
        )
        #expect(assertContentFrame(exportPlanResult), "exportPlan response shape invalid")
        #expect(structuredField(exportPlanResult, "outcome") != nil, "exportPlan outcome missing")

        let statusResult = await coord.jobStatus(jobID: "nonexistent-job-id")
        #expect(assertContentFrame(statusResult), "jobStatus response shape invalid")
        #expect(structuredField(statusResult, "outcome") == "notFound",
                "Expected notFound for unknown job")

        let cancelResult = await coord.jobCancel(jobID: "nonexistent-job-id")
        #expect(assertContentFrame(cancelResult), "jobCancel response shape invalid")
        #expect(structuredField(cancelResult, "outcome") == "notFound",
                "Expected notFound for unknown job")
    }

    // MARK: - F13-T1: exportPlan rejects path-traversal file names
    //
    // Regression for Fable finding F13: the caller-supplied `fileName` was
    // passed unvalidated to appendingPathComponent, which means a name like
    // "../../../etc/passwd" could escape the bookmark-granted directory.
    //
    // The fix adds `validateFileName(_:relativeTo:)` which checks at plan time:
    //   - empty name → denied{invalidParams}
    //   - name contains '/' or '\' → denied{invalidParams}
    //   - name == '.' or '..' → denied{invalidParams}
    //   - canonicalized result leaves the granted directory → denied{invalidParams}
    //
    // The same check runs at execute time (defense-in-depth). Both layers reject
    // the hostile name before any filesystem write.

    @Test("F13-T1: exportPlan rejects path-traversal and invalid file names")
    func exportPlanRejectsHostileFileNames() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // Populate the estate so exportPlan has at least one candidate.
        _ = try await scratch.kit.capture(
            scratch.handle,
            CaptureFrame(
                content: "Record for F13 path-traversal test",
                channel: .typed, room: "inbox",
                latticeAnchor: .udc("001"),
                addedBy: "test", embeddingModelID: "test",
                exportability: .public_
            )
        )

        let dirBookmark = Data(scratch.destDirURL.absoluteString.utf8)

        // Hostile file names that must each produce denied{invalidParams}.
        // These cover the four validation axes:
        //   1. Path components:  "../../../etc/passwd", "../evil"
        //   2. Embedded slash:   "subdir/evil.json", "a/b"
        //   3. Dot names:        "..", "."
        //   4. Empty:            ""
        //   5. Windows separator: "foo\\bar.json" (should fail even on macOS)
        let hostileNames: [String] = [
            "../../../etc/passwd",
            "../evil.json",
            "subdir/export.json",
            "a/b",
            "..",
            ".",
            "",
            "foo\\bar.json",
        ]

        for hostileName in hostileNames {
            let result = await coord.exportPlan(
                bookmark: dirBookmark,
                fileName: hostileName,
                scopeToken: "eligible-all"
            )
            let outcome = structuredField(result, "outcome")
            #expect(
                outcome == "denied",
                "hostile fileName '\(hostileName)' must produce denied, got \(String(describing: outcome)) | full: \(result)"
            )
            let reason = structuredField(result, "reason")
            #expect(
                reason == "invalidParams",
                "hostile fileName '\(hostileName)' must have reason=invalidParams, got \(String(describing: reason))"
            )
        }
    }

    // MARK: - F13-T2: exportPlan accepts a valid file name (regression guard)

    @Test("F13-T2: exportPlan accepts a safe file name and returns planned (regression guard)")
    func exportPlanAcceptsValidFileName() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        _ = try await scratch.kit.capture(
            scratch.handle,
            CaptureFrame(
                content: "Record for F13 valid-name regression check",
                channel: .typed, room: "inbox",
                latticeAnchor: .udc("001"),
                addedBy: "test", embeddingModelID: "test",
                exportability: .public_
            )
        )

        let dirBookmark = Data(scratch.destDirURL.absoluteString.utf8)

        // Safe names: flat file name, no traversal, no slashes.
        let safeNames = ["export.json", "my-export-2026.json", "abc_def.json"]
        for safeName in safeNames {
            let result = await coord.exportPlan(
                bookmark: dirBookmark,
                fileName: safeName,
                scopeToken: "eligible-all"
            )
            let outcome = structuredField(result, "outcome")
            #expect(
                outcome == "planned",
                "safe fileName '\(safeName)' must produce planned, got \(String(describing: outcome))"
            )
        }
    }

    // MARK: - GAP-T1: planToken from dead coordinator → denied{plan-stale}
    //
    // Regression for the GAP TEST finding: plan tokens are in-memory only.
    // When the coordinator restarts, the in-memory plan cache is empty. A
    // planToken from the old instance references a UUID that no longer exists
    // in the new instance's cache. The fix splits the old catch-all
    // failed{unexpected-failure} path into two arms:
    //   - malformed token (can't parse) → failed{unexpected-failure}
    //   - valid UUID but plan not found  → denied{plan-stale}
    //
    // This test verifies the second arm: a structurally valid planToken from a
    // dead coordinator instance returns denied{plan-stale} from a fresh instance.

    @Test("GAP-T1: planToken from dead coordinator returns denied{plan-stale} after restart")
    func planTokenFromDeadCoordinatorDenied() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }

        // Coordinator 1: create an import plan and capture its token.
        let coord1 = scratch.makeCoordinator()
        let seedURL = try scratch.writeSeedFile(recordCount: 2, prefix: "gap-t1")
        let planResult = await coord1.importPlan(bookmark: Data(seedURL.absoluteString.utf8))
        #expect(structuredField(planResult, "outcome") == "planned",
                "coord1 importPlan must succeed; got \(planResult)")
        guard let planToken = extractPlanToken(planResult) else {
            Issue.record("planToken missing from coord1 plan"); return
        }

        // coord1 goes out of scope — its in-memory plan cache is gone.
        // Coordinator 2: same layout directory, empty plan cache.
        let coord2 = scratch.makeCoordinator()

        // Execute with the planToken from coord1: plan UUID exists in the token
        // but NOT in coord2's plan cache → must return denied{plan-stale},
        // NOT failed{unexpected-failure}.
        let execResult = await coord2.importExecute(planToken: planToken)
        let outcome = structuredField(execResult, "outcome")
        let reason  = structuredField(execResult, "reason")

        #expect(outcome == "denied",
                "execute with dead coordinator's planToken must produce denied, got \(String(describing: outcome))")
        #expect(reason == "plan-stale",
                "reason must be plan-stale (not unexpected-failure), got \(String(describing: reason))")
    }

    // MARK: - GAP-T2: export planToken from dead coordinator → denied{plan-stale}

    @Test("GAP-T2: export planToken from dead coordinator returns denied{plan-stale}")
    func exportPlanTokenFromDeadCoordinatorDenied() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }

        // Capture an exportable record for coord1 to plan against.
        _ = try await scratch.kit.capture(
            scratch.handle,
            CaptureFrame(
                content: "Exportable for GAP-T2",
                channel: .typed, room: "inbox",
                latticeAnchor: .udc("001"),
                addedBy: "test", embeddingModelID: "test",
                exportability: .public_
            )
        )

        // Coordinator 1: create an export plan.
        let coord1 = scratch.makeCoordinator()
        let dirBookmark = Data(scratch.destDirURL.absoluteString.utf8)
        let planResult = await coord1.exportPlan(
            bookmark: dirBookmark,
            fileName: "gap-t2-export.json",
            scopeToken: "eligible-all"
        )
        #expect(structuredField(planResult, "outcome") == "planned",
                "coord1 exportPlan must succeed; got \(planResult)")
        guard let planToken = extractPlanToken(planResult) else {
            Issue.record("planToken missing from coord1 export plan"); return
        }

        // Coordinator 2: same layout directory, fresh plan cache.
        let coord2 = scratch.makeCoordinator()

        // Execute export with the dead coordinator's planToken → denied{plan-stale}.
        let execResult = await coord2.exportExecute(planToken: planToken)
        let outcome = structuredField(execResult, "outcome")
        let reason  = structuredField(execResult, "reason")

        #expect(outcome == "denied",
                "export execute with dead planToken must produce denied, got \(String(describing: outcome))")
        #expect(reason == "plan-stale",
                "export reason must be plan-stale, got \(String(describing: reason))")
    }

    // MARK: - D1-T16: export excludes private drawers from eligible-all scope

    @Test("D1-T16: .private_ drawers excluded from eligible-all scope; only .public_ transfers")
    func exportExcludesPrivateDrawers() async throws {
        let scratch = try await TransferScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // Capture one exportable (.public_) and one non-exportable (.private_) drawer.
        // The eligible-all scope is backed by VaultExportScope.exportable, which filters
        // for exportability == .public_ at the estate level. The .private_ drawer is outside
        // the scope entirely — it does not appear in candidateCount or estimatedTransferCount.
        _ = try await scratch.kit.capture(
            scratch.handle,
            CaptureFrame(
                content: "Public exportable record",
                channel: .typed, room: "inbox",
                latticeAnchor: .udc("001"),
                addedBy: "test", embeddingModelID: "test",
                exportability: .public_
            )
        )
        _ = try await scratch.kit.capture(
            scratch.handle,
            CaptureFrame(
                content: "Private non-exportable record",
                channel: .typed, room: "inbox",
                latticeAnchor: .udc("001"),
                addedBy: "test", embeddingModelID: "test",
                exportability: .private_   // outside eligible-all scope: not counted at all
            )
        )

        let dirBookmark = Data(scratch.destDirURL.absoluteString.utf8)
        let result = await coord.exportPlan(
            bookmark: dirBookmark, fileName: "t16-export.json", scopeToken: "eligible-all"
        )
        #expect(structuredField(result, "outcome") == "planned")
        if let plan = extractPlan(result), case .object(let p) = plan {
            // Only the .public_ drawer is in scope — estimatedTransferCount must be exactly 1.
            if case .integer(let est) = p["estimatedTransferCount"] {
                // Only the .public_ drawer transfers; private drawer is outside scope.
                #expect(Int(est) == 1, "Expected exactly 1 exportable drawer, got \(est)")
            }
            // candidateCount should also be 1 — private drawer is outside eligible-all scope.
            if case .integer(let cand) = p["candidateCount"] {
                #expect(Int(cand) == 1, "Expected candidateCount=1, got \(cand)")
            }
        }
    }
}
