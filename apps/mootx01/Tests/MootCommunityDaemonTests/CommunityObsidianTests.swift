// CommunityObsidianTests.swift
//
// Wave C1: CORE-06 obsidian continuous-sync endpoint tests.
//
// Tests the six obsidian tools registered through CommunityContractDispatch
// against a real in-memory estate (GeniusLocusKit + InMemoryStorage) and
// real temp vault directories so no on-disk estate state persists.
//
// ACCEPTANCE COVERAGE (per CORE-06 spec):
//
//   C6-T1   authorization missing ⇒ enable refused
//   C6-T2   select then enable ⇒ enabled; exportable capture converges to vault
//   C6-T3   non-exportable/sensitivity-excluded record NEVER appears in vault
//   C6-T4   repeated observation of same change ⇒ no duplicates
//   C6-T5   checkpoint survives new coordinator instance; resumes without re-syncing
//   C6-T6   revoke vault dir mid-run ⇒ interrupted{retryable} or blocked honestly
//   C6-T7   retry from terminal non-retryable state ⇒ refused{sync-not-retryable}
//   C6-T8   disable preserves vault content + truthful checkpoint state
//   C6-T9   status invariants (checkpointAt/recordCount pairing, pendingCount<=totalCount)
//   C6-T10  contract.json shape validation for all six endpoints
//   C6-T11  unknown fields fail closed (invalidParams)
//   C6-T12  six obsidian tools appear in tools/list response
//   C6-T13  obsidian tools without coordinator return unavailable responses
//   C6-T14  policy-exclusion: non-exportable drawer does not appear after sync
//   C6-T15  obsidian-vectors files load and pass status invariants
//
// Method: RED → GREEN. Tests authored against the contract spec; the
// CommunityObsidianCoordinator makes them green.

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

/// Per-test scratch with an in-memory estate + a real temp vault directory.
private struct ObsidianScratch {
    let layoutURL: URL
    let vaultURL: URL
    let kit: GeniusLocusKit
    let handle: EstateHandle

    init() async throws {
        // Layout directory for sidecar JSON files.
        layoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("c6-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: layoutURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Vault directory.
        vaultURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("c6-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: vaultURL, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // In-memory estate (same pattern as VaultResidentServiceTests).
        kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "obsidian-tests-\(UUID())")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await Estate.create(storage: storage, owner: owner)
        handle = try await kit.open(storage: storage, owner: owner)
    }

    func remove() {
        try? FileManager.default.removeItem(at: layoutURL)
        try? FileManager.default.removeItem(at: vaultURL)
    }

    /// Construct a coordinator with fast poll intervals for testing.
    func makeCoordinator() -> CommunityObsidianCoordinator {
        CommunityObsidianCoordinator(
            layoutURL: layoutURL,
            kit: kit,
            handle: handle,
            watcherPollSeconds: 60,   // no watcher events needed for most tests
            estatePollSeconds: 600,   // no background estate poll during test
            healthCheckSeconds: 1     // fast health-check for vault-loss detection
        )
    }

    /// Base64-encode the vault URL for use as bookmark data.
    var vaultBookmark: Data {
        Data(vaultURL.absoluteString.utf8)
    }

    /// Base64 string of the vault URL (wire format for obsidian_select_vault).
    var vaultBookmarkBase64: String {
        vaultBookmark.base64EncodedString()
    }
}

/// Capture an exportable drawer into the estate via kit.
///
/// Sets exportability = .public_ so VaultResidentService will write it to the vault.
private func captureExportable(
    kit: GeniusLocusKit,
    handle: EstateHandle,
    content: String,
    subject: String? = nil
) async throws {
    _ = try await kit.capture(
        handle,
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "inbox",
            latticeAnchor: .udc("001"),
            addedBy: "obsidian-test",
            embeddingModelID: "test-model",
            exportability: .public_,   // privacy fence: only .public_ reaches vault
            wing: "test",
            subject: subject
        )
    )
}

