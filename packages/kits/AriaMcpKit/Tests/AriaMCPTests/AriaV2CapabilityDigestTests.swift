import Foundation
import Testing
@testable import AriaMCP
import AriaMCPWire

@Suite("ARIA v2 capability digest")
struct AriaV2CapabilityDigestTests {
    @Test func selectedCatalogDigestSharedVector() throws {
        let digest = AriaV2SelectedCatalog.capabilityDigest
        #expect(digest == "cd523a448e0b4a4a5c7430c1628d2d22230f9b2e49f5fbd84ac1f09cc8056415")
        let artifactURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../Registry/aria-v2-selected-release.json")
            .standardizedFileURL
        let artifact = try JSONSerialization.jsonObject(
            with: Data(contentsOf: artifactURL)) as? [String: String]
        #expect(artifact?["ariaVersion"] == "v2")
        #expect(artifact?["catalogIdentity"] == digest)
    }
    @Test("Digest ignores supplied descriptor order and nested object-key order")
    func orderIndependence() throws {
        let first = descriptor(
            name: "moot_alpha",
            identity: "alpha",
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "b": .object(["type": .string("string")]),
                    "a": .object(["minimum": .integer(1), "type": .string("integer")]),
                ]),
            ])
        )
        let reorderedFirst = descriptor(
            name: "moot_alpha",
            identity: "alpha",
            schema: .object([
                "properties": .object([
                    "a": .object(["type": .string("integer"), "minimum": .integer(1)]),
                    "b": .object(["type": .string("string")]),
                ]),
                "type": .string("object"),
            ])
        )
        let second = descriptor(name: "moot_beta", identity: "beta")

        let lhs = try AriaV2CapabilityDigest.digest(descriptors: [second, first])
        let rhs = try AriaV2CapabilityDigest.digest(descriptors: [reorderedFirst, second])
        #expect(lhs == rhs)
    }

    @Test("Digest changes when a schema or effect changes")
    func definitionSensitivity() throws {
        let baseline = descriptor(name: "moot_alpha", identity: "alpha")
        let changedSchema = descriptor(
            name: "moot_alpha",
            identity: "alpha",
            schema: .object(["type": .string("array")])
        )
        let changedEffect = descriptor(
            name: "moot_alpha",
            identity: "alpha",
            effect: .write
        )

        let baselineDigest = try AriaV2CapabilityDigest.digest(descriptors: [baseline])
        let changedSchemaDigest = try AriaV2CapabilityDigest.digest(descriptors: [changedSchema])
        let changedEffectDigest = try AriaV2CapabilityDigest.digest(descriptors: [changedEffect])
        #expect(baselineDigest != changedSchemaDigest)
        #expect(baselineDigest != changedEffectDigest)
    }

    @Test("Effective-registry digest excludes build identity")
    func buildIDExclusion() throws {
        let operation = descriptor(name: "moot_alpha", identity: "alpha")
        let first = try AriaV2EffectiveRegistry(
            descriptors: [operation],
            inputs: .init(buildID: "build-one", lane: .public, capabilities: [])
        )
        let second = try AriaV2EffectiveRegistry(
            descriptors: [operation],
            inputs: .init(buildID: "build-two", lane: .public, capabilities: [])
        )

        let firstDigest = try AriaV2CapabilityDigest.digest(registry: first)
        let secondDigest = try AriaV2CapabilityDigest.digest(registry: second)
        #expect(firstDigest == secondDigest)
    }

    private func descriptor(
        name: String,
        identity: String,
        effect: AriaV2OperationEffect = .read,
        schema: JSONValue = .object(["type": .string("object")])
    ) -> AriaV2OperationDescriptor {
        AriaV2OperationDescriptor(
            identity: .init(rawValue: identity),
            publicName: name,
            effect: effect,
            availability: .init(),
            inputSchema: schema,
            projection: .init(
                outputSchema: .object(["type": .string("object")]),
                compactTextDescription: "Synthetic compact text."
            ),
            help: .init(
                description: "Synthetic help.",
                intents: ["synthetic"],
                example: .object(["argument": .string("value")]),
                prerequisites: ["synthetic-capability"]
            )
        )
    }
}
