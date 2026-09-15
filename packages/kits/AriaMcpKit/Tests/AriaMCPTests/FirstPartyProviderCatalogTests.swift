import Foundation
import Testing
@testable import AriaMCP

@Suite("FirstPartyProvider contract")
struct FirstPartyProviderCatalogTests {
    @Test func fixedCatalogAndDiscoveryMatchSharedVectors() throws {
        let fixture = try fixtureObject()
        let provider = try #require(fixture["provider"]?.objectValue)

        #expect(provider["provider"] == .string(FirstPartyProviderCatalog.providerName))
        #expect(provider["contract_version"] == .string(FirstPartyProviderCatalog.contractVersion))
        #expect(provider["aria_supported_version"] == .string(FirstPartyProviderCatalog.supportedARIAVersion))
        #expect(provider["capabilities"] == .array(FirstPartyProviderCatalog.capabilities.map(JSONValue.string)))
        #expect(provider["capability_digest"] == .string(FirstPartyProviderCatalog.capabilityDigest))
        #expect(FirstPartyProviderCatalog.discovery.jsonValue == .object(provider))

        let operations = try #require(fixture["operations"]?.arrayValue)
        #expect(operations.count == 26)
        #expect(operations.count == FirstPartyProviderCatalog.registry.operations.count)
        for vector in operations {
            let operation = try #require(vector.objectValue)
            let name = try #require(operation["name"]?.stringValue)
            let descriptor = try #require(FirstPartyProviderCatalog.registry.operation(named: name))
            #expect(descriptor.identity.rawValue == operation["identity"]?.stringValue)
            #expect(descriptor.effect.rawValue == operation["effect"]?.stringValue)
            let meta = try #require(descriptor.projection.outputSchema.objectValue?["properties"]?.objectValue?["meta"]?.objectValue)
            let metaProperties = try #require(meta["properties"]?.objectValue)
            #expect(metaProperties["effect"]?.objectValue?["const"] == .string(descriptor.effect.rawValue))
            #expect(metaProperties["completeness"] == nil)
        }
    }

    @Test func contractDoesNotFollowPublicCatalogSelection() throws {
        let stableNames = FirstPartyProviderCatalog.registry.operations.map(\.publicName)
        let stableSchemas = FirstPartyProviderCatalog.registry.operations.map(\.inputSchema)
        let stableDigest = FirstPartyProviderCatalog.capabilityDigest
        let publicTools = ToolProjection.tools(environment: [:])

        let publicEnabled = AriaV2SelectedCatalog.capabilityDigest(environment: [:])
        let publicWithoutVault = AriaV2SelectedCatalog.capabilityDigest(environment: ["MOOTX01_VAULT": "0"])
        #expect(publicTools.count == 81)
        #expect(publicEnabled == "7e16e5149d12665d517d576ce17a4121b29848066783fbb750b46842270871a6")
        #expect(stableNames.count == 26)
        #expect(stableDigest == "3cb6f168d86fc2c1dc0f5384f1ac5972c8c16d49ff08b32a862abaaab2d3a77e")
        #expect(publicEnabled != stableDigest)
        #expect(publicEnabled != publicWithoutVault)
        #expect(FirstPartyProviderCatalog.registry.operations.map(\.publicName) == stableNames)
        #expect(FirstPartyProviderCatalog.registry.operations.map(\.inputSchema) == stableSchemas)
        #expect(FirstPartyProviderCatalog.capabilityDigest == stableDigest)

        let names = Set(stableNames)
        #expect(!names.contains("moot_dream"))
        #expect(publicTools.map(\.name).contains("moot_dream"))
        #expect(names.isDisjoint(with: ["moot_file_packet", "moot_packet_get", "moot_vault_export"]))
        #expect(!names.contains { $0.hasPrefix("moot_community_") })
    }

    @Test func vectorsKeepMCPToolsListAndToolsCallEnvelopes() throws {
        let fixture = try fixtureObject()
        let examples = try #require(fixture["jsonrpc_examples"]?.arrayValue)
        let expectedMethods = ["tools/list", "tools/call", "tools/call"]

        for (example, expectedMethod) in zip(examples, expectedMethods) {
            let request = try #require(JSONRPCRequest.decode(example))
            #expect(request.jsonrpc == "2.0")
            #expect(request.method == expectedMethod)
        }

        let operations = try #require(fixture["operations"]?.arrayValue)
        for operation in operations {
            let vector = try #require(operation.objectValue)
            let name = try #require(vector["name"]?.stringValue)
            let arguments = try #require(vector["arguments"]?.objectValue)
            try FirstPartyProviderCatalog.validateArguments(name: name, arguments: arguments)
            #expect(FirstPartyProviderCatalog.registry.operation(named: name) != nil)
            #expect(arguments["estate_id"] == nil)
        }

        for example in examples.dropFirst() {
            let request = try #require(JSONRPCRequest.decode(example))
            let params = try #require(request.params?.objectValue)
            let name = try #require(params["name"]?.stringValue)
            let arguments = try #require(params["arguments"]?.objectValue)
            try FirstPartyProviderCatalog.validateArguments(name: name, arguments: arguments)
            #expect(FirstPartyProviderCatalog.registry.operation(named: name) != nil)
        }
    }

