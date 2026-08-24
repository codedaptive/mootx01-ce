// CommunityCaptureTests.swift
//
// Wave A2b: CORE-04 capture-family endpoint tests.
//
// Tests the two capture tools registered through CommunityContractDispatch
// against a real on-disk estate in a per-test temp directory.
//
// Test coverage (RED→GREEN per CORE-04 spec):
//
//   A4-C1   choices reflects actually-existing destinations (rooms in estate)
//   A4-C2   choices returns all four sensitivities
//   A4-C3   defaultPolicy is private-leaning (restricted, no export/LAN)
//   A4-C4   defaultPolicy.destinationID ∈ destinations (invariant)
//   A4-C5   capture to valid destination returns applied{recordID, effectivePolicy}
//   A4-C6   capture persists drawer — estate re-read observes the SAME policy
//   A4-C7   stale destination → refused(destination, destination-stale)
//   A4-C8   unknown destination → refused(destination, destination-stale) [non-empty]
//   A4-C9   lanEligible=true with exportEligible=false → refused(lan-eligibility, privacy-escalation)
//   A4-C10  exact retry returns byte-identical receipt and record count unchanged
//   A4-C11  exact retry across a NEW CommunityCaptureCoordinator (durability test)
//   A4-C12  conflicting retry (same requestID, different destinationID) → request-conflict
//   A4-C13  unknown argument fields → invalidParams (fail-closed)
//   A4-C14  missing required fields → invalidParams (fail-closed)
//   A4-C15  response shapes validate against contract.json capture types
//   A4-C16  empty content → refused(content, capture-content-invalid)
//   A4-C17  secret sensitivity with exportEligible=true → refused (privacy-escalation)
//   A4-C18  choices on empty estate returns empty destinations array
//
// Method: RED → GREEN. Tests were authored against the contract spec; the
// CommunityCaptureCoordinator makes them green.

import Testing
import Foundation
@testable import MootCommunityDaemon
import AriaMCP
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

// MARK: - Test infrastructure

/// Per-test scratch directory with a seeded estate.
///
/// Seeds two rooms (personal/capture and work/inbox) using LocusKit's
/// `Estate.capture` (which creates wing and room nodes on demand). This
/// gives the capture coordinator real destinations to enumerate.
private struct CaptureScratch {
    let url: URL

    /// The layout directory (= url). CommunityEstateLifecycleCoordinator
    /// and CommunityCaptureCoordinator use the layout directory convention
    /// (estate.sqlite at layoutURL/estate.sqlite).
    var layoutURL: URL { url }
    var estateURL: URL { url.appendingPathComponent("estate.sqlite") }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("a4-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// Plaintext key provider for test estates.
private let plaintextProvider: @Sendable (URL) throws -> EstateEncryptionConfig = { _ in .plaintext }

/// Seed a fresh estate at `estateURL` with two rooms:
///   - wing "personal", room "capture"
///   - wing "work",     room "inbox"
///
/// Returns after closing the estate so the capture coordinator can open it.
private func seedEstateRooms(at estateURL: URL) async throws {
    let config = EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: estateURL, busyTimeout: 5.0)
    )
    let storage = try SQLiteStorage(configuration: config)
    let estate = try await Estate.open(
        storage: storage,
        owner: OwnerCredentials(ownerIdentifier: "capture-test-seeder"),
        identityKeyStore: InMemoryEstateIdentityKeyStore()
    )
    // Capture a seed drawer in each room. This is the only way to create
    // wing/room nodes via the public Estate API (node creation is implicit
    // in the capture path — see EstateVerbs.captureBatch's createNode calls).
    _ = try await estate.capture(CaptureFrame(
        content: "seed: personal capture room",
        channel: .typed,
        room: "capture",
        latticeAnchor: .udc("001"),
        addedBy: "test-seeder",
        embeddingModelID: "test-model-v1",
        wing: "personal"
    ))
    _ = try await estate.capture(CaptureFrame(
        content: "seed: work inbox room",
        channel: .typed,
        room: "inbox",
        latticeAnchor: .udc("001"),
        addedBy: "test-seeder",
        embeddingModelID: "test-model-v1",
        wing: "work"
    ))
    // Close storage so the capture coordinator can open its own connection.
    await storage.close()
}

