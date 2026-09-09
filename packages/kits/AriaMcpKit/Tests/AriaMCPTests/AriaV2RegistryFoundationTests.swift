import Foundation
import Testing
@testable import AriaMCP

@Suite("ARIA v2 registry foundation")
struct AriaV2RegistryFoundationTests {
    private let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
    ])

    private let outputSchema: JSONValue = .object([
        "type": .string("object"),
    ])

    private func descriptor(
        identity: String = "memory.search",
        name: String = "moot_memory_search",
        effect: AriaV2OperationEffect = .read,
        availability: AriaV2OperationAvailability = .init(),
        intents: [String] = ["search"]
    ) -> AriaV2OperationDescriptor {
        AriaV2OperationDescriptor(
            identity: .init(rawValue: identity),
            publicName: name,
            effect: effect,
            availability: availability,
            inputSchema: inputSchema,
            projection: .init(
                outputSchema: outputSchema,
                compactTextDescription: "A compact search summary."
            ),
            help: .init(description: "Search memories.", intents: intents)
        )
    }

    private func inputs(
        lane: AriaV2VisibilityLane = .public,
        capabilities: Set<AriaV2Capability> = []
    ) -> AriaV2RegistryInputs {
        AriaV2RegistryInputs(buildID: "test", lane: lane, capabilities: capabilities)
    }

    @Test func effectiveRegistryExcludesUnavailableOperationsAndProjectsEffects() throws {
        let capability = AriaV2Capability(rawValue: "vault")
        let visible = descriptor()
        let hidden = descriptor(
            identity: "vault.export",
            name: "moot_vault_export",
            effect: .write,
            availability: .init(
                buildIDs: ["release"],
                lanes: [.firstParty],
                requiredCapabilities: [capability]
            )
        )

        let registry = try AriaV2EffectiveRegistry(
            descriptors: [hidden, visible], inputs: inputs())
        #expect(registry.operations == [visible])
        #expect(registry.projectedTools.map(\.name) == ["moot_memory_search"])
        #expect(registry.operation(named: "moot_vault_export") == nil)
        #expect(registry.projectedTools.first?.outputSchema == outputSchema)
        #expect(AriaV2OperationEffect.allCases == [.read, .write])
        #expect(AriaV2OperationEffect.read.authorizationPolicy == .inspection)
        #expect(AriaV2OperationEffect.write.authorizationPolicy == .mutation)
    }

    @Test func effectiveRegistryRejectsDuplicateDescriptorOwnership() throws {
        let one = descriptor()
        let duplicateIdentity = descriptor(identity: "memory.search", name: "moot_memory_get")
        #expect(throws: AriaV2RegistryError.duplicateIdentity(.init(rawValue: "memory.search"))) {
            _ = try AriaV2EffectiveRegistry(descriptors: [one, duplicateIdentity], inputs: inputs())
        }
    }

    @Test func argumentDecoderRejectsUnknownAndNonObjectArguments() throws {
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2ArgumentDecoder(.array([]), allowedKeys: ["memory_id"])
        }
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2ArgumentDecoder(
                .object(["legacy_id": .string("x")]),
                allowedKeys: ["memory_id"]
            )
        }
    }

    @Test func argumentDecoderRequiresScalarsAndNormalizesUUIDs() throws {
        let raw = "A0B1C2D3-E4F5-4678-9ABC-DEF012345678"
        let decoder = try AriaV2ArgumentDecoder(
            .object(["memory_id": .string(raw), "limit": .integer(4)]),
            allowedKeys: ["memory_id", "limit"]
        )
        let uuid = try decoder.requireUUID("memory_id")
        #expect(AriaV2ArgumentDecoder.canonicalUUID(uuid) == raw.lowercased())
        #expect(try decoder.requireInteger("limit") == 4)
        #expect(throws: JSONRPCError.self) {
            _ = try AriaV2ArgumentDecoder(
                .object(["memory_id": .null]), allowedKeys: ["memory_id"]
            ).requireUUID("memory_id")
        }
    }

    @Test func envelopePreservesTypedPayloadAndCapsTextByUnicodeScalar() {
        let text = String(repeating: "🙂", count: 513)
        let envelope = AriaV2Envelope.success(
            tool: "moot_memory_search",
            effect: .read,
            data: .object(["count": .integer(1)]),
            meta: ["completeness": .string("incomplete")],
            compactText: text
        )
        let object = envelope.objectValue
        let rendered = object?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        #expect(rendered?.unicodeScalars.count == AriaV2Envelope.compactTextScalarLimit)
        #expect(object?["isError"] == .bool(false))
        #expect(object?["structuredContent"]?.objectValue?["meta"]?.objectValue?["effect"] == .string("read"))
    }

    @Test func refusalUsesMCPErrorEnvelopeWithoutLegacyProjection() {
        let rendered = AriaV2Envelope.refusal(
            tool: "moot_memory_recall_transcript",
            error: .init(
                code: "capability_unavailable",
                message: "The required reranker is unavailable.",
                retryable: true,
                recovery: .object(["tool": .string("moot_status")])
            )
        )
        let object = rendered.objectValue
        #expect(object?["isError"] == .bool(true))
        #expect(object?["structuredContent"]?.objectValue?["error"]?.objectValue?["code"] == .string("capability_unavailable"))
    }

    @Test func helpUsesOnlyEffectiveOperationsAndKeepsDirectoryRecordsNonCallable() throws {
        let visible = descriptor()
        let hidden = descriptor(
            identity: "vault.export",
            name: "moot_vault_export",
            availability: .init(lanes: [.firstParty])
        )
        let registry = try AriaV2EffectiveRegistry(
            descriptors: [visible, hidden], inputs: inputs())
        let service = AriaV2HelpService(
            registry: registry,
            directoryRecords: [
                .init(
                    recipeID: "search-recipe",
                    description: "A non-callable search recipe.",
                    callableTools: ["moot_memory_search"]
                ),
            ]
        )
        let directory = try #require(service.resolve(try AriaV2HelpRequest(arguments: .object([:]))))
        guard case .directory(let operations, let records) = directory else {
            Issue.record("Expected directory help.")
            return
        }
        #expect(operations.map(\.publicName) == ["moot_memory_search"])
        #expect(records.map(\.recipeID) == ["search-recipe"])
        #expect(registry.projectedTools.map(\.name) == ["moot_memory_search"])
    }
}
