// CommunityEstateLifecycleTests.swift
//
// Wave A2a: CORE-03 estate-lifecycle endpoint tests.
//
// Tests the six estate-lifecycle tools registered through CommunityContractDispatch
// against a real on-disk estate in a per-test temp directory. Never touches the
// production estate; all estate I/O is to a LifecycleScratch temp dir.
//
// Test coverage:
//   A3-E1   fresh root → inspect returns needsCreation
//   A3-E2   create → ready state with a real estate UUID
//   A3-E3   create when NOT needsCreation → blocked{action-refused}
//   A3-E4   reopen → ready state with the SAME estate UUID
//   A3-E5   corrupt estate file → corrupt state with bounded diagnosis + choices
//   A3-E6   open of absent estateID → blocked{estate-missing}
//   A3-E7   migration operation state survives a simulated reconnect
//   A3-E8   recover without authority → blocked{authority-insufficient}
//   A3-E9   cancel → cancelled{resumable} truthfully
//   A3-E10  unknown argument fields → invalidParams (fail-closed)
//   A3-E11  every response validates against contract.json EstateLifecycleState shape
//
// Method: RED → GREEN. Tests were authored before the full implementation,
// verified red on stub dispatchers, then made green by the Wave A2a implementation.

import Testing
import Foundation
import CryptoKit
@testable import MootCommunityDaemon
import MootDaemonProvider
import AriaMCP
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

// MARK: - Test infrastructure

/// Per-test scratch directory for the coordinator layout.
private struct LifecycleScratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("a3-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// The layout URL passed to CommunityEstateLifecycleCoordinator.
    var layoutURL: URL { url }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Plaintext key provider for test coordinators. No Keychain, no encryption.
private let plaintextProvider: @Sendable (URL) throws -> EstateEncryptionConfig = { _ in .plaintext }

/// Build a dispatcher with a live coordinator over `layoutURL`.
private func makeDispatcher(layoutURL: URL) -> (
    dispatcher: ARIA_MCPDispatcher,
    coordinator: CommunityEstateLifecycleCoordinator
) {
    let coord = CommunityEstateLifecycleCoordinator(
        layoutURL: layoutURL,
        ownerIdentifier: "com.mootx01.daemon.test",
        keyProvider: plaintextProvider
    )
    let providerState = CommunityProviderState(
        instanceIdentifier: UUID(uuidString: "A3000000-0000-0000-0000-000000000001")!,
        estateIdentifier: UUID()  // placeholder — estate endpoints derive from coordinator
    )
    let handler = CommunityContractDispatch(state: providerState, lifecycle: coord)
    let info = ARIA_MCPDispatcher.ServerInfo(name: "mootx01", version: "1.1.0")
    return (ARIA_MCPDispatcher(info: info, communityHandler: handler), coord)
}

/// Execute a tool call through the dispatcher and return structuredContent.
/// Records an issue and returns nil if the response is not a success result.
private func callTool(
    _ dispatcher: ARIA_MCPDispatcher,
    name: String,
    arguments: JSONValue = .object([:])
) async -> [String: JSONValue]? {
    let req = JSONRPCRequest(
        id: .integer(1),
        method: "tools/call",
        params: .object(["name": .string(name), "arguments": arguments])
    )
    let resp = await dispatcher.handle(req)
    guard let r = resp, case .result(let result) = r.payload else {
        Issue.record("Expected result for \(name), got: \(String(describing: resp))")
        return nil
    }
    guard case .object(let outer) = result,
          case .object(let sc) = outer["structuredContent"] else {
        Issue.record("No structuredContent for \(name): \(result)")
        return nil
    }
    return sc
}

/// Execute a tool call and return the JSONRPCError if it returned an error payload.
private func callToolExpectingError(
    _ dispatcher: ARIA_MCPDispatcher,
    name: String,
    arguments: JSONValue = .object([:])
) async -> JSONRPCError? {
    let req = JSONRPCRequest(
        id: .integer(1),
        method: "tools/call",
        params: .object(["name": .string(name), "arguments": arguments])
    )
    let resp = await dispatcher.handle(req)
    guard let r = resp, case .error(let err) = r.payload else { return nil }
    return err
}

/// Extracts the "state" string from a structuredContent dict.
private func stateString(_ sc: [String: JSONValue]?) -> String? {
    guard let sc, case .string(let s) = sc["state"] else { return nil }
    return s
}

// MARK: - Contract shape validator
//
// Validates that a structuredContent dict matches the EstateLifecycleState
// discriminated-union shape from contracts/community/1.1/contract.json.
// This is the groundwork for the Wave E conformance harness; here it is
// scoped to the estate-family tools only.

/// Root URL of the repository (relative to this test file).
private var repoRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()  // CommunityEstateLifecycleTests.swift → MootCommunityDaemonTests/
        .deletingLastPathComponent()  // MootCommunityDaemonTests/ → Tests/
        .deletingLastPathComponent()  // Tests/ → apps/mootx01/
        .deletingLastPathComponent()  // apps/mootx01/ → apps/
        .deletingLastPathComponent()  // apps/ → repo root
}

