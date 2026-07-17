import AriaMCP
import Testing
@testable import MootIntentKit

private actor RuntimeProbeCaller: MootToolCalling {
    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult {
        IntentCallResult(text: name, isError: false)
    }
}

private actor ProviderInvocationCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@Suite("Intent runtime bridge")
struct IntentRuntimeBridgeTests {
    @Test("unconfigured bridge fails closed")
    func unconfiguredBridgeFailsClosed() async {
        let runtime = IntentRuntimeBridge()
        await #expect(throws: IntentRuntimeError.self) {
            _ = try await runtime.bridge()
        }
    }

    @Test("lazy provider is resolved once and cached")
    func lazyProviderIsCached() async throws {
        let runtime = IntentRuntimeBridge()
        let caller = RuntimeProbeCaller()
        let counter = ProviderInvocationCounter()
        runtime.registerProvider {
            await counter.increment()
            return caller
        }

        let callers = try await withThrowingTaskGroup(of: (any MootToolCalling).self) { group in
            for _ in 0..<10 {
                group.addTask { try await runtime.bridge() }
            }
            var values: [any MootToolCalling] = []
            for try await value in group { values.append(value) }
            return values
        }
        let first = callers[0]
        let second = callers[1]
        let firstResult = await first.callTool("first", arguments: [:])
        let secondResult = await second.callTool("second", arguments: [:])

        #expect(firstResult.text == "first")
        #expect(secondResult.text == "second")
        #expect(callers.count == 10)
        #expect(await counter.value == 1)
    }

    @Test("estate intents target the main app and require local authentication")
    @available(macOS 27.0, iOS 27.0, *)
    func estateIntentPolicy() {
        #expect(CaptureDrawerIntent.allowedExecutionTargets.contains(.main))
        #expect(RecallDrawerIntent.allowedExecutionTargets.contains(.main))
        #expect(CaptureDrawerIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
        #expect(RecallDrawerIntent.authenticationPolicy == .requiresLocalDeviceAuthentication)
    }
}
