import Testing
import Foundation
@testable import MootGateway
import MootIntentKit
import AriaMCP

private actor PartialReviveCaller: MootToolCalling {
    private var failuresRemaining: Set<String>
    private var attemptedIDs: [String] = []

    init(failOnceFor id: String) {
        failuresRemaining = [id]
    }

    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult {
        guard name == "moot_update_memory",
              case .string(let id)? = arguments["id"],
              case .string("revive")? = arguments["mutation"] else {
            return IntentCallResult(text: "unexpected call", isError: true)
        }
        attemptedIDs.append(id)
        if failuresRemaining.remove(id) != nil {
            return IntentCallResult(text: "temporary refusal", isError: true)
        }
        return IntentCallResult(text: "revived", isError: false)
    }

    func attempts() -> [String] {
        attemptedIDs
    }
}

// M-MXA-2R — batch curation against a live in-memory estate.
//
// Host constraint: this machine runs macOS 26 with the Xcode 27 SDK, so
// 2027-wave AppIntents symbols (EntityCollection) exist at compile time but
// not in the OS runtime — a test binary referencing them fails at dlopen.
// The batch intents are therefore split: identifier-only execution loops in
// BatchCurationCore (exercised HERE, on this host) and the thin
// EntityCollection-typed system surface (runtime-verified on an OS-27
// runtime via the M-MXA-4 AppIntentsTesting lane). The undo intent uses no
// 27-wave API, so the real intent runs in this suite.
//
// Charter checks encoded here:
//   - batch mutate + batch withdraw round-trip through the real tool surface
//   - undo (revive) restores withdrawn drawers; single-slot semantics
//   - NO batch expunge exists (there is no such type or core function)

@Suite("Batch curation (M-MXA-2R)", .serialized)
struct BatchCurationTests {

    /// Capture N fixture drawers, returning their ids. `subject` is mandatory
    /// on moot_file_memory (PR-02 capture contract).
    private func captureFixtures(_ bridge: MootBridge, count: Int) async throws -> [String] {
        for i in 0..<count {
            _ = await bridge.callToolFull("moot_file_memory", arguments: [
                "content": .string("batch fixture drawer \(i) badger"),
                "subject": .string("Batch fixture drawer \(i) exercises curation with the badger token."),
                "location": .string("batch-tests"),
                "impatient": .bool(true),
            ])
        }
        let search = await bridge.callToolFull("moot_memory_search", arguments: [
            "query": .string("badger"),
            "limit": .integer(Int64(count + 5)),
        ])
        let ids = StructuredRecallResults.entities(from: search.structured).map(\.id)
        try #require(ids.count == count)
        return ids
    }

    /// A withdrawn drawer fails moot_memory_get's active-only gate; an active
    /// one reads back. That gate IS the observable state for this suite.
    private func isActive(_ bridge: MootBridge, id: String) async -> Bool {
        let get = await bridge.callToolFull("moot_memory_get", arguments: ["id": .string(id)])
        return !get.isError && !get.text.contains("not found")
    }

    @Test("batch withdraw retires every drawer; undo revives them (single slot)")
    @MainActor
    func batchWithdrawThenUndo() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let ids = try await captureFixtures(bridge, count: 3)
        BatchWithdrawLedger.shared.clear()

        let outcome = await BatchCurationCore.withdraw(ids: ids, reason: "test batch", caller: bridge)
        #expect(outcome.succeeded.count == 3)
        #expect(outcome.failed.isEmpty)
        for id in ids {
            #expect(await isActive(bridge, id: id) == false, "drawer \(id) still active after withdraw")
        }
        #expect(BatchWithdrawLedger.shared.peek() == ids)

        // Undo through the REAL intent — no 27-wave API on this path.
        _ = try await UndoLastBatchWithdrawIntent(caller: bridge).perform()
        for id in ids {
            #expect(await isActive(bridge, id: id), "drawer \(id) not revived by undo")
        }

        // Single-slot: a successful undo clears the ledger; a second undo is a no-op.
        #expect(BatchWithdrawLedger.shared.peek() == nil)
        _ = try await UndoLastBatchWithdrawIntent(caller: bridge).perform()
    }

    @Test("batch mutate confirms every drawer through the identifier-only loop")
    func batchMutateConfirms() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let ids = try await captureFixtures(bridge, count: 2)

        let outcome = await BatchCurationCore.mutate(ids: ids, mutation: "confirm", caller: bridge)
        #expect(outcome.succeeded.count == 2)
        #expect(outcome.failed.isEmpty)

        for id in ids {
            let get = await bridge.callToolFull("moot_memory_get", arguments: ["id": .string(id)])
            #expect(get.text.contains("confirmation: userConfirmed"),
                    "drawer \(id) not user-confirmed after batch mutate")
        }
    }

    @Test("failed ids are reported and excluded from the undo ledger")
    func failedIdsExcludedFromLedger() async throws {
        let bridge = try await MootBridge.attachInMemory()
        let ids = try await captureFixtures(bridge, count: 1)
        BatchWithdrawLedger.shared.clear()

        let bogus = "00000000-0000-0000-0000-000000000000"
        let outcome = await BatchCurationCore.withdraw(
            ids: [ids[0], bogus], reason: nil, caller: bridge
        )
        #expect(outcome.succeeded == [ids[0]])
        #expect(outcome.failed == [bogus])
        // Undo must only revive what actually withdrew.
        #expect(BatchWithdrawLedger.shared.peek() == [ids[0]])
        BatchWithdrawLedger.shared.clear()
    }

    @Test("empty withdraw batch never overwrites a revertible ledger slot")
    func ledgerIgnoresEmptyBatches() {
        BatchWithdrawLedger.shared.clear()
        BatchWithdrawLedger.shared.record(["a", "b"])
        BatchWithdrawLedger.shared.record([])
        #expect(BatchWithdrawLedger.shared.peek() == ["a", "b"])
        BatchWithdrawLedger.shared.clear()
        #expect(BatchWithdrawLedger.shared.peek() == nil)
    }

    @Test("partial undo retries only the drawers that failed to revive")
    @MainActor
    func partialUndoRetainsOnlyFailures() async throws {
        let first = "11111111-1111-1111-1111-111111111111"
        let retry = "22222222-2222-2222-2222-222222222222"
        let caller = PartialReviveCaller(failOnceFor: retry)
        BatchWithdrawLedger.shared.clear()
        BatchWithdrawLedger.shared.record([first, retry])

        _ = try await UndoLastBatchWithdrawIntent(caller: caller).perform()
        #expect(BatchWithdrawLedger.shared.peek() == [retry])

        _ = try await UndoLastBatchWithdrawIntent(caller: caller).perform()
        #expect(BatchWithdrawLedger.shared.peek() == nil)
        #expect(await caller.attempts() == [first, retry, retry])
    }
}