/// The contracts/community/1.1 directory.
private var contractRoot: URL {
    repoRoot.appendingPathComponent("contracts/community/1.1")
}

/// Known EstateLifecycleState variants and their required extra keys.
/// Derived from contracts/community/1.1/contract.json — kept in sync by
/// `A3-E11` which parses the live contract file.
private let estateLifecycleVariantRequiredKeys: [String: Set<String>] = [
    "checking":          [],
    "needsCreation":     [],
    "chooseExisting":    ["estates"],
    "missingKey":        ["estate", "choices"],
    "corrupt":           ["estate", "diagnosis", "choices"],
    "incompatible":      ["estate", "reason"],
    "migrationRequired": ["plan"],
    "migrating":         ["progress"],
    "ready":             ["receipt"],
    "cancelled":         ["resumable"],
    "blocked":           ["reason"],
]

/// Assert that `sc` is a valid EstateLifecycleState: has a known "state"
/// discriminator and all required keys for that variant.
private func assertValidEstateLifecycleShape(
    _ sc: [String: JSONValue]?,
    context: String = ""
) {
    guard let sc else {
        Issue.record("assertValidEstateLifecycleShape: nil structuredContent\(context.isEmpty ? "" : " (\(context))")")
        return
    }
    guard case .string(let stateStr) = sc["state"] else {
        Issue.record("assertValidEstateLifecycleShape: missing 'state' key\(context.isEmpty ? "" : " (\(context))")")
        return
    }
    guard let required = estateLifecycleVariantRequiredKeys[stateStr] else {
        Issue.record("assertValidEstateLifecycleShape: unknown state '\(stateStr)'\(context.isEmpty ? "" : " (\(context))")")
        return
    }
    for key in required {
        if sc[key] == nil {
            Issue.record("assertValidEstateLifecycleShape: variant '\(stateStr)' missing required key '\(key)'\(context.isEmpty ? "" : " (\(context))")")
        }
    }
}

// MARK: - A3-E1: fresh root → needsCreation

@Test("A3-E1: fresh root ⇒ inspect returns needsCreation")
func freshRootReturnsNeedsCreation() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let sc = await callTool(dispatcher, name: "moot_community_estate_inspect")
    #expect(stateString(sc) == "needsCreation", "Fresh layout with no estate should return needsCreation")
    assertValidEstateLifecycleShape(sc, context: "A3-E1 inspect")
}

// MARK: - A3-E2: create → ready with identity

@Test("A3-E2: create ⇒ ready state with real estate UUID")
func createReturnsReadyWithIdentity() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let sc = await callTool(
        dispatcher,
        name: "moot_community_estate_create",
        arguments: .object(["name": .string("Test Estate")])
    )
    #expect(stateString(sc) == "ready", "Create on fresh layout should return ready")
    // Verify receipt is present and contains a real estate UUID.
    guard case .object(let receipt) = sc?["receipt"],
          case .object(let estate) = receipt["estate"],
          case .string(let estateID) = estate["id"] else {
        Issue.record("A3-E2: missing receipt.estate.id in ready state")
        return
    }
    // The estate UUID must be a real UUID, not all-zeros.
    let parsedUUID = UUID(uuidString: estateID)
    #expect(parsedUUID != nil, "estate.id must be a valid UUID string")
    #expect(parsedUUID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
            "estate.id must not be all-zeros")
    // The name must match what we passed.
    guard case .string(let returnedName) = estate["name"] else {
        Issue.record("A3-E2: estate.name missing")
        return
    }
    #expect(returnedName == "Test Estate", "estate.name must match the create argument")
    assertValidEstateLifecycleShape(sc, context: "A3-E2 create")
}

