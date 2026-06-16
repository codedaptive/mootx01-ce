import Foundation
import AppIntents
import AriaMCP   // JSONValue

// MARK: - Caller-driven verb intents: reanchor · mutate · withdraw · expunge
//
// Each is a real, compiling AppIntent whose perform() routes through the
// matching moot_* tool. They are surfaced to Shortcuts per the mapping table
// — structural operations the user composes deliberately.
//
// System registration: these are live iOS-native capabilities. They are not
// yet registered with the system Shortcuts catalog because that requires an
// Xcode app bundle to declare this package's AppIntentsPackage — a packaging
// step, not a capability gap.
//
// The two Brain-emitted verbs (propose, associate) deliberately have NO intent:
// they are not caller-invokable; their future Apple home is App Intents
// elicitation, not a callable verb.

// MARK: ReanchorDrawerIntent

/// verb: reanchor · move where a drawer sits in structure.
public struct ReanchorDrawerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Move Memory"
    public static let description = IntentDescription(
        "Move a memory to a different location.",
        categoryName: "Memory"
    )

    @Parameter(title: "Memory ID") public var id: String
    /// The target room / location hint. Maps to moot_move_memory `location`
    /// (same convention as moot_file_memory — a free-form room name, not a
    /// physical path). The tool's own resolver maps this to the substrate's
    /// `toRoom` field.
    @Parameter(title: "Location") public var location: String

    /// The tool caller injected by the host. `nil` triggers the runtime fallback.
    public var caller: (any MootToolCalling)?

    public init() {}
    public init(id: String, location: String, caller: (any MootToolCalling)? = nil) {
        self.id = id
        self.location = location
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller()
        let result = await c.callTool("moot_move_memory", arguments: [
            "id": .string(id),
            "location": .string(location),
        ])
        if result.isError { throw IntentToolError.substrateRefused(result.text) }
        return .result(dialog: IntentDialog(stringLiteral: result.text))
    }

    @MainActor
    private func resolvedCaller() async throws -> any MootToolCalling {
        if let caller { return caller }
        return try await IntentRuntimeBridge.shared.bridge()
    }
}

// MARK: MutateDrawerIntent

/// verb: mutate · apply a named mutation to a memory's structural state.
public struct MutateDrawerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Update Memory"
    public static let description = IntentDescription(
        "Apply a named change to a memory.",
        categoryName: "Memory"
    )

    @Parameter(title: "Memory ID") public var id: String
    /// Named mutation (confirm, reject, contest, resolve, accept, …) — matches
    /// the tool surface's decodeMutationKind vocabulary.
    @Parameter(title: "Mutation", default: "confirm") public var mutation: String

    /// The tool caller injected by the host. `nil` triggers the runtime fallback.
    public var caller: (any MootToolCalling)?

    public init() {}
    public init(id: String, mutation: String = "confirm", caller: (any MootToolCalling)? = nil) {
        self.id = id
        self.mutation = mutation
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller()
        let result = await c.callTool("moot_update_memory", arguments: [
            "id": .string(id),
            "mutation": .string(mutation),
        ])
        if result.isError { throw IntentToolError.substrateRefused(result.text) }
        return .result(dialog: IntentDialog(stringLiteral: result.text))
    }

    @MainActor
    private func resolvedCaller() async throws -> any MootToolCalling {
        if let caller { return caller }
        return try await IntentRuntimeBridge.shared.bridge()
    }
}

// MARK: WithdrawDrawerIntent

/// verb: withdraw · retire a memory; history preserved.
public struct WithdrawDrawerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Withdraw Memory"
    public static let description = IntentDescription(
        "Retire a memory from active circulation.",
        categoryName: "Memory"
    )

    @Parameter(title: "Memory ID") public var id: String

    /// The tool caller injected by the host. `nil` triggers the runtime fallback.
    public var caller: (any MootToolCalling)?

    public init() {}
    public init(id: String, caller: (any MootToolCalling)? = nil) {
        self.id = id
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller()
        let result = await c.callTool("moot_withdraw_memory", arguments: ["id": .string(id)])
        if result.isError { throw IntentToolError.substrateRefused(result.text) }
        return .result(dialog: IntentDialog(stringLiteral: result.text))
    }

    @MainActor
    private func resolvedCaller() async throws -> any MootToolCalling {
        if let caller { return caller }
        return try await IntentRuntimeBridge.shared.bridge()
    }
}

// MARK: ExpungeDrawerIntent

/// verb: expunge · irreversible hard-erase. Guarded — requires confirmation.
public struct ExpungeDrawerIntent: AppIntent {
    public static let title: LocalizedStringResource = "Erase Memory"
    public static let description = IntentDescription(
        "Permanently erase a memory and its audit trail.",
        categoryName: "Memory"
    )

    public static let isDiscoverable = true

    @Parameter(title: "Memory ID") public var id: String
    @Parameter(title: "Reason") public var reason: String
    /// Guard bit: the substrate refuses the erase when this is false, keeping
    /// the confirmation requirement enforced at the tool level, not just here.
    @Parameter(title: "Confirmed", default: false) public var confirmed: Bool

    /// The tool caller injected by the host. `nil` triggers the runtime fallback.
    public var caller: (any MootToolCalling)?

    public init() {}
    public init(id: String, reason: String, confirmed: Bool = false, caller: (any MootToolCalling)? = nil) {
        self.id = id
        self.reason = reason
        self.confirmed = confirmed
        self.caller = caller
    }

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let c = try await resolvedCaller()
        let result = await c.callTool("moot_erase_memory", arguments: [
            "id": .string(id),
            "reason": .string(reason),
            "confirmed": .bool(confirmed),
        ])
        if result.isError { throw IntentToolError.substrateRefused(result.text) }
        return .result(dialog: IntentDialog(stringLiteral: result.text))
    }

    @MainActor
    private func resolvedCaller() async throws -> any MootToolCalling {
        if let caller { return caller }
        return try await IntentRuntimeBridge.shared.bridge()
    }
}