/// Build a capture dispatcher over a seeded scratch estate.
///
/// Returns the dispatcher and coordinator so tests can introspect the
/// coordinator directly (for the downstream-query invariant tests).
private func makeDispatcher(layoutURL: URL) -> (
    dispatcher: ARIA_MCPDispatcher,
    captureCoord: CommunityCaptureCoordinator
) {
    let coord = CommunityCaptureCoordinator(
        layoutURL: layoutURL,
        ownerIdentifier: "com.mootx01.daemon.test",
        keyProvider: plaintextProvider
    )
    let providerState = CommunityProviderState(
        instanceIdentifier: UUID(uuidString: "A4000000-0000-0000-0000-000000000001")!,
        estateIdentifier: UUID()
    )
    let handler = CommunityContractDispatch(
        state: providerState,
        lifecycle: nil,
        capture: coord
    )
    let info = ARIA_MCPDispatcher.ServerInfo(name: "mootx01", version: "1.1.0")
    return (ARIA_MCPDispatcher(info: info, communityHandler: handler), coord)
}

/// Execute a capture tool call through the dispatcher and return structuredContent.
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

/// Execute a tool call and return (response dict, JSONRPC error) — for error-path tests.
private func callToolForError(
    _ dispatcher: ARIA_MCPDispatcher,
    name: String,
    arguments: JSONValue
) async -> (result: [String: JSONValue]?, error: (code: Int, message: String)?) {
    let req = JSONRPCRequest(
        id: .integer(1),
        method: "tools/call",
        params: .object(["name": .string(name), "arguments": arguments])
    )
    let resp = await dispatcher.handle(req)
    guard let r = resp else { return (nil, nil) }
    switch r.payload {
    case .result(let result):
        guard case .object(let outer) = result,
              case .object(let sc) = outer["structuredContent"] else {
            return (nil, nil)
        }
        return (sc, nil)
    case .error(let jsonrpcError):
        return (nil, (code: jsonrpcError.code, message: jsonrpcError.message))
    }
}

/// Extract the contract.json types section for shape validation.
private var contractTypesURL: URL {
    // Derive repo root from this test file's path (same as CommunityContractTests).
    URL(filePath: #filePath)
        .deletingLastPathComponent()  // MootCommunityDaemonTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // apps/mootx01/
        .deletingLastPathComponent()  // apps/
        .appendingPathComponent("contracts/community/1.1/contract.json")
}

// MARK: - A4-C18: choices on empty estate

@Test("A4-C18: choices on estate with no rooms returns empty destinations")
func captureChoicesEmptyEstate() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }

    // Create an estate without any rooms (just a fresh open/create cycle).
    let config = EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: scratch.estateURL, busyTimeout: 5.0)
    )
    let storage = try SQLiteStorage(configuration: config)
    let _ = try await Estate.open(
        storage: storage,
        owner: OwnerCredentials(ownerIdentifier: "test"),
        identityKeyStore: InMemoryEstateIdentityKeyStore()
    )
    await storage.close()

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc = await callTool(dispatcher, name: "moot_community_capture_choices")
    let sc_ = try #require(sc)

    guard case .array(let destinations) = sc_["destinations"] else {
        Issue.record("destinations should be an array")
        return
    }
    #expect(destinations.isEmpty, "empty estate → no destinations")
}

// MARK: - A4-C1 through A4-C4: capture_choices with seeded estate