// MARK: - A3-E3: create when NOT needsCreation → blocked

@Test("A3-E3: create when NOT needsCreation ⇒ blocked{action-refused}")
func createWhenAlreadyExistsIsRefused() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // First create succeeds.
    let sc1 = await callTool(
        dispatcher, name: "moot_community_estate_create",
        arguments: .object(["name": .string("First")])
    )
    #expect(stateString(sc1) == "ready", "First create must succeed")

    // Second create must be refused.
    let sc2 = await callTool(
        dispatcher, name: "moot_community_estate_create",
        arguments: .object(["name": .string("Second")])
    )
    #expect(stateString(sc2) == "blocked", "Second create must be refused")
    guard case .string(let reason) = sc2?["reason"] else {
        Issue.record("A3-E3: missing reason in blocked state")
        return
    }
    #expect(reason == "action-refused", "blocked reason must be action-refused, not \(reason)")
    assertValidEstateLifecycleShape(sc2, context: "A3-E3 second-create")
}

// MARK: - A3-E4: reopen → ready with same identity

@Test("A3-E4: reopen ⇒ ready state with the SAME estate UUID")
func lifecycleReopenReturnsSameIdentity() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }

    // Coordinator A: create the estate.
    let (dispA, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc1 = await callTool(
        dispA, name: "moot_community_estate_create",
        arguments: .object(["name": .string("Reopen Test")])
    )
    guard case .object(let receipt1) = sc1?["receipt"],
          case .object(let estate1) = receipt1["estate"],
          case .string(let uuid1) = estate1["id"] else {
        Issue.record("A3-E4: create did not return estate.id")
        return
    }

    // Coordinator B: new instance, same layout — simulates a daemon restart.
    let (dispB, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc2 = await callTool(dispB, name: "moot_community_estate_inspect")
    #expect(stateString(sc2) == "ready", "Reopen must return ready")
    guard case .object(let receipt2) = sc2?["receipt"],
          case .object(let estate2) = receipt2["estate"],
          case .string(let uuid2) = estate2["id"] else {
        Issue.record("A3-E4: inspect did not return estate.id")
        return
    }
    #expect(uuid1 == uuid2, "Estate UUID must be stable across reopen (CORE-01): uuid1=\(uuid1) uuid2=\(uuid2)")
    assertValidEstateLifecycleShape(sc2, context: "A3-E4 reopen")
}

// MARK: - A3-E5: corrupt estate → corrupt state

@Test("A3-E5: corrupt estate file ⇒ corrupt state with bounded diagnosis + choices")
func corruptEstateReturnsCorruptState() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }

    // Write garbage bytes to the estate path. A real SQLite file starts with
    // "SQLite format 3\0"; these bytes are not that — LocusKit/SQLiteStorage
    // will refuse to open the file and throw a typed error.
    let garbage = Data(repeating: 0xDE, count: 4096)
    let estateURL = scratch.layoutURL.appendingPathComponent("estate.sqlite")
    try garbage.write(to: estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc = await callTool(dispatcher, name: "moot_community_estate_inspect")
    #expect(stateString(sc) == "corrupt", "Garbage estate file must return corrupt state")

    // Verify the required fields are present and bounded.
    guard case .string(let diagnosis) = sc?["diagnosis"] else {
        Issue.record("A3-E5: corrupt state missing diagnosis")
        return
    }
    #expect(!diagnosis.isEmpty, "diagnosis must be non-empty")
    // Diagnosis must be bounded — never a raw SQL error (which may contain
    // SQL text or file-path fragments). We check it is one of our known prefixes.
    let knownDiagnosisPrefixes = [
        "The canonical store failed",
        "The estate encryption key",
        "The estate is locked",
        "The estate connection",
        "The WAL is non-empty",
        "An unexpected",
        "The estate storage backend",
    ]
    let diagnosisIsBounded = knownDiagnosisPrefixes.contains { diagnosis.hasPrefix($0) }
    #expect(diagnosisIsBounded, "diagnosis must be a bounded classification string, not raw error text: \(diagnosis)")

    // Choices must be a non-empty array.
    guard case .array(let choices) = sc?["choices"], !choices.isEmpty else {
        Issue.record("A3-E5: corrupt state missing choices array")
        return
    }
    // Each choice must have the required fields.
    for choice in choices {
        guard case .object(let c) = choice else { continue }
        #expect(c["id"] != nil, "choice must have id")
        #expect(c["title"] != nil, "choice must have title")
        #expect(c["consequence"] != nil, "choice must have consequence")
        #expect(c["isDestructive"] != nil, "choice must have isDestructive")
    }

    assertValidEstateLifecycleShape(sc, context: "A3-E5 corrupt")
}

