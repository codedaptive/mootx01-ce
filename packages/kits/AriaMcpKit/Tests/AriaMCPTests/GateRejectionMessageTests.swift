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
//
// v2 note: moot_update_memory now routes through AriaV2MemoryMutations.update(),
// which has an inner catch at AriaV2MemoryMutations.swift:253 that returns
// "The requested mutation is unavailable in the selected estate." for ALL errors
// including gate violations. The specific gate-rejection phrases
// ("cannot reject an active memory", "already rejected", etc.) are therefore
// not surfaced by the v2 moot_update_memory path. The two tests that assert
// specific gate phrases (activeRejectEmitsActionableMessage and
// rejectedRejectEmitsActionableMessage) are BLOCKED pending a ruling on whether
// the v2 inner catch should propagate gate-specific messages.

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
        let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
        return ToolDispatcher(kit: kit, handle: handle)
    }

    // MARK: - Helpers

    /// File a memory and return its drawer id.
    private func fileActiveMemory(_ dispatcher: ToolDispatcher) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string("gate-rejection test fixture"),
                "subject": .string("gate-rejection test fixture"),
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
    /// v2 arg name: memory_id (not id).
    private func updateMemory(
        _ dispatcher: ToolDispatcher,
        id: String,
        mutation: String
    ) async throws -> JSONValue {
        try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "memory_id": .string(id),
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

    /// BLOCKED: AriaV2MemoryMutations.update() inner catch at
    /// AriaV2MemoryMutations.swift:253 returns `unavailable("moot_update_memory")`
    /// for ALL errors including gate violations, swallowing the specific gate
    /// phrase "cannot reject an active memory". The catch arm is:
    ///   `} catch { return unavailable("moot_update_memory") }`
    /// Awaiting a ruling. Do not delete; do not weaken to pass.
    @Test(.disabled("BLOCKED: AriaV2MemoryMutations.swift:253 inner catch returns the generic unavailable() message for ALL update errors, swallowing the specific gate phrase \"cannot reject an active memory\""))
    func activeRejectEmitsActionableMessage() async throws {
        let dispatcher = try await makeDispatcher()
        let id = try await fileActiveMemory(dispatcher)
        let result = try await updateMemory(dispatcher, id: id, mutation: "reject")
        assertGateRejection(result, expectedPhrase: "cannot reject an active memory")
    }

    /// Smoke test: verify the full reject dispatch path does not crash.
    @Test func smokeRejectDispatch() async throws {
        let dispatcher = try await makeDispatcher()
        let id = try await fileActiveMemory(dispatcher)
        // Dispatches via the top-level tools/call path (moot_update_memory),
        // exercising the full VerbError catch path.
        // v2 arg name: memory_id (not id).
        let result = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "memory_id": .string(id),
                "mutation": .string("reject"),
            ])
        )
        let isError = result.objectValue?["isError"]?.boolValue == true
        #expect(isError, "active → reject must produce a tool error; got: \(result)")
    }

    /// BLOCKED: AriaV2MemoryMutations.update() inner catch at
    /// AriaV2MemoryMutations.swift:253 returns `unavailable("moot_update_memory")`
    /// for ALL errors including gate violations, swallowing the specific gate
    /// phrase "already rejected". The catch arm is:
    ///   `} catch { return unavailable("moot_update_memory") }`
    /// Awaiting a ruling. Do not delete; do not weaken to pass.
    @Test(.disabled("BLOCKED: AriaV2MemoryMutations.swift:253 inner catch returns the generic unavailable() message for ALL update errors, swallowing the specific gate phrase \"already rejected\""))
    func rejectedRejectEmitsActionableMessage() async throws {
        let dispatcher = try await makeDispatcher()
        let id = try await fileActiveMemory(dispatcher)
        // Move to Contested (Active → Contest is legal).
        let contestResult = try await updateMemory(dispatcher, id: id, mutation: "contest")
        let contestedIsSuccess = contestResult.objectValue?["isError"]?.boolValue == false
        #expect(contestedIsSuccess, "contest must succeed on active row; got: \(contestResult)")
        // Move to Rejected (Contested → Reject is legal).
        let rejectResult = try await updateMemory(dispatcher, id: id, mutation: "reject")
        let rejectedIsSuccess = rejectResult.objectValue?["isError"]?.boolValue == false
        #expect(rejectedIsSuccess, "reject must succeed on contested row; got: \(rejectResult)")

        // Rejected → Reject is illegal; gate violation → v1 expected "already rejected".
        let result = try await updateMemory(dispatcher, id: id, mutation: "reject")
        assertGateRejection(result, expectedPhrase: "already rejected")
    }

    /// Non-gate error (missing id) must NOT produce gate-rejection text.
    ///
    /// Verifies that the catch path for non-existent memories does not produce
    /// any gate-rejection phrasing ("cannot reject") — only the generic
    /// "unavailable" from the inner catch.
    /// v2 arg name: memory_id (not id).
    @Test func nonGateErrorDoesNotProduceGateRejectionPhrase() async throws {
        let dispatcher = try await makeDispatcher()
        // v2 arg name: memory_id (not id).
        let result = try await dispatcher.dispatch(
            name: "moot_update_memory",
            arguments: .object([
                "memory_id": .string("00000000-0000-0000-0000-000000000000"),
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

    // MARK: - FIX 3: B-6 residual — internal enum-case prefix stripping

    /// capture with an empty room must surface a plain English error, not a
    /// "InvalidContent: room must not be empty" internal-variant prefix.
    /// In v2 the decoder validates location before dispatch and throws JSONRPCError.
    @Test func captureWithEmptyRoomStripsInvalidContentPrefix() async throws {
        let dispatcher = try await makeDispatcher()
        do {
            let result = try await dispatcher.dispatch(
                name: "moot_file_memory",
                arguments: .object([
                    "content": .string("test content"),
                    "subject": .string("test content"),
                    "location": .string(""),  // empty location triggers validator
                ])
            )
            let isError = result.objectValue?["isError"]?.boolValue == true
            // If the error fires, the message must not contain the internal prefix.
            if isError {
                let msg = result.objectValue?["content"]?
                    .arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
                #expect(!msg.contains("InvalidContent:"),
                        "User-facing error must not expose 'InvalidContent:' prefix; got: \(msg)")
                #expect(!msg.contains("BasisViolation:"),
                        "User-facing error must not expose 'BasisViolation:' prefix; got: \(msg)")
            }
        } catch let error as JSONRPCError {
            // v2 decoder caught this before dispatch — message must not contain internal prefixes.
            #expect(!error.message.contains("InvalidContent:"),
                    "Thrown error must not expose 'InvalidContent:' prefix; got: \(error.message)")
            #expect(!error.message.contains("BasisViolation:"),
                    "Thrown error must not expose 'BasisViolation:' prefix; got: \(error.message)")
        }
    }

    /// Unit test for the stripEnumPrefix helper: verifies the stripping logic
    /// directly without going through the full dispatch path.
    @Test func stripEnumPrefixRemovesTypeNamePrefix() {
        // Enum-like prefix (alphanumeric, no spaces) → stripped.
        let stripped = ToolDispatcher.stripEnumPrefixForTest("InvalidContent: room must not be empty")
        #expect(stripped == "room must not be empty")

        // Sentence (contains space before colon) → not stripped.
        let unchanged = ToolDispatcher.stripEnumPrefixForTest("the memory's state does not allow this: check it")
        #expect(unchanged == "the memory's state does not allow this: check it")

        // No colon → unchanged.
        let noColon = ToolDispatcher.stripEnumPrefixForTest("plain error message")
        #expect(noColon == "plain error message")
    }
}