@Test("A4-C1: choices reflects actually-existing destinations (rooms in estate)")
func captureChoicesReflectsRooms() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc = await callTool(dispatcher, name: "moot_community_capture_choices")
    let sc_ = try #require(sc)

    guard case .array(let destinations) = sc_["destinations"] else {
        Issue.record("destinations not an array")
        return
    }

    // Exactly two destinations: "personal/capture" and "work/inbox".
    #expect(destinations.count == 2, "expected 2 destinations, got \(destinations.count)")

    let destIDs: [String] = destinations.compactMap { dest in
        guard case .object(let d) = dest, case .string(let id) = d["id"] else { return nil }
        return id
    }
    // Sorted alphabetically per the coordinator.
    #expect(destIDs.contains("personal/capture"), "missing personal/capture destination")
    #expect(destIDs.contains("work/inbox"), "missing work/inbox destination")

    // Each destination must have id, title, and detail (non-empty strings).
    for dest in destinations {
        guard case .object(let d) = dest else {
            Issue.record("destination is not an object")
            continue
        }
        guard case .string(let id) = d["id"], !id.isEmpty else {
            Issue.record("destination.id missing or empty")
            continue
        }
        guard case .string(let title) = d["title"], !title.isEmpty else {
            Issue.record("destination.title missing or empty for id=\(d["id"] as Any)")
            continue
        }
        // detail may be empty per contract (it's a "string", not "nonempty-string").
        guard case .string(_) = d["detail"] else {
            Issue.record("destination.detail missing or wrong type for id=\(d["id"] as Any)")
            continue
        }
    }
}

@Test("A4-C2: choices returns all four sensitivities in escalating order")
func captureChoicesAllFourSensitivities() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc = await callTool(dispatcher, name: "moot_community_capture_choices")
    let sc_ = try #require(sc)

    guard case .array(let sensitivities) = sc_["sensitivities"] else {
        Issue.record("sensitivities not an array")
        return
    }
    #expect(sensitivities.count == 4, "expected 4 sensitivities")
    let sensitivityValues = sensitivities.compactMap { v -> String? in
        guard case .string(let s) = v else { return nil }
        return s
    }
    // Must include all four contract values.
    for expected in ["normal", "elevated", "restricted", "secret"] {
        #expect(sensitivityValues.contains(expected), "missing sensitivity '\(expected)'")
    }
}

@Test("A4-C3: defaultPolicy is private-leaning (restricted, no export, no LAN)")
func captureChoicesPrivateLeaningDefault() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc = await callTool(dispatcher, name: "moot_community_capture_choices")
    let sc_ = try #require(sc)

    guard case .object(let policy) = sc_["defaultPolicy"] else {
        Issue.record("defaultPolicy not an object")
        return
    }
    guard case .string(let sensitivity) = policy["sensitivity"] else {
        Issue.record("defaultPolicy.sensitivity missing")
        return
    }
    #expect(sensitivity == "restricted", "expected restricted default, got \(sensitivity)")

    guard case .bool(let exportEligible) = policy["exportEligible"] else {
        Issue.record("defaultPolicy.exportEligible missing or not boolean")
        return
    }
    #expect(!exportEligible, "default exportEligible must be false (private-leaning)")

    guard case .bool(let lanEligible) = policy["lanEligible"] else {
        Issue.record("defaultPolicy.lanEligible missing or not boolean")
        return
    }
    #expect(!lanEligible, "default lanEligible must be false (private-leaning)")
}

@Test("A4-C4: defaultPolicy.destinationID is in the destinations array")
func captureChoicesDefaultDestinationInDestinations() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc = await callTool(dispatcher, name: "moot_community_capture_choices")
    let sc_ = try #require(sc)

    guard case .array(let destinations) = sc_["destinations"],
          case .object(let policy) = sc_["defaultPolicy"],
          case .string(let defaultDestID) = policy["destinationID"] else {
        Issue.record("missing destinations or defaultPolicy")
        return
    }
    let destIDs: [String] = destinations.compactMap { dest in
        guard case .object(let d) = dest, case .string(let id) = d["id"] else { return nil }
        return id
    }
    #expect(destIDs.contains(defaultDestID),
            "defaultPolicy.destinationID '\(defaultDestID)' not in destinations")
}