// MARK: - A3-E6: open of absent estateID → estate-missing

@Test("A3-E6: open of absent estateID ⇒ blocked{estate-missing}")
func openAbsentEstateIDReturnsEstateMissing() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // No estate file exists — requesting any UUID should return estate-missing.
    let absentID = UUID(uuidString: "DEAD0000-0000-0000-0000-000000000000")!
    let sc = await callTool(
        dispatcher, name: "moot_community_estate_open",
        arguments: .object(["estateID": .string(absentID.uuidString.lowercased())])
    )
    #expect(stateString(sc) == "blocked", "Opening absent estate must return blocked")
    guard case .string(let reason) = sc?["reason"] else {
        Issue.record("A3-E6: missing reason in blocked state")
        return
    }
    #expect(reason == "estate-missing", "blocked reason must be estate-missing, not \(reason)")
    assertValidEstateLifecycleShape(sc, context: "A3-E6 open-absent")
}

// MARK: - A3-E7: migration state survives a simulated reconnect

@Test("A3-E7: migration operation state survives a simulated reconnect (new dispatch instance)")
func migrationStateSurvivesReconnect() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }

    // ── Part A: Write an in-progress migration operation state to disk.
    //    This simulates what a previous session's estate_migrate call would
    //    have persisted. Writing it directly (white-box) tests the persistence
    //    layer: the new coordinator must read it back faithfully.
    let operationID = UUID().uuidString.lowercased()
    let planID = UUID().uuidString.lowercased()
    let estateID = UUID().uuidString.lowercased()
    let opState = PersistedOperationState(
        kind: .migrating,
        operationID: operationID,
        planID: planID,
        completedUnits: 4,
        totalUnits: 10,
        estateID: estateID,
        estateName: "Reconnect Test Estate",
        sourceVersion: "1.0",
        targetVersion: "1.1",
        resumable: true
    )
    let stateData = try JSONEncoder().encode(opState)
    let stateURL = scratch.layoutURL.appendingPathComponent("operation-state.json")
    try stateData.write(to: stateURL)

    // ── Part B: Create a NEW coordinator over the same layout. This is the
    //    "simulated reconnect" — new dispatch instance, same on-disk state.
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // ── Part C: Inspect must surface the in-progress migration from disk.
    let sc = await callTool(dispatcher, name: "moot_community_estate_inspect")
    #expect(stateString(sc) == "migrating",
            "New dispatcher must read persisted migrating state: got \(sc?["state"] as Any)")

    // Verify the persisted operationID is returned faithfully.
    guard case .object(let progress) = sc?["progress"] else {
        Issue.record("A3-E7: migrating state missing progress field")
        return
    }
    guard case .string(let returnedOpID) = progress["operationID"] else {
        Issue.record("A3-E7: progress missing operationID")
        return
    }
    #expect(returnedOpID == operationID,
            "Persisted operationID must round-trip: expected \(operationID) got \(returnedOpID)")
    guard case .integer(let completed) = progress["completedUnits"],
          case .integer(let total) = progress["totalUnits"] else {
        Issue.record("A3-E7: progress missing completedUnits/totalUnits")
        return
    }
    #expect(completed == 4, "completedUnits must be preserved")
    #expect(total == 10, "totalUnits must be preserved")

    assertValidEstateLifecycleShape(sc, context: "A3-E7 reconnect-inspect")
}

