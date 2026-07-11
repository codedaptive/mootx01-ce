#if DEBUG
import AppIntents
import AriaMCP

/// Test-only system-path probe. It is excluded from release builds and hidden
/// from Siri and Shortcuts in debug builds.
public struct TestEstateStatusIntent: MootEstateIntent {
    public static let title: LocalizedStringResource = "Test Estate Status"
    public static let isDiscoverable = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 27.0, macOS 27.0, *)
    public static let allowedExecutionTargets: IntentExecutionTargets = .main

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let caller = try await IntentRuntimeBridge.shared.bridge()
        let result = await caller.callTool("moot_estate_status", arguments: [:])
        if result.isError { throw IntentToolError.substrateRefused(result.text) }
        return .result(value: result.text)
    }
}

/// Removes test-marker drawers from the selected disposable estate.
public struct ResetTestEstateIntent: MootEstateIntent {
    public static let title: LocalizedStringResource = "Reset Test Estate"
    public static let isDiscoverable = false
    public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(iOS 27.0, macOS 27.0, *)
    public static let allowedExecutionTargets: IntentExecutionTargets = .main

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let caller = try await IntentRuntimeBridge.shared.bridge()
        var removed = 0
        for _ in 0..<20 {
            let drawers = await caller.recallDrawers(
                query: "mootx01-app-test",
                limit: 50
            )
            guard !drawers.isEmpty else { break }
            for drawer in drawers {
                let result = await caller.callTool("moot_erase_memory", arguments: [
                    "id": .string(drawer.id),
                    "reason": .string("AppIntentsTesting reset"),
                    "confirmed": .bool(true),
                ])
                if !result.isError { removed += 1 }
            }
        }
        return .result(value: removed)
    }
}
#endif