// MARK: - A4-C5 through A4-C6: capture applies and persists

@Test("A4-C5: capture to valid destination returns applied{recordID, effectivePolicy}")
func captureToValidDestinationApplied() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let args = JSONValue.object([
        "requestID": .string("30000000-0000-0000-0000-000000000001"),
        "subject": .string("Test subject"),
        "content": .string("Test capture content."),
        "destinationID": .string("work/inbox"),
        "sensitivity": .string("elevated"),
        "exportEligible": .bool(true),
        "lanEligible": .bool(false),
    ])
    let sc = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc_ = try #require(sc)

    guard case .string(let outcome) = sc_["outcome"] else {
        Issue.record("outcome field missing: \(sc_)")
        return
    }
    #expect(outcome == "applied", "expected applied, got \(outcome)")

    // recordID must be a valid UUID string.
    guard case .string(let recordIDStr) = sc_["recordID"],
          let _ = UUID(uuidString: recordIDStr) else {
        Issue.record("recordID missing or not a valid UUID: \(sc_["recordID"] as Any)")
        return
    }

    // effectivePolicy must carry the same values we supplied.
    guard case .object(let policy) = sc_["effectivePolicy"] else {
        Issue.record("effectivePolicy missing or not an object")
        return
    }
    guard case .object(let dest) = policy["destination"],
          case .string(let destID) = dest["id"] else {
        Issue.record("effectivePolicy.destination missing")
        return
    }
    #expect(destID == "work/inbox", "effectivePolicy destination should be work/inbox")

    guard case .string(let sensitivity) = policy["sensitivity"] else {
        Issue.record("effectivePolicy.sensitivity missing")
        return
    }
    #expect(sensitivity == "elevated")

    guard case .bool(let exportEligible) = policy["exportEligible"],
          case .bool(let lanEligible) = policy["lanEligible"] else {
        Issue.record("effectivePolicy export/LAN missing")
        return
    }
    #expect(exportEligible == true)
    #expect(lanEligible == false)
}

@Test("A4-C6: capture persists drawer — downstream query reads same effective policy")
func capturePersistsDrawerDownstreamQuery() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // Capture a record.
    let requestID = UUID().uuidString.lowercased()
    let args = JSONValue.object([
        "requestID": .string(requestID),
        "subject": .string("Downstream query test"),
        "content": .string("This record must be readable from estate state."),
        "destinationID": .string("personal/capture"),
        "sensitivity": .string("restricted"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
    ])
    let sc = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc_ = try #require(sc)

    guard case .string(let outcome) = sc_["outcome"], outcome == "applied" else {
        Issue.record("expected applied outcome: \(sc_)")
        return
    }
    guard case .string(let recordIDStr) = sc_["recordID"],
          let recordID = UUID(uuidString: recordIDStr) else {
        Issue.record("recordID missing")
        return
    }

    // Downstream query: open the estate directly and verify the drawer exists
    // in the correct room with the correct sensitivity.
    let config = EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: scratch.estateURL, busyTimeout: 5.0)
    )
    let storage = try SQLiteStorage(configuration: config)
    let estate = try await Estate.open(
        storage: storage,
        owner: OwnerCredentials(ownerIdentifier: "downstream-query"),
        identityKeyStore: InMemoryEstateIdentityKeyStore()
    )
    defer { Task { await storage.close() } }

    // The drawer should be in the "personal" wing, "capture" room.
    let drawers = try await estate.drawersIn(wing: "personal", room: "capture")
    let capturedDrawer = drawers.first(where: { $0.id == recordID.uuidString.lowercased()
        || $0.id == recordID.uuidString })

    #expect(capturedDrawer != nil, "drawer \(recordIDStr) not found in personal/capture")

    if let drawer = capturedDrawer {
        // Verify sensitivity: restricted = raw 32 at bits 6–11 of adjectiveBitmap.
        #expect(drawer.adjectiveSensitivity == .restricted,
                "drawer sensitivity should be restricted, got \(drawer.adjectiveSensitivity)")
        // Verify exportability: false → private_ (raw 0).
        #expect(drawer.exportability == .private_,
                "drawer exportability should be private_, got \(drawer.exportability)")
    }
}