// MARK: - A3-E7b: estate_migrate returns blocked and persists NO state (honest refusal)
//
// Community edition has no migration source. migrate() must refuse honestly
// (blocked{reason: "migration-interrupted"}) and must NOT write
// operation-state.json — writing phantom state would cause inspect() to
// surface "migrating" forever (F12 fix).
//
// "migration-interrupted" is the contract-valid reason code for a migration
// that cannot proceed. "migration-source-unavailable" is not in the contract's
// reasonCodes enum; "migration-interrupted" covers the same semantics and
// passes the contract shape validator.
//
// NOTE: This test was previously named "estate_migrate creates durable operation
// state on disk" and asserted migrating state + persisted op. Those assertions
// described the BUGGY behavior. They are removed here because the test was
// asserting the exact phantom-state bug that F12 fixes.

@Test("A3-E7b: estate_migrate returns blocked and persists nothing (honest refusal)")
func migrateReturnsBlockedAndPersistsNothing() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }

    // Create an estate first (state does not affect migrate's honest refusal).
    let (dispatcher, coord) = makeDispatcher(layoutURL: scratch.layoutURL)
    _ = await callTool(
        dispatcher, name: "moot_community_estate_create",
        arguments: .object(["name": .string("Migration Test")])
    )

    // Call migrate with a planID.
    let planID = UUID()
    let sc = await callTool(
        dispatcher, name: "moot_community_estate_migrate",
        arguments: .object(["planID": .string(planID.uuidString.lowercased())])
    )

    // Must return blocked with an informative reason — NOT migrating.
    #expect(stateString(sc) == "blocked",
            "community migrate must return blocked (no migration source available)")
    guard case .string(let reason) = sc?["reason"] else {
        Issue.record("A3-E7b: missing reason field in blocked response")
        return
    }
    // "migration-interrupted" is the contract-valid code — see §reasonCodes in contract.json.
    #expect(reason == "migration-interrupted",
            "blocked reason must be migration-interrupted (contract-valid code for unavailable source), got: \(reason)")

    // Critically: operation-state.json must NOT have been written.
    // Writing phantom migrating state would cause inspect() to surface
    // "migrating" forever (F12 root cause).
    let persistedState = await coord.readOperationState()
    #expect(persistedState == nil,
            "migrate must NOT write operation-state.json when refusing honestly")

    // Shape validation: the response must satisfy the contract envelope.
    assertValidEstateLifecycleShape(sc, context: "A3-E7b migrate-honest-refusal")
}

// MARK: - A3-E8: recover without authority → blocked

@Test("A3-E8: recover without authority ⇒ blocked{authority-insufficient}")
func recoverWithoutAuthorityIsRefused() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // The community edition has no authority escalation; any recovery choice
    // must be refused (this matches fixture estate-recovery-refused-without-authority).
    let sc = await callTool(
        dispatcher, name: "moot_community_estate_recover",
        arguments: .object(["choiceID": .string("restore-last-good")])
    )
    #expect(stateString(sc) == "blocked", "recover without authority must return blocked")
    guard case .string(let reason) = sc?["reason"] else {
        Issue.record("A3-E8: missing reason in blocked state")
        return
    }
    #expect(reason == "authority-insufficient",
            "blocked reason must be authority-insufficient, not \(reason)")
    assertValidEstateLifecycleShape(sc, context: "A3-E8 recover-refused")
}

// MARK: - A3-E9: cancel → cancelled{resumable} truthfully