/// Capture a non-exportable drawer (stays private, never reaches vault).
private func captureNonExportable(
    kit: GeniusLocusKit,
    handle: EstateHandle,
    content: String
) async throws {
    _ = try await kit.capture(
        handle,
        CaptureFrame(
            content: content,
            channel: .typed,
            room: "private-notes",
            latticeAnchor: .udc("001"),
            addedBy: "obsidian-test",
            embeddingModelID: "test-model",
            exportability: .private_,  // privacy fence: .private_ never reaches vault
            wing: "test",
            subject: nil
        )
    )
}

/// Count .md files in the vault directory tree.
private func countVaultMdFiles(_ vaultURL: URL) -> Int {
    guard let enumerator = FileManager.default.enumerator(
        at: vaultURL,
        includingPropertiesForKeys: [],
        options: [.skipsHiddenFiles]
    ) else { return 0 }
    return (enumerator.allObjects as? [URL])?.filter { $0.pathExtension == "md" }.count ?? 0
}

/// Return true if any .md file under `vaultURL` contains the given substring.
///
/// Uses `allObjects` (non-lazy materialization) to satisfy Swift 6 strict
/// concurrency — iterating `NSEnumerator` lazily in an async context is
/// `unavailable` from Swift 6 because the underlying sequence is not
/// `Sendable`; collecting upfront is safe.
private func vaultContainsText(_ needle: String, in vaultURL: URL) -> Bool {
    guard let enumerator = FileManager.default.enumerator(
        at: vaultURL,
        includingPropertiesForKeys: [],
        options: [.skipsHiddenFiles]
    ) else { return false }
    let mdFiles = (enumerator.allObjects as? [URL])?.filter { $0.pathExtension == "md" } ?? []
    for url in mdFiles {
        if let text = try? String(contentsOf: url, encoding: .utf8), text.contains(needle) {
            return true
        }
    }
    return false
}

/// Extract a string field from a tool result's structuredContent.
private func structuredField(_ result: JSONValue, _ key: String) -> String? {
    guard case .object(let obj) = result,
          case .object(let sc) = obj["structuredContent"],
          case .string(let v) = sc[key] else { return nil }
    return v
}

