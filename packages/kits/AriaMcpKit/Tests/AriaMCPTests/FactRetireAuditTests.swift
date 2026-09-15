// FactRetireAuditTests.swift
//
// Gate tests that prove `moot_retire_fact` wires `changedBy` and `reason`
// into the `_storagekit_audit` row.
//
// Every test drives the FULL dispatch chain:
//   ToolDispatcher.dispatch(name: "moot_retire_fact", ...) → retireFact →
//   kit.retireKGFact → DrawerStore.withdrawKGFact → _storagekit_audit row.
//
// Three assertions on the single audit event that must exist:
//   1. verb == "retract"       — correct verb from withdrawKGFact
//   2. actor == server identity — changedBy is now context.serverIdentity
//   3. reason == caller reason  — reason is now forwarded from the request
//
// Each assertion stands alone, so a failure names the field that moved:
// the actor case also asserts the value is NOT the old hardcoded literal
// "aria-v2-retire-fact", and a third test covers an omitted reason.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateTypes
@testable import AriaMCP

// ---------------------------------------------------------------------------
// MARK: - Shared helpers
// ---------------------------------------------------------------------------

/// Extract the `structuredContent.data` dictionary from a dispatch result.
private func data(_ result: JSONValue) -> [String: JSONValue]? {
    result.objectValue?["structuredContent"]?.objectValue?["data"]?.objectValue
}

/// Open a bare in-memory estate for audit tests.
/// Returns the dispatcher, kit, and handle so the test can query audit rows.
private func openBareEstate(identity: String = "aria-mcp-server")
    async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle)
{
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "fact-retire-audit-tests")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(
        storage: storage,
        owner: owner,
        identityKeyStore: InMemoryEstateIdentityKeyStore())
    let dispatcher = ToolDispatcher(kit: kit, handle: handle, serverIdentity: identity)
    return (dispatcher, kit, handle)
}

// ---------------------------------------------------------------------------
// MARK: - Test suite
// ---------------------------------------------------------------------------

@Suite("moot_retire_fact audit wiring — changedBy and reason forwarded to _storagekit_audit")
struct FactRetireAuditTests {

    // -----------------------------------------------------------------------
    // Test 1: reason forwarded
    // -----------------------------------------------------------------------

    /// Retire a fact with reason="audit-reason-a". The audit row must carry
    /// that exact reason string. Before the fix, reason was always nil.
    @Test("moot_retire_fact: audit row carries the caller-supplied reason")
    func retireFactAuditRowCarriesReason() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate()

        // File a fact first.
        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_fact",
            arguments: .object([
                "subject":   .string("Galileo"),
                "predicate": .string("discovered"),
                "object":    .string("Jupiter's moons"),
            ]))
        let factIDStr = try #require(data(fileResult)?["fact_id"]?.stringValue)

        // Retire with an explicit reason.
        let retireResult = try await dispatcher.dispatch(
            name: "moot_retire_fact",
            arguments: .object([
                "fact_id": .string(factIDStr),
                "reason":  .string("audit-reason-a"),
            ]))
        let retiredData = try #require(data(retireResult))
        #expect(retiredData["fact_id"]?.stringValue == factIDStr,
                "moot_retire_fact must echo the fact_id in structuredContent.data")

        // Read the audit trail and check the single row.
        let events = try await kit.auditTrail(in: handle, rowID: factIDStr)
        #expect(events.count == 1, "exactly one audit event for a single retirement")
        let ev = try #require(events.first)
        #expect(ev.verb == "retract",    "audit verb must be 'retract'")
        #expect(ev.reason == "audit-reason-a",
                "audit reason must match the caller-supplied value; got \(ev.reason as Any)")
    }

    // -----------------------------------------------------------------------
    // Test 2: actor is server identity, not the old constant
    // -----------------------------------------------------------------------

    /// The audit actor must equal the serverIdentity injected at dispatcher
    /// construction, not the old hard-coded constant "aria-v2-retire-fact".
    @Test("moot_retire_fact: audit actor equals serverIdentity, not 'aria-v2-retire-fact'")
    func retireFactAuditActorEqualsServerIdentity() async throws {
        let serverID = "test-mootx01-host"
        let (dispatcher, kit, handle) = try await openBareEstate(identity: serverID)

        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_fact",
            arguments: .object([
                "subject":   .string("Copernicus"),
                "predicate": .string("proposed"),
                "object":    .string("heliocentrism"),
            ]))
        let factIDStr = try #require(data(fileResult)?["fact_id"]?.stringValue)

        _ = try await dispatcher.dispatch(
            name: "moot_retire_fact",
            arguments: .object([
                "fact_id": .string(factIDStr),
                "reason":  .string("audit-reason-b"),
            ]))

        let events = try await kit.auditTrail(in: handle, rowID: factIDStr)
        #expect(events.count == 1)
        let ev = try #require(events.first)
        #expect(ev.actor == serverID,
                "audit actor must be serverIdentity '\(serverID)'; got '\(ev.actor)'")
        #expect(ev.actor != "aria-v2-retire-fact",
                "old hard-coded constant must NOT appear as audit actor")
    }

    // -----------------------------------------------------------------------
    // Test 3: nil reason when no reason is supplied
    // -----------------------------------------------------------------------

    /// When the caller omits reason, the audit row reason must be nil (not a
    /// non-nil value from a forgotten forwarding bug).
    @Test("moot_retire_fact: audit reason is nil when no reason supplied")
    func retireFactAuditReasonIsNilWhenOmitted() async throws {
        let (dispatcher, kit, handle) = try await openBareEstate()

        let fileResult = try await dispatcher.dispatch(
            name: "moot_file_fact",
            arguments: .object([
                "subject":   .string("Newton"),
                "predicate": .string("formulated"),
                "object":    .string("gravity"),
            ]))
        let factIDStr = try #require(data(fileResult)?["fact_id"]?.stringValue)

        // Retire without a reason.
        _ = try await dispatcher.dispatch(
            name: "moot_retire_fact",
            arguments: .object([
                "fact_id": .string(factIDStr),
            ]))

        let events = try await kit.auditTrail(in: handle, rowID: factIDStr)
        #expect(events.count == 1)
        let ev = try #require(events.first)
        #expect(ev.verb == "retract")
        #expect(ev.reason == nil,
                "audit reason must be nil when no reason is supplied; got \(ev.reason as Any)")
    }
}