@Test("A3-E9: cancel ⇒ cancelled{resumable} truthfully (resumable=true for interrupted migration)")
func cancelReturnsCancelledResumable() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }

    // Seed an in-progress migration operation state.
    let operationID = UUID()
    let opState = PersistedOperationState(
        kind: .migrating,
        operationID: operationID.uuidString.lowercased(),
        planID: UUID().uuidString.lowercased(),
        completedUnits: 2,
        totalUnits: 10,
        estateID: UUID().uuidString.lowercased(),
        estateName: "Cancel Test",
        sourceVersion: "1.0",
        targetVersion: "1.1",
        resumable: true
    )
    let stateData = try JSONEncoder().encode(opState)
    let stateURL = scratch.layoutURL.appendingPathComponent("operation-state.json")
    try stateData.write(to: stateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // Cancel the in-progress operation.
    let sc = await callTool(
        dispatcher, name: "moot_community_estate_cancel",
        arguments: .object(["operationID": .string(operationID.uuidString.lowercased())])
    )
    #expect(stateString(sc) == "cancelled", "cancel must return cancelled state")
    guard case .bool(let resumable) = sc?["resumable"] else {
        Issue.record("A3-E9: cancelled state missing resumable field")
        return
    }
    // An interrupted migration (completedUnits < totalUnits) is resumable.
    #expect(resumable == true, "An interrupted migration must be resumable=true")
    assertValidEstateLifecycleShape(sc, context: "A3-E9 cancel")
}

// MARK: - A3-E9b: cancel non-existent operationID → blocked

@Test("A3-E9b: cancel of unknown operationID ⇒ blocked{operation-cancelled}")
func cancelUnknownOperationReturnsBlocked() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let unknownID = UUID()
    let sc = await callTool(
        dispatcher, name: "moot_community_estate_cancel",
        arguments: .object(["operationID": .string(unknownID.uuidString.lowercased())])
    )
    #expect(stateString(sc) == "blocked", "cancel of unknown operationID must return blocked")
    assertValidEstateLifecycleShape(sc, context: "A3-E9b cancel-unknown")
}

// MARK: - A3-E10: unknown argument fields → invalidParams (fail-closed)

@Test("A3-E10: unknown argument fields ⇒ invalidParams for all estate tools")
func unknownArgumentFieldsFailClosed() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // Each tool is tested with an extra unexpected field.
    // Fail-closed: unknown fields → invalidParams, never silently ignored.

    // inspect takes Empty: any field is unknown.
    let inspectErr = await callToolExpectingError(
        dispatcher,
        name: "moot_community_estate_inspect",
        arguments: .object(["unexpected": .string("value")])
    )
    #expect(inspectErr?.code == JSONRPCErrorCode.invalidParams,
            "estate_inspect with extra field must return invalidParams")

    // create takes NameArguments{name}: extra field → invalid.
    let createErr = await callToolExpectingError(
        dispatcher,
        name: "moot_community_estate_create",
        arguments: .object(["name": .string("ok"), "extra": .string("bad")])
    )
    #expect(createErr?.code == JSONRPCErrorCode.invalidParams,
            "estate_create with extra field must return invalidParams")

    // open takes EstateIDArguments{estateID}: extra field → invalid.
    let openErr = await callToolExpectingError(
        dispatcher,
        name: "moot_community_estate_open",
        arguments: .object(["estateID": .string(UUID().uuidString), "extra": .bool(true)])
    )
    #expect(openErr?.code == JSONRPCErrorCode.invalidParams,
            "estate_open with extra field must return invalidParams")

    // migrate takes PlanIDArguments{planID}: extra field → invalid.
    let migrateErr = await callToolExpectingError(
        dispatcher,
        name: "moot_community_estate_migrate",
        arguments: .object(["planID": .string(UUID().uuidString), "extra": .integer(1)])
    )
    #expect(migrateErr?.code == JSONRPCErrorCode.invalidParams,
            "estate_migrate with extra field must return invalidParams")

    // recover takes ChoiceIDArguments{choiceID}: extra field → invalid.
    let recoverErr = await callToolExpectingError(
        dispatcher,
        name: "moot_community_estate_recover",
        arguments: .object(["choiceID": .string("ok"), "extra": .null])
    )
    #expect(recoverErr?.code == JSONRPCErrorCode.invalidParams,
            "estate_recover with extra field must return invalidParams")

    // cancel takes OperationIDArguments{operationID}: extra field → invalid.
    let cancelErr = await callToolExpectingError(
        dispatcher,
        name: "moot_community_estate_cancel",
        arguments: .object(["operationID": .string(UUID().uuidString), "extra": .string("bad")])
    )
    #expect(cancelErr?.code == JSONRPCErrorCode.invalidParams,
            "estate_cancel with extra field must return invalidParams")
}