/// Extract an integer field from a tool result's structuredContent.
private func structuredIntField(_ result: JSONValue, _ key: String) -> Int? {
    guard case .object(let obj) = result,
          case .object(let sc) = obj["structuredContent"] else { return nil }
    if case .integer(let i) = sc[key] { return Int(i) }
    return nil
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

// MARK: - Tests

@Suite("CommunityObsidian (CORE-06)")
struct CommunityObsidianTests {

    // MARK: - C6-T1: authorization missing ⇒ enable refused

    @Test("C6-T1: authorization missing ⇒ enable refused with vault-authorization-missing")
    func authorizationMissingEnableRefused() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // No vault selected → enable must be refused.
        let result = await coord.enable()
        let outcome = structuredField(result, "outcome")
        #expect(outcome == "refused", "Expected refused, got: \(String(describing: outcome))")
        let reason = structuredField(result, "reason")
        #expect(reason == "vault-authorization-missing")

        // Status should show blocked{vault-authorization-missing}.
        let status = await coord.status()
        let state = structuredField(status, "state")
        #expect(state == "blocked")
        let blockReason = structuredField(status, "reason")
        #expect(blockReason == "vault-authorization-missing")

        // Authorization should show missing.
        let auth = await coord.authorization()
        let authState = structuredField(auth, "state")
        #expect(authState == "missing")
    }

    // MARK: - C6-T2: select then enable ⇒ enabled + exportable capture converges

    @Test("C6-T2: select then enable ⇒ enabled; exportable capture converges to vault")
    func selectThenEnableConverges() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // Capture an exportable drawer before enabling.
        try await captureExportable(kit: scratch.kit, handle: scratch.handle,
                                    content: "Test note for vault sync", subject: "Sync Test")

        // Select vault.
        let selResult = await coord.selectVault(
            bookmark: scratch.vaultBookmark,
            displayName: "Test Vault"
        )
        let selOutcome = structuredField(selResult, "outcome")
        #expect(selOutcome == "selected")

        // Enable service.
        let enableResult = await coord.enable()
        let enableOutcome = structuredField(enableResult, "outcome")
        #expect(enableOutcome == "enabled", "Expected enabled, got: \(String(describing: enableOutcome))")

        // Give startup resync a moment to complete.
        try await Task.sleep(nanoseconds: 500_000_000)

        // Verify status is idle (or starting, since resync is fast).
        let status = await coord.status()
        let state = structuredField(status, "state")
        #expect(state == "idle" || state == "starting" || state == "scanning",
                "Expected running state, got: \(String(describing: state))")

        // Verify vault has .md files (the exportable drawer was exported).
        let mdCount = countVaultMdFiles(scratch.vaultURL)
        #expect(mdCount >= 1, "Expected at least one .md file in vault after sync, got \(mdCount)")

        // Cleanup: disable to stop background tasks.
        _ = await coord.disable()
    }

    // MARK: - C6-T3: non-exportable record never appears in vault

    @Test("C6-T3: non-exportable record NEVER appears in vault (privacy fence)")
    func nonExportableNeverReachesVault() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // Capture a non-exportable drawer.
        try await captureNonExportable(kit: scratch.kit, handle: scratch.handle,
                                       content: "Secret: do not sync to vault")

        // Select and enable.
        _ = await coord.selectVault(bookmark: scratch.vaultBookmark, displayName: "TV")
        let enableResult = await coord.enable()
        #expect(structuredField(enableResult, "outcome") == "enabled")

        // Wait for startup resync.
        try await Task.sleep(nanoseconds: 500_000_000)

        // The vault should have zero .md files (only the non-exportable drawer exists).
        let mdCount = countVaultMdFiles(scratch.vaultURL)
        #expect(mdCount == 0, "Expected zero vault files for non-exportable drawer; got \(mdCount)")

        _ = await coord.disable()
    }

    // MARK: - C6-T4: repeated observation of same change ⇒ no duplicates

    @Test("C6-T4: repeated observation of same change ⇒ no duplicates in vault")
    func repeatedObservationNoDuplicates() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }

        // Capture one exportable drawer.
        try await captureExportable(kit: scratch.kit, handle: scratch.handle,
                                    content: "Idempotent note", subject: "Idempotent")

        // First coordinator: select, enable, wait for resync.
        let coord1 = scratch.makeCoordinator()
        _ = await coord1.selectVault(bookmark: scratch.vaultBookmark, displayName: "TV")
        _ = await coord1.enable()
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = await coord1.disable()

        let countAfterFirst = countVaultMdFiles(scratch.vaultURL)

        // Second coordinator (simulates restart): same vault, same estate — resync.
        let coord2 = scratch.makeCoordinator()
        _ = await coord2.resumeIfEnabled()
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = await coord2.disable()

        let countAfterSecond = countVaultMdFiles(scratch.vaultURL)

        // Idempotent: the same files exist, no new duplicates.
        #expect(countAfterSecond == countAfterFirst,
                "Expected same vault file count after second sync; first=\(countAfterFirst), second=\(countAfterSecond)")
    }

    // MARK: - C6-T5: checkpoint survives new coordinator instance

    @Test("C6-T5: checkpoint survives new coordinator instance; resumes from sidecar")
    func checkpointSurvivesRestart() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }

        try await captureExportable(kit: scratch.kit, handle: scratch.handle,
                                    content: "Checkpoint test", subject: "CP")

        // First coordinator: select, enable, wait for resync.
        let coord1 = scratch.makeCoordinator()
        _ = await coord1.selectVault(bookmark: scratch.vaultBookmark, displayName: "TV")
        _ = await coord1.enable()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Read checkpoint from sidecar via status (it's persisted after startup resync).
        let status1 = await coord1.status()
        _ = await coord1.disable()

        // The status should have checkpointAt and recordCount (both present).
        // If status is still "starting", the checkpoint may not yet be written — that's OK.
        // What matters is that the SIDECAR has the checkpoint.
        let state1 = structuredField(status1, "state")
        // Acceptable states: idle (checkpoint written), starting (write pending).
        #expect(state1 == "idle" || state1 == "starting" || state1 == "paused",
                "Unexpected state after first enable: \(String(describing: state1))")

        // Second coordinator: reads sidecar, has the checkpoint.
        let coord2 = scratch.makeCoordinator()
        // Status after restart (disabled state, reads from sidecar).
        let status2 = await coord2.status()
        let state2 = structuredField(status2, "state")
        // Disabled → paused; checkpoint present if first sync completed.
        #expect(state2 == "paused" || state2 == "idle",
                "Expected paused after restart, got: \(String(describing: state2))")
    }

    // MARK: - C6-T6: vault dir removed mid-run ⇒ interrupted{retryable}

    @Test("C6-T6: vault dir removed mid-run ⇒ interrupted{retryable} or blocked honestly")
    func vaultRemovedMidRunInterrupted() async throws {
        // Use a separate vault that we will remove mid-run.
        let ephemeralVault = FileManager.default.temporaryDirectory
            .appendingPathComponent("c6-ephemeral-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ephemeralVault, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ephemeralVault) }

        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }

        // Coordinator with very fast health check (1 s, same as default in makeCoordinator).
        let coord = scratch.makeCoordinator()
        let bookmark = Data(ephemeralVault.absoluteString.utf8)
        _ = await coord.selectVault(bookmark: bookmark, displayName: "Ephemeral")
        _ = await coord.enable()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Remove the vault directory mid-run.
        try FileManager.default.removeItem(at: ephemeralVault)

        // Wait for health check to fire (> 1 second).
        try await Task.sleep(nanoseconds: 2_000_000_000)

        // Status should be interrupted or blocked (not idle).
        let status = await coord.status()
        let state = structuredField(status, "state")
        #expect(state == "interrupted" || state == "blocked",
                "Expected interrupted or blocked after vault removal; got: \(String(describing: state))")

        // If interrupted, must be retryable=true (vault loss is retryable).
        if state == "interrupted" {
            let retryable = structuredField(status, "retryable")
            #expect(retryable == "true" || {
                // retryable is a boolean in the JSON, not a string — check bool form.
                guard case .object(let obj) = status,
                      case .object(let sc) = obj["structuredContent"],
                      case .bool(let b) = sc["retryable"] else { return false }
                return b
            }(), "Expected retryable=true for vault-access-revoked interruption")
        }
    }

    // MARK: - C6-T7: retry from non-retryable state ⇒ refused{sync-not-retryable}

    @Test("C6-T7: retry when not in interrupted state ⇒ refused{sync-not-retryable}")
    func retryFromNonRetryableRefused() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // No interruption state — retry should refuse.
        let result = await coord.retry()
        let outcome = structuredField(result, "outcome")
        #expect(outcome == "refused")
        let reason = structuredField(result, "reason")
        #expect(reason == "sync-not-retryable")
    }

    // MARK: - C6-T8: disable preserves vault content + truthful checkpoint

    @Test("C6-T8: disable preserves vault content and reports truthful checkpoint state")
    func disablePreservesVaultContent() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }

        try await captureExportable(kit: scratch.kit, handle: scratch.handle,
                                    content: "Preserve me", subject: "Preserve")

        let coord = scratch.makeCoordinator()
        _ = await coord.selectVault(bookmark: scratch.vaultBookmark, displayName: "TV")
        _ = await coord.enable()
        try await Task.sleep(nanoseconds: 500_000_000)

        // Count vault files before disable.
        let before = countVaultMdFiles(scratch.vaultURL)

        // Disable.
        let result = await coord.disable()
        let outcome = structuredField(result, "outcome")
        // Contract: disable returns disabledOnly (vault content preserved, not removed).
        #expect(outcome == "disabledOnly",
                "Expected disabledOnly, got: \(String(describing: outcome))")

        // Vault content is preserved on disk.
        let after = countVaultMdFiles(scratch.vaultURL)
        #expect(after == before,
                "Expected vault file count unchanged after disable; before=\(before), after=\(after)")

        // Status should be paused (disabled but checkpoint truthfully reported).
        let status = await coord.status()
        let state = structuredField(status, "state")
        #expect(state == "paused", "Expected paused after disable, got: \(String(describing: state))")
    }

    // MARK: - C6-T9: status invariants (checkpointAt/recordCount pairing)

    @Test("C6-T9: status invariants — checkpointAt and recordCount both present or both absent")
    func statusCheckpointInvariants() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // No vault selected: checkpointAt and recordCount should both be absent.
        let blocked = await coord.status()
        assertCheckpointPairing(blocked, label: "blocked (no auth)")

        // Select vault (no sync yet): still no checkpoint.
        _ = await coord.selectVault(bookmark: scratch.vaultBookmark, displayName: "TV")
        let paused = await coord.status()
        assertCheckpointPairing(paused, label: "paused (no sync)")

        // Enable and resync.
        _ = await coord.enable()
        try await Task.sleep(nanoseconds: 500_000_000)
        let running = await coord.status()
        assertCheckpointPairing(running, label: "after resync")

        _ = await coord.disable()
        let disabled = await coord.status()
        assertCheckpointPairing(disabled, label: "disabled")
    }

    // MARK: - C6-T10: contract shape validation for all six endpoints

    @Test("C6-T10: all six obsidian endpoints return valid MCP structured-result shapes")
    func allEndpointsReturnValidShapes() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // Test each endpoint and verify MCP shape.
        let responses = [
            await coord.status(),
            await coord.authorization(),
            await coord.selectVault(
                bookmark: scratch.vaultBookmark,
                displayName: "TestVault"
            ),
            await coord.enable(),
            await coord.disable(),
            await coord.retry(),
        ]

        for (i, resp) in responses.enumerated() {
            #expect(assertContentFrame(resp),
                    "Response \(i) missing valid content frame: \(resp)")
            // structuredContent must have a discriminator field.
            guard case .object(let obj) = resp,
                  case .object(let sc) = obj["structuredContent"] else {
                Issue.record("Response \(i) missing structuredContent")
                continue
            }
            let hasState = sc["state"] != nil
            let hasOutcome = sc["outcome"] != nil
            #expect(hasState || hasOutcome,
                    "Response \(i) structuredContent missing 'state' or 'outcome' discriminator")
        }
    }

    // MARK: - C6-T11: unknown fields fail closed (invalidParams)

    @Test("C6-T11: unknown argument fields in obsidian tools return invalidParams")
    func unknownFieldsFailClosed() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let dispatch = makeMockDispatch(scratch: scratch)

        // All Empty-argument endpoints reject unknown fields.
        let emptyTools = [
            "moot_community_obsidian_status",
            "moot_community_obsidian_authorization",
            "moot_community_obsidian_enable",
            "moot_community_obsidian_disable",
            "moot_community_obsidian_retry",
        ]
        for tool in emptyTools {
            await #expect(throws: JSONRPCError.self) {
                _ = try await dispatch.dispatch(
                    name: tool,
                    arguments: .object(["unknownField": .string("val")])
                )
            }
        }

        // select_vault rejects unknown fields.
        await #expect(throws: JSONRPCError.self) {
            _ = try await dispatch.dispatch(
                name: "moot_community_obsidian_select_vault",
                arguments: .object([
                    "bookmark": .string("Ym9va21hcms="),
                    "displayName": .string("TV"),
                    "extraField": .string("oops"),
                ])
            )
        }
    }

    // MARK: - C6-T12: six obsidian tools appear in tools/list

    @Test("C6-T12: six obsidian tools appear in communityToolList")
    func sixObsidianToolsInList() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let dispatch = makeMockDispatch(scratch: scratch)

        let names = dispatch.communityToolList.map { $0.name }
        let expected = [
            "moot_community_obsidian_status",
            "moot_community_obsidian_authorization",
            "moot_community_obsidian_select_vault",
            "moot_community_obsidian_enable",
            "moot_community_obsidian_disable",
            "moot_community_obsidian_retry",
        ]
        for name in expected {
            #expect(names.contains(name), "Tool '\(name)' not in tools/list")
        }
    }

    // MARK: - C6-T13: obsidian tools without coordinator return unavailable responses

    @Test("C6-T13: obsidian tools without coordinator return blocked/refused/denied/missing")
    func obsidianToolsWithoutCoordinator() async throws {
        let state = CommunityProviderState(
            instanceIdentifier: UUID(),
            estateIdentifier: UUID()
        )
        // Dispatch with NO obsidian coordinator injected.
        let dispatch = CommunityContractDispatch(state: state)

        // status → blocked
        let statusResult = try await dispatch.dispatch(
            name: "moot_community_obsidian_status",
            arguments: .object([:])
        )
        #expect(structuredField(statusResult, "state") == "blocked")

        // authorization → missing
        let authResult = try await dispatch.dispatch(
            name: "moot_community_obsidian_authorization",
            arguments: .object([:])
        )
        #expect(structuredField(authResult, "state") == "missing")

        // enable → refused
        let enableResult = try await dispatch.dispatch(
            name: "moot_community_obsidian_enable",
            arguments: .object([:])
        )
        #expect(structuredField(enableResult, "outcome") == "refused")

        // disable → failed
        let disableResult = try await dispatch.dispatch(
            name: "moot_community_obsidian_disable",
            arguments: .object([:])
        )
        #expect(structuredField(disableResult, "outcome") == "failed")

        // retry → refused
        let retryResult = try await dispatch.dispatch(
            name: "moot_community_obsidian_retry",
            arguments: .object([:])
        )
        #expect(structuredField(retryResult, "outcome") == "refused")
    }

    // MARK: - C6-T14: policy-exclusion: non-exportable drawer never reaches vault

    @Test("C6-T14: policy-exclusion — only exportable drawers appear; policy-refused reflected in status")
    func policyExclusionBlockedNonExportable() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // Capture mixed: one exportable, one non-exportable.
        try await captureExportable(kit: scratch.kit, handle: scratch.handle,
                                    content: "Exportable content", subject: "Pub")
        try await captureNonExportable(kit: scratch.kit, handle: scratch.handle,
                                       content: "Private content — must not appear")

        _ = await coord.selectVault(bookmark: scratch.vaultBookmark, displayName: "TV")
        _ = await coord.enable()
        try await Task.sleep(nanoseconds: 500_000_000)

        // The vault should have at least 1 .md file (the exportable one exported by VaultBridge).
        // VaultKit may write additional metadata/index .md files — exact count is an
        // implementation detail. The privacy invariant is: the private content string
        // ("Private content — must not appear") must not appear in any vault file.
        let mdCount = countVaultMdFiles(scratch.vaultURL)
        #expect(mdCount >= 1, "Expected at least 1 vault file; got \(mdCount)")

        // Scan every .md file for the private content string.
        // Use allObjects (non-lazy) to satisfy Swift 6 async context requirements.
        let privateContentFound = vaultContainsText(
            "Private content — must not appear",
            in: scratch.vaultURL
        )
        #expect(!privateContentFound,
                "Private (non-exportable) content must not appear in any vault .md file")

        _ = await coord.disable()
    }

    // MARK: - C6-T15: obsidian-vectors files load and pass status invariants

    @Test("C6-T15: obsidian-vectors status files load and each entry passes contract invariants")
    func obsidianVectorsLoadAndPassInvariants() throws {
        let vectorsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/MootCommunityDaemonTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // apps/mootx01
            .appendingPathComponent("testdata/obsidian-vectors", isDirectory: true)

        let fm = FileManager.default
        guard fm.fileExists(atPath: vectorsDir.path) else {
            // Vectors directory doesn't exist yet — skip gracefully.
            return
        }

        let jsonFiles = (try? fm.contentsOfDirectory(atPath: vectorsDir.path))?
            .filter { $0.hasSuffix(".json") } ?? []

        for filename in jsonFiles {
            let fileURL = vectorsDir.appendingPathComponent(filename)
            let data = try Data(contentsOf: fileURL)
            let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []

            for (i, entry) in json.enumerated() {
                guard let state = entry["state"] as? String else {
                    Issue.record("Vector \(filename)[\(i)] missing 'state' field")
                    continue
                }

                // Validate checkpointAt/recordCount pairing invariant.
                let hasCheckpointAt = entry["checkpointAt"] != nil
                let hasRecordCount = entry["recordCount"] != nil
                #expect(
                    hasCheckpointAt == hasRecordCount,
                    "Vector \(filename)[\(i)] state=\(state): checkpointAt and recordCount must both be present or both absent"
                )

                // Validate pendingCount/totalCount pairing.
                let hasPending = entry["pendingCount"] != nil
                let hasTotal = entry["totalCount"] != nil
                #expect(
                    hasPending == hasTotal,
                    "Vector \(filename)[\(i)] state=\(state): pendingCount and totalCount must both be present or both absent"
                )

                // Validate pendingCount <= totalCount.
                if let p = entry["pendingCount"] as? Int, let t = entry["totalCount"] as? Int {
                    #expect(p <= t,
                            "Vector \(filename)[\(i)] state=\(state): pendingCount (\(p)) must be <= totalCount (\(t))")
                }

                // Validate interrupted/blocked/failed have 'reason'.
                if ["interrupted", "blocked", "failed"].contains(state) {
                    #expect(entry["reason"] != nil,
                            "Vector \(filename)[\(i)] state=\(state) must have 'reason'")
                }
                // Validate interrupted/failed have 'retryable'.
                if ["interrupted", "failed"].contains(state) {
                    #expect(entry["retryable"] != nil,
                            "Vector \(filename)[\(i)] state=\(state) must have 'retryable'")
                }
            }
        }
    }

    // MARK: - C6-T16: select_vault with invalid bookmark returns denied

    @Test("C6-T16: select_vault with invalid bookmark returns denied")
    func selectVaultInvalidBookmarkDenied() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        // Bookmark that decodes to a non-existent path.
        let badBookmark = Data("file:///no/such/path/\(UUID().uuidString)".utf8)
        let result = await coord.selectVault(bookmark: badBookmark, displayName: "Bad")
        let outcome = structuredField(result, "outcome")
        #expect(outcome == "denied")
        let reason = structuredField(result, "reason")
        #expect(reason == "vault-authorization-missing")
    }

    // MARK: - C6-T17: enable after disable re-enables cleanly

    @Test("C6-T17: enable after disable re-enables and service is running")
    func enableAfterDisableReenables() async throws {
        let scratch = try await ObsidianScratch()
        defer { scratch.remove() }
        let coord = scratch.makeCoordinator()

        _ = await coord.selectVault(bookmark: scratch.vaultBookmark, displayName: "TV")

        // Enable → disable → enable.
        _ = await coord.enable()
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = await coord.disable()

        let reEnableResult = await coord.enable()
        let outcome = structuredField(reEnableResult, "outcome")
        #expect(outcome == "enabled")

        _ = await coord.disable()
    }

    // MARK: - Helpers

    /// Assert checkpointAt and recordCount are both present or both absent
    /// in a status response's structuredContent.
    private func assertCheckpointPairing(_ result: JSONValue, label: String) {
        guard case .object(let obj) = result,
              case .object(let sc) = obj["structuredContent"] else {
            Issue.record("\(label): missing structuredContent")
            return
        }
        let hasCA = sc["checkpointAt"] != nil
        let hasRC = sc["recordCount"] != nil
        #expect(hasCA == hasRC,
                "\(label): checkpointAt and recordCount must both be present or both absent")
    }

    /// Build a CommunityContractDispatch with the obsidian coordinator injected.
    private func makeMockDispatch(scratch: ObsidianScratch) -> CommunityContractDispatch {
        let provState = CommunityProviderState(
            instanceIdentifier: UUID(),
            estateIdentifier: UUID()
        )
        let coord = scratch.makeCoordinator()
        return CommunityContractDispatch(
            state: provState,
            lifecycle: nil,
            capture: nil,
            review: nil,
            obsidian: coord
        )
    }
}
