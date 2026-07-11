import Foundation
import AppIntents
import AriaMCP   // JSONValue, for building tool arguments

// MARK: - Batch curation core  (M-MXA-2R)
//
// The identifier-only execution loops behind the batch intents, plus the
// single-slot undo ledger and the undo intent itself. Deliberately in a
// SEPARATE FILE from the EntityCollection-typed intents: EntityCollection is
// a 2027-wave API whose symbols do not exist on a macOS 26 host, and static
// linking pulls object files whole — keeping this file free of 27-only
// symbol references is what lets the in-process test suite load and verify
// the real execution paths on the current host. The EntityCollection intents
// (BatchCollectionIntents.swift) call into these same loops, so testing the
// core IS testing the intents' execution semantics.
//
// Charter boundary (Bob ruling, estate E26078CC): there is NO batch expunge,
// on any surface, under any framing. Mass deletion is out. Batch withdraw
// exists ONLY because withdraw is reversible — the substrate's `revive`
// mutation legally restores withdrawn → active (EstateVerbs cookbook §9.3) —
// and its undo ships in this same file.

public enum BatchCurationCore {

    public struct Outcome: Sendable {
        public let succeeded: [String]
        public let failed: [String]
    }

    /// Apply one named mutation to every id, one audited tool call each.
    public static func mutate(
        ids: [String], mutation: String, caller: any MootToolCalling
    ) async -> Outcome {
        var ok: [String] = []
        var bad: [String] = []
        for id in ids {
            let result = await caller.callTool("moot_update_memory", arguments: [
                "id": .string(id),
                "mutation": .string(mutation),
            ])
            if result.isError { bad.append(id) } else { ok.append(id) }
        }
        return Outcome(succeeded: ok, failed: bad)
    }

    /// Withdraw every id, then record what ACTUALLY withdrew in the undo
    /// ledger — undo must not revive drawers the batch never touched.
    public static func withdraw(
        ids: [String], reason: String?, caller: any MootToolCalling
    ) async -> Outcome {
        var ok: [String] = []
        var bad: [String] = []
        for id in ids {
            var arguments: [String: JSONValue] = ["id": .string(id)]
            if let reason, !reason.isEmpty { arguments["reason"] = .string(reason) }
            let result = await caller.callTool("moot_withdraw_memory", arguments: arguments)
            if result.isError { bad.append(id) } else { ok.append(id) }
        }
        BatchWithdrawLedger.shared.record(ok)
        return Outcome(succeeded: ok, failed: bad)
    }
}

// MARK: UndoLastBatchWithdrawIntent

/// Reverts the most recent batch withdraw by reviving each drawer
/// (substrate mutation `revive`: withdrawn → active is a legal transition).
/// Single-slot by ruling (D5: "undo last import, nothing more") — only the
/// LAST batch is revertible, and a fully successful undo clears the slot.
/// Uses no 2027-wave APIs, so it ships at the kit floor.
public struct UndoLastBatchWithdrawIntent: MootEstateIntent {
    public static let title: LocalizedStringResource = "Undo Last Withdraw"
    public static let description = IntentDescription(
        "Restore the memories withdrawn by the most recent batch withdraw.",
        categoryName: "Memory"
    )
    public static let isDiscoverable = true
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(anyAppleOS 27.0, *)
    public static let allowedExecutionTargets: IntentExecutionTargets = .main

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(caller: (any MootToolCalling)? = nil) {
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let batch = BatchWithdrawLedger.shared.peek(), !batch.isEmpty else {
            return .result(dialog: "Nothing to undo — no batch withdraw recorded.")
        }
        let c = try await resolvedCaller()
        let outcome = await BatchCurationCore.mutate(ids: batch, mutation: "revive", caller: c)
        if outcome.failed.isEmpty {
            // Fully reverted: clear the slot so a second undo is a no-op.
            BatchWithdrawLedger.shared.clear()
            return .result(dialog: IntentDialog(
                stringLiteral: "restored \(outcome.succeeded.count) memories"
            ))
        }
        // Partial revert: retry only the revivals that actually failed.
        BatchWithdrawLedger.shared.replace(with: outcome.failed)
        return .result(dialog: IntentDialog(
            stringLiteral: "restored \(outcome.succeeded.count) of \(batch.count) memories; "
                + "\(outcome.failed.count) refused: \(outcome.failed.joined(separator: ", "))"
        ))
    }

    @MainActor
    private func resolvedCaller() async throws -> any MootToolCalling {
        if let caller { return caller }
        return try await IntentRuntimeBridge.shared.bridge()
    }
}

// MARK: - BatchWithdrawLedger

/// Single-slot record of the most recent batch withdraw (Bob ruling D5:
/// "undo last import, nothing more" — deliberately NOT a history).
/// In-memory only: the undo affordance is a same-session safety net, and an
/// app restart clearing it is acceptable v1 behavior. If persistence is ever
/// wanted, that is a new ruling, not a drive-by upgrade.
public final class BatchWithdrawLedger: @unchecked Sendable {
    public static let shared = BatchWithdrawLedger()

    private let lock = NSLock()
    private var lastBatch: [String]?

    private init() {}

    public func record(_ ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        // An empty batch (everything refused) must not overwrite a
        // still-revertible previous batch.
        guard !ids.isEmpty else { return }
        lastBatch = ids
    }

    public func peek() -> [String]? {
        lock.lock(); defer { lock.unlock() }
        return lastBatch
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        lastBatch = nil
    }

    public func replace(with ids: [String]) {
        lock.lock(); defer { lock.unlock() }
        lastBatch = ids.isEmpty ? nil : ids
    }
}