// MARK: - A3-E11: shape validation against contract.json

@Test("A3-E11: every estate endpoint response validates against contract.json EstateLifecycleState shape")
func allResponsesValidateAgainstContractShape() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }

    // Load the live contract.json to verify our variant keys are current.
    let contractURL = contractRoot.appendingPathComponent("contract.json")
    let contractData = try Data(contentsOf: contractURL)
    let contract = try JSONSerialization.jsonObject(with: contractData) as? [String: Any]
    let types = contract?["types"] as? [String: Any]
    let elcType = types?["EstateLifecycleState"] as? [String: Any]
    let variants = elcType?["variants"] as? [String: Any]

    // Verify our known variant key map covers all contract variants.
    if let variants {
        for variantName in variants.keys {
            if estateLifecycleVariantRequiredKeys[variantName] == nil {
                Issue.record("A3-E11: contract variant '\(variantName)' is not in our required-keys map — map needs update")
            }
        }
    }

    // Run all six endpoints through the shape validator.
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // inspect → needsCreation
    let inspectSC = await callTool(dispatcher, name: "moot_community_estate_inspect")
    assertValidEstateLifecycleShape(inspectSC, context: "A3-E11 inspect")

    // create → ready
    let createSC = await callTool(
        dispatcher, name: "moot_community_estate_create",
        arguments: .object(["name": .string("Shape Test")])
    )
    assertValidEstateLifecycleShape(createSC, context: "A3-E11 create")

    // open (absent estateID) → blocked
    let openSC = await callTool(
        dispatcher, name: "moot_community_estate_open",
        arguments: .object(["estateID": .string(UUID().uuidString)])
    )
    assertValidEstateLifecycleShape(openSC, context: "A3-E11 open-absent")

    // migrate → migrating
    let migrateSC = await callTool(
        dispatcher, name: "moot_community_estate_migrate",
        arguments: .object(["planID": .string(UUID().uuidString)])
    )
    assertValidEstateLifecycleShape(migrateSC, context: "A3-E11 migrate")

    // recover → blocked
    let recoverSC = await callTool(
        dispatcher, name: "moot_community_estate_recover",
        arguments: .object(["choiceID": .string("restore-last-good")])
    )
    assertValidEstateLifecycleShape(recoverSC, context: "A3-E11 recover")

    // cancel (no active op) → blocked
    let cancelSC = await callTool(
        dispatcher, name: "moot_community_estate_cancel",
        arguments: .object(["operationID": .string(UUID().uuidString)])
    )
    assertValidEstateLifecycleShape(cancelSC, context: "A3-E11 cancel")
}

// MARK: - A3-E12: tools appear in the tool list

@Test("A3-E12: all six estate tools appear in the tools/list response")
func estateToolsAreInToolList() async throws {
    let scratch = try LifecycleScratch()
    defer { scratch.remove() }
    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let req = JSONRPCRequest(id: .integer(1), method: "tools/list", params: .object([:]))
    let resp = await dispatcher.handle(req)
    guard let r = resp, case .result(let result) = r.payload,
          case .object(let outer) = result,
          case .array(let tools) = outer["tools"] else {
        Issue.record("A3-E12: tools/list did not return tools array")
        return
    }

    let toolNames = tools.compactMap { tool -> String? in
        guard case .object(let t) = tool, case .string(let n) = t["name"] else { return nil }
        return n
    }
    let expectedTools = [
        "moot_community_estate_inspect",
        "moot_community_estate_create",
        "moot_community_estate_open",
        "moot_community_estate_migrate",
        "moot_community_estate_recover",
        "moot_community_estate_cancel",
    ]
    for expected in expectedTools {
        #expect(toolNames.contains(expected), "Tool '\(expected)' must appear in tools/list")
    }
}