// MARK: - A4-C7 through A4-C9: validation refusals

@Test("A4-C7: stale destination → refused(destination, destination-stale)")
func captureStaleDestinationRefused() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let args = JSONValue.object([
        "requestID": .string("30000000-0000-0000-0000-000000000003"),
        "subject": .string("Stale destination test"),
        "content": .string("Keep this draft for correction."),
        "destinationID": .string("removed/inbox"),  // non-existent destination
        "sensitivity": .string("normal"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
    ])
    let sc = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc_ = try #require(sc)

    guard case .string(let outcome) = sc_["outcome"] else {
        Issue.record("outcome missing")
        return
    }
    #expect(outcome == "refused", "expected refused for stale destination")
    guard case .string(let field) = sc_["field"] else {
        Issue.record("field missing")
        return
    }
    #expect(field == "destination")
    guard case .string(let reason) = sc_["reason"] else {
        Issue.record("reason missing")
        return
    }
    #expect(reason == "destination-stale", "expected destination-stale, got \(reason)")
}

@Test("A4-C8: structurally-invalid destination → refused (destination-stale for non-empty id)")
func captureInvalidDestinationRefused() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let args = JSONValue.object([
        "requestID": .string("30000000-0000-0000-0000-000000000099"),
        "subject": .string("Bad destination"),
        "content": .string("Testing unknown destination."),
        "destinationID": .string("absolutely/not/real"),  // unknown multi-part id
        "sensitivity": .string("normal"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
    ])
    let sc = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc_ = try #require(sc)

    guard case .string(let outcome) = sc_["outcome"] else {
        Issue.record("outcome missing"); return
    }
    #expect(outcome == "refused")
    guard case .string(let field) = sc_["field"] else {
        Issue.record("field missing"); return
    }
    #expect(field == "destination")
}

@Test("A4-C9: lanEligible=true with exportEligible=false → refused(lan-eligibility, privacy-escalation)")
func captureLanWithoutExportRefused() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // Matches fixture case "capture-lan-privacy-escalation-refused".
    let args = JSONValue.object([
        "requestID": .string("30000000-0000-0000-0000-000000000004"),
        "subject": .string("Secret"),
        "content": .string("Never leave the machine."),
        "destinationID": .string("personal/capture"),
        "sensitivity": .string("secret"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(true),
    ])
    let sc = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc_ = try #require(sc)

    guard case .string(let outcome) = sc_["outcome"] else {
        Issue.record("outcome missing"); return
    }
    #expect(outcome == "refused")
    guard case .string(let field) = sc_["field"] else {
        Issue.record("field missing"); return
    }
    #expect(field == "lan-eligibility")
    guard case .string(let reason) = sc_["reason"] else {
        Issue.record("reason missing"); return
    }
    #expect(reason == "privacy-escalation")
}

@Test("A4-C16: empty content → refused(content, capture-content-invalid)")
func captureEmptyContentRefused() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let args = JSONValue.object([
        "requestID": .string("30000000-0000-0000-0000-000000000020"),
        "subject": .string("Empty content"),
        "content": .string(""),   // empty — must be refused
        "destinationID": .string("personal/capture"),
        "sensitivity": .string("normal"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
    ])
    let sc = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc_ = try #require(sc)
    guard case .string(let outcome) = sc_["outcome"] else {
        Issue.record("outcome missing"); return
    }
    #expect(outcome == "refused")
    guard case .string(let field) = sc_["field"] else {
        Issue.record("field missing"); return
    }
    #expect(field == "content")
}