    @Test func fixedSchemaAdmissionMatchesRecallAndKeystoneContracts() throws {
        try FirstPartyProviderCatalog.validateArguments(name: "moot_recall_precise", arguments: [
            "query": .string("lake path"), "limit": .integer(3), "filter": .string("exportable"),
        ])
        try FirstPartyProviderCatalog.validateArguments(name: "moot_memory_search", arguments: [
            "query": .string("lake path"), "filter": .string("exportable"),
        ])
        try FirstPartyProviderCatalog.validateArguments(name: "moot_fact_search", arguments: [
            "source_id_exact": .string(""), "subject_exact": .string("lake path"),
        ])
        try FirstPartyProviderCatalog.validateArguments(name: "moot_lens_keystones", arguments: [
            "wing": .string("main"), "topK": .integer(3), "keystoneOnly": .bool(true),
        ])
        #expect(throws: JSONRPCError.self) {
            try FirstPartyProviderCatalog.validateArguments(name: "moot_file_memory", arguments: [
                "content": .string("x"), "subject": .string("x"), "location": .string("x"),
                "undeclared": .string("must fail before capture"),
            ])
        }
        #expect(throws: JSONRPCError.self) {
            try FirstPartyProviderCatalog.validateArguments(name: "moot_recall_precise", arguments: [
                "query": .string("lake path"), "answer": .string("auto"),
            ])
        }
        #expect(throws: JSONRPCError.self) {
            try FirstPartyProviderCatalog.validateArguments(
                name: "moot_recall_precise",
                arguments: ["query": .string("lake path"), "filter": .string("exportable")],
                contractVersion: FirstPartyProviderCatalog.legacyContractVersion)
        }
        #expect(throws: JSONRPCError.self) {
            try FirstPartyProviderCatalog.validateArguments(name: "moot_memory_search", arguments: [
                "query": .string("lake path"), "filter": .string("currentlyBelieve"),
            ])
        }
        #expect(FirstPartyProviderCatalog.admittedContractVersion([
            "contract_version": .string(FirstPartyProviderCatalog.legacyContractVersion),
            "aria_supported_version": .string(FirstPartyProviderCatalog.supportedARIAVersion),
            "capability_digest": .string(FirstPartyProviderCatalog.legacyCapabilityDigest),
        ]) == FirstPartyProviderCatalog.legacyContractVersion)
    }

    @Test func providerOnlyFactSelectorsDoNotWidenPublicV2Grammar() throws {
        try FirstPartyProviderCatalog.validateArguments(name: "moot_fact_search", arguments: [
            "source_id_exact": .string(""), "subject_exact": .string("lake path"),
        ])
        #expect(throws: JSONRPCError.self) {
            try AriaV2FactSearchRequest(arguments: .object([
                "source_id_exact": .string(""), "subject_exact": .string("lake path"),
            ]))
        }
    }

    @Test func nativeMutationGrammarIsAdvertisedWithoutLosingLegacyAliases() throws {
        let id = JSONValue.string("11111111-2222-3333-4444-555555555555")
        try FirstPartyProviderCatalog.validateArguments(name: "moot_update_memory", arguments: [
            "id": id, "mutation": .string("confirm"),
        ])
        try FirstPartyProviderCatalog.validateArguments(name: "moot_withdraw_memory", arguments: ["id": id])
        try FirstPartyProviderCatalog.validateArguments(name: "moot_erase_memory", arguments: [
            "id": id, "confirmed": .bool(true),
        ])
        try FirstPartyProviderCatalog.validateArguments(name: "moot_confirm_memory", arguments: ["id": id])
        try FirstPartyProviderCatalog.validateArguments(name: "moot_move_memory", arguments: [
            "id": id, "location": .string("new room"),
        ])
        try FirstPartyProviderCatalog.validateArguments(name: "moot_review_tunnel", arguments: [
            "tunnel_id": id, "verdict": .string("accept"),
        ])
        try FirstPartyProviderCatalog.validateArguments(name: "moot_retire_fact", arguments: ["id": id])

        // The exact 1.0 tuple keeps its original spellings and move requirement.
        try FirstPartyProviderCatalog.validateArguments(
            name: "moot_move_memory",
            arguments: ["memory_id": id, "wing": .string("main"), "room": .string("new room")],
            contractVersion: FirstPartyProviderCatalog.legacyContractVersion)
        #expect(throws: JSONRPCError.self) {
            try FirstPartyProviderCatalog.validateArguments(
                name: "moot_move_memory",
                arguments: ["id": id, "location": .string("new room")],
                contractVersion: FirstPartyProviderCatalog.legacyContractVersion)
        }
        #expect(throws: JSONRPCError.self) {
            try FirstPartyProviderCatalog.validateArguments(name: "moot_update_memory", arguments: [
                "id": id, "memory_id": id, "mutation": .string("confirm"),
            ])
        }
        #expect(throws: JSONRPCError.self) {
            try FirstPartyProviderCatalog.validateArguments(name: "moot_erase_memory", arguments: [
                "id": id, "confirmed": .bool(false),
            ])
        }
        #expect(throws: JSONRPCError.self) {
            try FirstPartyProviderCatalog.validateArguments(name: "moot_review_tunnel", arguments: [
                "tunnel_id": id, "verdict": .string("accept"), "decision": .string("accept"),
            ])
        }
    }

    private func fixtureObject() throws -> [String: JSONValue] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Conformance/first_party_provider_v1_vectors.json")
        return try #require(JSONValue.parse(Data(contentsOf: url)).objectValue)
    }
}
