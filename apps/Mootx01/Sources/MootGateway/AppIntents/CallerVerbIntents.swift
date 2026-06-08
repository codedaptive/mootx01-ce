import Foundation
import AppIntents
import AriaMCP   // JSONValue

// MARK: - The remaining caller-driven verb intents (shells)
//
// reanchor · mutate · withdraw · expunge. Each is a real, compiling AppIntent
// whose perform() routes through the matching moot_* tool. They are surfaced
// to Shortcuts (not Siri) per the mapping table — structural operations the
// user composes deliberately rather than speaks. The two Brain-emitted verbs
// (propose, associate) deliberately have NO intent: they are not caller-
// invokable; their future Apple home is App Intents elicitation, not a verb.

/// verb: reanchor · move where a drawer sits in structure.
public struct ReanchorDrawerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Move Memory"
    public static let description = IntentDescription("Move a memory to a different location.", categoryName: "Memory")

    @Parameter(title: "Memory ID") public var id: String
    @Parameter(title: "Destination") public var destination: String

    public init() {}
    public init(id: String, destination: String) { self.id = id; self.destination = destination }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let bridge = try await GatewayRuntime.shared.bridge()
        let call = await bridge.callTool("moot_move_memory", arguments: [
            "id": .string(id),
            "destination": .string(destination),
        ])
        if call.isError { throw GatewayIntentError.substrateRefused(call.text) }
        return .result(dialog: IntentDialog(stringLiteral: call.text))
    }
}

/// verb: mutate · apply a named mutation to a memory's structural state.
public struct MutateDrawerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Update Memory"
    public static let description = IntentDescription("Apply a named change to a memory.", categoryName: "Memory")

    @Parameter(title: "Memory ID") public var id: String
    /// Named mutation (confirm, reject, contest, resolve, accept, …) — matches
    /// the tool surface's decodeMutationKind vocabulary.
    @Parameter(title: "Mutation", default: "confirm") public var mutation: String

    public init() {}
    public init(id: String, mutation: String = "confirm") { self.id = id; self.mutation = mutation }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let bridge = try await GatewayRuntime.shared.bridge()
        let call = await bridge.callTool("moot_update_memory", arguments: [
            "id": .string(id),
            "mutation": .string(mutation),
        ])
        if call.isError { throw GatewayIntentError.substrateRefused(call.text) }
        return .result(dialog: IntentDialog(stringLiteral: call.text))
    }
}

/// verb: withdraw · retire a memory; history preserved.
public struct WithdrawDrawerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Withdraw Memory"
    public static let description = IntentDescription("Retire a memory from active circulation.", categoryName: "Memory")

    @Parameter(title: "Memory ID") public var id: String

    public init() {}
    public init(id: String) { self.id = id }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let bridge = try await GatewayRuntime.shared.bridge()
        let call = await bridge.callTool("moot_withdraw_memory", arguments: ["id": .string(id)])
        if call.isError { throw GatewayIntentError.substrateRefused(call.text) }
        return .result(dialog: IntentDialog(stringLiteral: call.text))
    }
}

/// verb: expunge · irreversible hard-erase. Guarded — requires confirmation.
public struct ExpungeDrawerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Erase Memory"
    public static let description = IntentDescription("Permanently erase a memory and its audit trail.", categoryName: "Memory")
    /// Mark destructive so the system double-checks before running.
    public static let isDiscoverable = true

    @Parameter(title: "Memory ID") public var id: String
    @Parameter(title: "Reason") public var reason: String
    @Parameter(title: "Confirmed", default: false) public var confirmed: Bool

    public init() {}
    public init(id: String, reason: String, confirmed: Bool = false) {
        self.id = id; self.reason = reason; self.confirmed = confirmed
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let bridge = try await GatewayRuntime.shared.bridge()
        let call = await bridge.callTool("moot_erase_memory", arguments: [
            "id": .string(id),
            "reason": .string(reason),
            "confirmed": .bool(confirmed),
        ])
        if call.isError { throw GatewayIntentError.substrateRefused(call.text) }
        return .result(dialog: IntentDialog(stringLiteral: call.text))
    }
}