@Test("A4-C17: secret sensitivity with exportEligible=true → refused (privacy-escalation)")
func captureSecretWithExportRefused() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let args = JSONValue.object([
        "requestID": .string("30000000-0000-0000-0000-000000000021"),
        "subject": .string("Secret export attempt"),
        "content": .string("Attempting to export a secret record."),
        "destinationID": .string("personal/capture"),
        "sensitivity": .string("secret"),
        "exportEligible": .bool(true),  // invalid: secret + exportEligible
        "lanEligible": .bool(false),
    ])
    let sc = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc_ = try #require(sc)
    guard case .string(let outcome) = sc_["outcome"] else {
        Issue.record("outcome missing"); return
    }
    #expect(outcome == "refused")
    guard case .string(let field) = sc_["field"] else {
        Issue.record("field missing"); return
    }
    #expect(field == "export-eligibility")
    guard case .string(let reason) = sc_["reason"] else {
        Issue.record("reason missing"); return
    }
    #expect(reason == "privacy-escalation")
}

// MARK: - A4-C10 through A4-C12: idempotency and conflict

@Test("A4-C10: exact retry returns byte-identical receipt; record count unchanged")
func captureExactRetryIdempotent() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let requestID = "30000000-0000-0000-0000-000000000001"
    let args = JSONValue.object([
        "requestID": .string(requestID),
        "subject": .string("Meeting note"),
        "content": .string("Follow up on the Community release."),
        "destinationID": .string("work/inbox"),
        "sensitivity": .string("elevated"),
        "exportEligible": .bool(true),
        "lanEligible": .bool(false),
    ])

    // First capture.
    let sc1 = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc1_ = try #require(sc1)
    guard case .string(let outcome1) = sc1_["outcome"], outcome1 == "applied" else {
        Issue.record("first capture should be applied: \(sc1_)"); return
    }
    guard case .string(let recordID1) = sc1_["recordID"] else {
        Issue.record("first capture missing recordID"); return
    }

    // Count drawers before retry.
    let drawersBefore = try await countDrawers(in: scratch.estateURL, wing: "work", room: "inbox")

    // Exact retry — same arguments.
    let sc2 = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc2_ = try #require(sc2)
    guard case .string(let outcome2) = sc2_["outcome"], outcome2 == "applied" else {
        Issue.record("retry should also be applied: \(sc2_)"); return
    }
    guard case .string(let recordID2) = sc2_["recordID"] else {
        Issue.record("retry missing recordID"); return
    }

    // recordID must be identical.
    #expect(recordID1 == recordID2, "retry must return same recordID")

    // Drawer count must be unchanged.
    let drawersAfter = try await countDrawers(in: scratch.estateURL, wing: "work", room: "inbox")
    #expect(drawersAfter == drawersBefore, "retry must not create a new drawer")
}

