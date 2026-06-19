// GateRejectionMessageTests.swift
//
// Wave D — illegal-state-transition error message parity (Swift leg).
//
// Verifies that moot_update_memory returns actionable English messages
// (not Swift type-chain strings like "GateViolation.basisViolation(...)") when
// the mutation is rejected by the gate automaton. Each test triggers a specific
// illegal transition from the message table and asserts:
//   1. The result has isError == true.
//   2. The message contains NO Swift type name (basisViolation, illegalTransition,
//      GateViolation, LocusKitError, InvalidContent in the user-visible sense).
//   3. The message contains the expected actionable English phrase.
//
// Parity requirement: the exact same phrases must appear in the Rust
// describe_gate_rejection helper in AriaMcpKit/rust/src/interface_tools.rs.

import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Gate-rejection error messages — Wave D parity", .serialized)
struct GateRejectionMessageTests {

    // MARK: - Estate fixture

    /// Build a ToolDispatcher wired to a fresh in-memory estate.
    private func makeDispatcher() async throws -> ToolDispatcher {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "gate-rejection-tests")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory)
        )
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return ToolDispatcher(kit: kit, handle: handle)
    }

    // MARK: - Helpers

    /// File a memory and return its drawer id.
    private func fileActiveMemory(_ dispatcher: ToolDispatcher) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("gate-rejection test fixture"),
                "location": .string("General"),
            ])
        )
        let text = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        let id = text.components(separatedBy: "\n").first?
            .replacingOccurrences(of: "filed memory ", with: "") ?? ""
        #expect(!id.isEmpty, "filed memory must return a non-empty id")
        return id
    }

    /// Apply a named mutation to the memory identified by `id`.
    private func updateMemory(
        _ dispatcher: ToolDispatcher,
        id: String,
        mutation: String
    ) async throws -> JSONValue {
        try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "id": .string(id),
                "mutation": .string(mutation),
            ])
        )
    }

    /// Assert that `result` is a tool-level error containing `expectedPhrase`
    /// and NOT containing any internal type names.
    private func assertGateRejection(_ result: JSONValue, expectedPhrase: String) {
        // isError must be true.
        let isError = result.objectValue?["isError"]?.boolValue == true
        #expect(isError, "expected tool-level error; got: \(result)")

        let msg = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""

        // No Swift type names.
        #expect(
            !msg.contains("basisViolation"),
            "error message must not contain 'basisViolation'; got: \(msg)"
        )
        #expect(
            !msg.contains("illegalTransition"),
            "error message must not contain 'illegalTransition'; got: \(msg)"
        )
        #expect(
            !msg.contains("GateViolation"),
            "error message must not contain 'GateViolation'; got: \(msg)"
        )
        #expect(
            !msg.contains("underlyingEstateFailure"),
            "error message must not contain 'underlyingEstateFailure'; got: \(msg)"
        )

        // Expected actionable phrase.
        #expect(
            msg.contains(expectedPhrase),
            "expected phrase '\(expectedPhrase)' in error message; got: \(msg)"
        )
    }

    // MARK: - Tests

    /// active + reject → "cannot reject an active memory; contest or withdraw it first"
    ///
    /// Active → Reject is not in the automaton transition table; the gate
    /// returns BasisViolation(IllegalTransition(Active, Reject)).
    @Test func activeRejectEmitsActionableMessage() async throws {
        let dispatcher = try await makeDispatcher()
        let id = try await fileActiveMemory(dispatcher)
        let result = try await updateMemory(dispatcher, id: id, mutation: "reject")
        assertGateRejection(result, expectedPhrase: "cannot reject an active memory")
    }

    /// Smoke test: verify the full reject dispatch path does not crash.
    @Test func smokeRejectDispatch() async throws {
        let dispatcher = try await makeDispatcher()
        let id = try await fileActiveMemory(dispatcher)
        // Use direct dispatch to run_update_memory rather than the top-level
        // dispatch which involves the full VerbError catch path.
        let result = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "id": .string(id),
                "mutation": .string("reject"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue == true
        #expect(isError, "active → reject must produce a tool error; got: \(result)")
    }

    /// rejected + reject → "memory is already rejected"
    ///
    /// A memory that is already in the Rejected state cannot be rejected again.
    /// This test drives a memory to Rejected via the now-legal Contested → Reject
    /// path (contested memories can be judged false and rejected), then attempts
    /// a second Reject and asserts the specific "already rejected" actionable
    /// message is returned with no internal Swift type names in the error text.
    @Test func rejectedRejectEmitsActionableMessage() async throws {
        let dispatcher = try await makeDispatcher()
        let id = try await fileActiveMemory(dispatcher)
        // Move to Contested (Active → Contest is legal).
        let contestResult = try await updateMemory(dispatcher, id: id, mutation: "contest")
        let contestedIsSuccess = contestResult.objectValue?["isError"]?.boolValue == false
        #expect(contestedIsSuccess, "contest must succeed on active row; got: \(contestResult)")
        // Move to Rejected (Contested → Reject is legal: contested → reject → rejected).
        let rejectResult = try await updateMemory(dispatcher, id: id, mutation: "reject")
        let rejectedIsSuccess = rejectResult.objectValue?["isError"]?.boolValue == false
        #expect(rejectedIsSuccess, "reject must succeed on contested row; got: \(rejectResult)")

        // Rejected → Reject is illegal; gate returns "memory is already rejected".
        let result = try await updateMemory(dispatcher, id: id, mutation: "reject")
        assertGateRejection(result, expectedPhrase: "already rejected")
    }

    /// Non-gate error (missing id) must NOT produce gate-rejection text.
    ///
    /// Verifies that the describeGateRejection parser correctly returns nil for
    /// errors that do not embed "illegal state transition: " and the fallback
    /// generic message is used, not a fabricated gate-rejection phrase.
    @Test func nonGateErrorDoesNotProduceGateRejectionPhrase() async throws {
        let dispatcher = try await makeDispatcher()
        let result = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "id": .string("00000000-0000-0000-0000-000000000000"),
                "mutation": .string("confirm"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue == true
        #expect(isError, "update of missing row must fail")

        let msg = result.objectValue?["content"]?
            .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        #expect(
            !msg.contains("cannot reject"),
            "non-gate error must not produce gate-rejection phrasing; got: \(msg)"
        )
    }
}
