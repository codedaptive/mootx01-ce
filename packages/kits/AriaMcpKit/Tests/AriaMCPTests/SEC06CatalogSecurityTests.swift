import AriaMCPWire
import Foundation
import Testing
@testable import AriaMCP

@Suite("SEC-06 caller-specific cognition catalog")
struct SEC06CatalogSecurityTests {
    @Test("first-party lens listing advertises first-party argument types")
    func firstPartyListingUsesFirstPartyProjection() throws {
        let service = AriaV2CognitionCatalogService(
            estateID: UUID(),
            callableToolNames: Set(FirstPartyProviderCatalog.registry.operations.map(\.publicName)),
            buildID: FirstPartyProviderCatalog.contractVersion,
            capabilityDigest: FirstPartyProviderCatalog.capabilityDigest,
            projectedTools: FirstPartyProviderCatalog.projectedTools)

        let result = try service.lenses(AriaV2CognitionCatalogRequest(
            arguments: .object(["verbose": .bool(true)])))
        let tools = try #require(
            result.objectValue?["structuredContent"]?.objectValue?["data"]?
                .objectValue?["tools"]?.arrayValue)
        let keystones = try #require(tools.first {
            $0.objectValue?["name"] == .string("moot_lens_keystones")
        }?.objectValue)
        let properties = try #require(
            keystones["input_schema"]?.objectValue?["properties"]?.objectValue)

        #expect(properties["topK"]?.objectValue?["type"] == .string("integer"))
        #expect(properties["keystoneOnly"]?.objectValue?["type"] == .string("boolean"))
        #expect(properties["estate_id"] == nil)
    }
}