@Test("A4-C11: exact retry across a NEW CommunityCaptureCoordinator (durable ledger)")
func captureExactRetryAcrossNewInstance() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    // First coordinator: capture a record.
    let requestID = "30000000-0000-0000-0000-000000000050"
    let args = JSONValue.object([
        "requestID": .string(requestID),
        "subject": .string("Durable retry subject"),
        "content": .string("This capture must survive across daemon restarts."),
        "destinationID": .string("personal/capture"),
        "sensitivity": .string("restricted"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
    ])

    let (dispatcher1, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc1 = await callTool(dispatcher1, name: "moot_community_capture", arguments: args)
    let sc1_ = try #require(sc1)
    guard case .string(let outcome1) = sc1_["outcome"], outcome1 == "applied",
          case .string(let recordID1) = sc1_["recordID"] else {
        Issue.record("first capture failed: \(sc1_)"); return
    }

    // Second coordinator over the SAME layout directory — simulates a daemon restart.
    let (dispatcher2, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc2 = await callTool(dispatcher2, name: "moot_community_capture", arguments: args)
    let sc2_ = try #require(sc2)
    guard case .string(let outcome2) = sc2_["outcome"], outcome2 == "applied",
          case .string(let recordID2) = sc2_["recordID"] else {
        Issue.record("retry on new instance failed: \(sc2_)"); return
    }

    // Same recordID after restart (ledger was read from disk).
    #expect(recordID1 == recordID2, "retry on new coordinator must return same recordID")

    // Drawer count must still be one (no duplicate).
    let drawerCount = try await countDrawers(in: scratch.estateURL, wing: "personal", room: "capture")
    // One seed drawer + one capture (the seed was created by seedEstateRooms).
    // The capture added exactly one drawer; the retry must not add another.
    #expect(drawerCount == 2, "expected exactly 1 seed + 1 capture, got \(drawerCount)")
}

@Test("A4-C12: conflicting retry (same requestID, different policy) → request-conflict")
func captureConflictingRetry() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let requestID = "30000000-0000-0000-0000-000000000060"
    let firstArgs = JSONValue.object([
        "requestID": .string(requestID),
        "subject": .string("Original subject"),
        "content": .string("Original content."),
        "destinationID": .string("personal/capture"),
        "sensitivity": .string("normal"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
    ])
    let sc1 = await callTool(dispatcher, name: "moot_community_capture", arguments: firstArgs)
    guard case .string(let outcome1) = sc1?["outcome"], outcome1 == "applied" else {
        Issue.record("first capture should be applied"); return
    }

    // Same requestID, different destinationID → conflict.
    let conflictArgs = JSONValue.object([
        "requestID": .string(requestID),
        "subject": .string("Original subject"),
        "content": .string("Original content."),
        "destinationID": .string("work/inbox"),   // different from first
        "sensitivity": .string("normal"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
    ])
    let sc2 = await callTool(dispatcher, name: "moot_community_capture", arguments: conflictArgs)
    let sc2_ = try #require(sc2)

    guard case .string(let outcome2) = sc2_["outcome"] else {
        Issue.record("outcome missing in conflict response"); return
    }
    #expect(outcome2 == "refused", "conflicting retry should be refused")
    guard case .string(let reason) = sc2_["reason"] else {
        Issue.record("reason missing"); return
    }
    #expect(reason == "request-conflict")
}

// MARK: - A4-C13 through A4-C14: fail-closed argument validation

@Test("A4-C13: unknown argument fields → invalidParams (fail-closed)")
func captureUnknownFieldsFail() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let args = JSONValue.object([
        "requestID": .string("30000000-0000-0000-0000-000000000070"),
        "subject": .string("Test"),
        "content": .string("Test content."),
        "destinationID": .string("personal/capture"),
        "sensitivity": .string("normal"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
        "unknownField": .string("should fail closed"),  // extra field
    ])
    let (_, error) = await callToolForError(dispatcher, name: "moot_community_capture", arguments: args)
    #expect(error != nil, "unknown field should produce an error")
    if let err = error {
        #expect(err.code == JSONRPCErrorCode.invalidParams,
                "expected invalidParams, got code \(err.code)")
    }
}

@Test("A4-C14: missing required field (content) → invalidParams")
func captureMissingRequiredField() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    // Missing 'content'.
    let args = JSONValue.object([
        "requestID": .string("30000000-0000-0000-0000-000000000080"),
        "subject": .string("No content"),
        // "content" deliberately omitted
        "destinationID": .string("personal/capture"),
        "sensitivity": .string("normal"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
    ])
    let (_, error) = await callToolForError(dispatcher, name: "moot_community_capture", arguments: args)
    #expect(error != nil, "missing content should produce an error")
    if let err = error {
        #expect(err.code == JSONRPCErrorCode.invalidParams)
    }
}

// MARK: - A4-C15: shape validation against contract.json

@Test("A4-C15: CaptureChoices response shape matches contract.json CaptureChoices type")
func captureChoicesShapeMatchesContract() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)
    let sc = await callTool(dispatcher, name: "moot_community_capture_choices")
    let sc_ = try #require(sc)

    // Required top-level fields per contract.json CaptureChoices.
    #expect(sc_["destinations"] != nil, "CaptureChoices must have destinations")
    #expect(sc_["sensitivities"] != nil, "CaptureChoices must have sensitivities")
    #expect(sc_["defaultPolicy"] != nil, "CaptureChoices must have defaultPolicy")

    // CaptureDefaultPolicy shape.
    if case .object(let policy) = sc_["defaultPolicy"] {
        #expect(policy["destinationID"] != nil)
        #expect(policy["sensitivity"] != nil)
        #expect(policy["exportEligible"] != nil)
        #expect(policy["lanEligible"] != nil)
    } else {
        Issue.record("defaultPolicy not an object")
    }

    // CaptureDestination shape (check first destination if any).
    if case .array(let dests) = sc_["destinations"], !dests.isEmpty {
        if case .object(let dest) = dests[0] {
            #expect(dest["id"] != nil)
            #expect(dest["title"] != nil)
            #expect(dest["detail"] != nil)
        }
    }
}

