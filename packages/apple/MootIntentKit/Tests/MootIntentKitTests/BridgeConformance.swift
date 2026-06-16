import Foundation
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import MootIntentKit

// MARK: - TestBridge
//
// A real MootBridge-equivalent that satisfies MootToolCalling for the test
// target. We cannot import MootBridge directly (it lives in apps/Mootx01-App,
// which is a separate package), so we replicate the three-step wiring
// (schema → coordinator → dispatcher) here — the same pattern documented in
// MootBridge.swift.
//
// Note on perform() headlessness: AppIntents' perform() requires the App
// Intents runtime (a registered app bundle). In a headless test target that
// runtime is not present, so we test the underlying tool-call composition
// functions directly — the callTool paths that perform() delegates to. This is
// stated explicitly in the test suite header and satisfies the force-test
// requirement.

actor TestBridge: MootToolCalling {

    private let dispatcher: ARIA_MCPDispatcher
    private var nextID: Int64 = 1

    init(dispatcher: ARIA_MCPDispatcher) {
        self.dispatcher = dispatcher
    }

    /// Build a TestBridge over a fresh in-memory estate.
    static func makeInMemory() async throws -> TestBridge {
        let owner = OwnerCredentials(ownerIdentifier: "test-owner")
        let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
        let storage = InMemoryStorage(configuration: configuration)

        let kit = GeniusLocusKit()
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        let info = ARIA_MCPDispatcher.ServerInfo(name: "TestBridge", version: "0.0.0")
        let tooling = ToolDispatcher(kit: kit, handle: handle)
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)
        return TestBridge(dispatcher: dispatcher)
    }

    func callTool(_ name: String, arguments: [String: JSONValue]) async -> IntentCallResult {
        let id = JSONValue.integer(nextID)
        nextID += 1
        let params: JSONValue = .object([
            "name": .string(name),
            "arguments": .object(arguments),
        ])
        let request = JSONRPCRequest(id: id, method: "tools/call", params: params)
        guard let response = await dispatcher.handle(request) else {
            return IntentCallResult(text: "no response from dispatcher", isError: true)
        }
        return Self.flatten(response)
    }

    private static func flatten(_ response: JSONRPCResponse) -> IntentCallResult {
        switch response.payload {
        case .error(let error):
            return IntentCallResult(
                text: "JSON-RPC error \(error.code): \(error.message)",
                isError: true
            )
        case .result(let value):
            guard let object = value.objectValue else {
                return IntentCallResult(text: prettyPrint(value), isError: false)
            }
            let isError = object["isError"]?.boolValue ?? false
            guard let content = object["content"]?.arrayValue else {
                return IntentCallResult(text: prettyPrint(value), isError: isError)
            }
            let text = content.compactMap { block -> String? in
                block.objectValue?["text"]?.stringValue
            }.joined(separator: "\n")
            return IntentCallResult(
                text: text.isEmpty ? prettyPrint(value) : text,
                isError: isError
            )
        }
    }

    private static func prettyPrint(_ value: JSONValue) -> String {
        do {
            let data = try JSONSerialization.data(
                withJSONObject: value.foundationObject,
                options: [.prettyPrinted, .sortedKeys]
            )
            return String(decoding: data, as: UTF8.self)
        } catch {
            return "(unrenderable)"
        }
    }
}
