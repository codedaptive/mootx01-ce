import Foundation
import AppIntents
import AriaMCP   // JSONValue, for building tool arguments

// MARK: - Batch curation intents  (M-MXA-2R)
//
// Batch forms of the two REVERSIBLE curation verbs, using EntityCollection so
// the system passes drawer identifiers without resolving full entities
// (wwdc2026-345: ARIA verbs take IDs — full resolution was pure waste).
// Execution loops and the undo path live in BatchCurationCore.swift; this
// file holds only the EntityCollection-typed system surface.
//
// Availability + testability: EntityCollection is @available 27 AND its
// symbols are absent from a macOS 26 host, so this file is 27-gated and kept
// symbol-isolated from the core (see the note there). Runtime verification of
// THIS surface happens on an OS-27 runtime (iOS 27 simulator or a macOS 27
// host — the M-MXA-4 AppIntentsTesting lane); the execution semantics are
// verified in-process today through the core.
//
// Charter boundary (Bob ruling, estate E26078CC): there is NO batch expunge,
// on any surface, under any framing.

// MARK: BatchMutateIntent

/// verb: mutate × N · batch form of MutateDrawerIntent. Applies one named
/// mutation (confirm, reject, contest, resolve, accept, …) to every drawer
/// in the collection. Mutations are audited, non-destructive state moves —
/// the benign end of the verb ledger, so no extra guard beyond the
/// substrate's own per-mutation legality checks.
@available(macOS 27.0, iOS 27.0, *)
public struct BatchMutateIntent: AppIntent {
    public static let title: LocalizedStringResource = "Update Memories"
    public static let description = IntentDescription(
        "Apply one mutation (confirm, reject, …) to several memories at once.",
        categoryName: "Memory"
    )
    public static let isDiscoverable = true

    @Parameter(title: "Memories") public var drawers: EntityCollection<DrawerEntity>
    @Parameter(title: "Mutation", default: "confirm") public var mutation: String

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(
        drawers: EntityCollection<DrawerEntity>,
        mutation: String = "confirm",
        caller: (any MootToolCalling)? = nil
    ) {
        self.drawers = drawers
        self.mutation = mutation
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller()
        // EntityCollection carries identifiers — no entity resolution happens.
        let outcome = await BatchCurationCore.mutate(
            ids: Array(drawers.identifiers), mutation: mutation, caller: c
        )
        let summary = outcome.failed.isEmpty
            ? "updated \(outcome.succeeded.count) memories (\(mutation))"
            : "updated \(outcome.succeeded.count) of \(drawers.count) memories (\(mutation)); "
              + "\(outcome.failed.count) refused: \(outcome.failed.joined(separator: ", "))"
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }

    @MainActor
    private func resolvedCaller() async throws -> any MootToolCalling {
        if let caller { return caller }
        return try await IntentRuntimeBridge.shared.bridge()
    }
}

// MARK: BatchWithdrawIntent

/// verb: withdraw × N · batch form of WithdrawDrawerIntent. Soft-removes
/// every drawer in the collection from active circulation, then records the
/// batch so UndoLastBatchWithdrawIntent can revive it. A per-batch
/// confirmation (count in the dialog) fires before anything is withdrawn —
/// deterministic, at the action execution stage (wwdc2026-347).
@available(macOS 27.0, iOS 27.0, *)
public struct BatchWithdrawIntent: AppIntent {
    public static let title: LocalizedStringResource = "Withdraw Memories"
    public static let description = IntentDescription(
        "Withdraw several memories from circulation. Reversible with Undo Last Withdraw.",
        categoryName: "Memory"
    )
    public static let isDiscoverable = true
    /// Withdrawing content is curation of sensitive state; do not allow it
    /// from a locked device (wwdc2026-347 lock-screen hardening).
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Memories") public var drawers: EntityCollection<DrawerEntity>
    @Parameter(title: "Reason") public var reason: String?

    public var caller: (any MootToolCalling)?

    public init() {}
    public init(
        drawers: EntityCollection<DrawerEntity>,
        reason: String? = nil,
        caller: (any MootToolCalling)? = nil
    ) {
        self.drawers = drawers
        self.reason = reason
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard !drawers.isEmpty else {
            return .result(dialog: "No memories to withdraw.")
        }
        // Per-batch human check BEFORE execution. Throws (cancelling the
        // intent) when the user declines — nothing is withdrawn.
        try await requestConfirmation(
            dialog: IntentDialog(
                stringLiteral: "Withdraw \(drawers.count) memories? You can revert this with Undo Last Withdraw."
            )
        )
        let c = try await resolvedCaller()
        let outcome = await BatchCurationCore.withdraw(
            ids: Array(drawers.identifiers), reason: reason, caller: c
        )
        let summary = outcome.failed.isEmpty
            ? "withdrew \(outcome.succeeded.count) memories"
            : "withdrew \(outcome.succeeded.count) of \(drawers.count) memories; "
              + "\(outcome.failed.count) refused: \(outcome.failed.joined(separator: ", "))"
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }

    @MainActor
    private func resolvedCaller() async throws -> any MootToolCalling {
        if let caller { return caller }
        return try await IntentRuntimeBridge.shared.bridge()
    }
}