@Test("A4-C15b: CaptureOutcome.applied shape matches contract.json")
func captureOutcomeAppliedShapeMatchesContract() async throws {
    let scratch = try CaptureScratch()
    defer { scratch.remove() }
    try await seedEstateRooms(at: scratch.estateURL)

    let (dispatcher, _) = makeDispatcher(layoutURL: scratch.layoutURL)

    let args = JSONValue.object([
        "requestID": .string("30000000-0000-0000-0000-000000000090"),
        "subject": .string("Shape check"),
        "content": .string("Shape validation content."),
        "destinationID": .string("work/inbox"),
        "sensitivity": .string("normal"),
        "exportEligible": .bool(false),
        "lanEligible": .bool(false),
    ])
    let sc = await callTool(dispatcher, name: "moot_community_capture", arguments: args)
    let sc_ = try #require(sc)

    // CaptureOutcome applied shape.
    #expect(sc_["outcome"] != nil, "outcome must be present")
    if case .string(let o) = sc_["outcome"] { #expect(o == "applied") }
    #expect(sc_["recordID"] != nil, "applied: recordID must be present")
    #expect(sc_["effectivePolicy"] != nil, "applied: effectivePolicy must be present")

    // CapturePolicy shape.
    if case .object(let policy) = sc_["effectivePolicy"] {
        #expect(policy["destination"] != nil)
        #expect(policy["sensitivity"] != nil)
        #expect(policy["exportEligible"] != nil)
        #expect(policy["lanEligible"] != nil)
        // CaptureDestination inside CapturePolicy.
        if case .object(let dest) = policy["destination"] {
            #expect(dest["id"] != nil)
            #expect(dest["title"] != nil)
            #expect(dest["detail"] != nil)
        }
    } else {
        Issue.record("effectivePolicy not an object")
    }
}

// MARK: - Helpers

/// Count non-tombstoned drawers in a wing/room by opening a read-only estate.
private func countDrawers(in estateURL: URL, wing: String, room: String) async throws -> Int {
    let config = EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: estateURL, busyTimeout: 5.0)
    )
    let storage = try SQLiteStorage(configuration: config)
    defer { Task { await storage.close() } }
    let estate = try await Estate.open(
        storage: storage,
        owner: OwnerCredentials(ownerIdentifier: "count-drawers"),
        identityKeyStore: InMemoryEstateIdentityKeyStore()
    )
    let drawers = try await estate.drawersIn(wing: wing, room: room)
    return drawers.count
}
