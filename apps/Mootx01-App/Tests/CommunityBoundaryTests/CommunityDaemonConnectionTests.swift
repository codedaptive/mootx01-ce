import AriaMCPWire
import Foundation
@testable import MootCommunityGateway
import Testing

@Suite("Community daemon-only connection")
struct CommunityDaemonConnectionTests {
    @Test("schema-2 descriptor wire format decodes without exposing estate storage")
    func descriptorDecodes() throws {
        let descriptor = CommunityDaemonDescriptorFile.decode(try descriptorData())

        #expect(descriptor?.schemaVersion == DaemonContract.schemaVersion)
        #expect(descriptor?.estateIdentifier == Self.estateID)
        #expect(descriptor?.credentialGeneration == 7)
        #expect(descriptor?.descriptorGeneration == 11)
        #expect(descriptor?.descriptorMAC == [UInt8](repeating: 0xA5, count: 32))
        #expect(descriptor?.capabilities == Set(DaemonCapability.allCases))
    }

    @Test("descriptor reader rejects widened and non-canonical records")
    func malformedDescriptorsFailClosed() throws {
        var extra = try descriptorObject()
        extra["estatePath"] = "/private/estate.sqlite"
        #expect(CommunityDaemonDescriptorFile.decode(try JSONSerialization.data(withJSONObject: extra)) == nil)

        var leadingZero = try descriptorObject()
        leadingZero["descriptorGeneration"] = "011"
        #expect(CommunityDaemonDescriptorFile.decode(
            try JSONSerialization.data(withJSONObject: leadingZero)
        ) == nil)

        var unknownCapability = try descriptorObject()
        unknownCapability["capabilities"] = ["authenticated-first-party", "unknown"]
        #expect(CommunityDaemonDescriptorFile.decode(
            try JSONSerialization.data(withJSONObject: unknownCapability)
        ) == nil)
    }

    @Test("missing descriptor is unavailable and oversized descriptor is refused")
    func descriptorFileOutcomes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("missing.json")
        #expect(try CommunityDaemonDescriptorFile.load(from: missing) == nil)

        let oversized = directory.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: 65 * 1024).write(to: oversized)
        #expect(throws: CommunityDaemonDescriptorFile.ReadError.oversized) {
            try CommunityDaemonDescriptorFile.load(from: oversized)
        }
    }

    @Test("Community product sources have no embedded-estate or Product Dock route")
    func communitySourceBoundary() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let communitySources = [
            appRoot.appendingPathComponent("Sources/MootCommunityUI", isDirectory: true),
            appRoot.appendingPathComponent("CommunityApp", isDirectory: true),
        ]
        let forbidden = [
            "GatewayRuntime.shared.bridge",
            "MootBridge.attachSQLite",
            "MootBridge.attachInMemory",
            "ProductDockProcessLifecycle",
            "SQLiteStorage",
        ]

        var findings: [String] = []
        for directory in communitySources {
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
            while let file = enumerator?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                for token in forbidden where source.contains(token) {
                    findings.append("\(file.lastPathComponent): \(token)")
                }
            }
        }
        #expect(findings.isEmpty, "Community storage/dock boundary violations: \(findings)")
    }

    @Test("Community release entitlement uses the daemon custody App Group")
    func communityReleaseUsesTeamPrefixedCustodyGroup() throws {
        let appRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let entitlementsURL = appRoot
            .appendingPathComponent("CommunityApp/Mootx01-Community-macOS.entitlements")
        let plist = try #require(
            PropertyListSerialization.propertyList(
                from: Data(contentsOf: entitlementsURL),
                format: nil
            ) as? [String: Any]
        )
        let groups = try #require(
            plist["com.apple.security.application-groups"] as? [String]
        )

        #expect(groups == ["G94X5T5GK7.group.com.codedaptive.mootx01"])
    }

    @Test("compiled Community contract identity matches the frozen bundle")
    func compiledContractIdentityMatchesFrozenBundle() throws {
        let contractRoot = repositoryRoot()
            .appendingPathComponent("contracts/community/1.1", isDirectory: true)
        let contractData = try Data(contentsOf: contractRoot.appendingPathComponent("contract.json"))
        let contract = try #require(
            JSONSerialization.jsonObject(with: contractData) as? [String: Any]
        )
        let digest = try String(
            contentsOf: contractRoot.appendingPathComponent("fixture-bundle.sha256"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let endpoints = try #require(contract["endpoints"] as? [[String: Any]])

        #expect(contract["contractID"] as? String == CommunityContractIdentity.contractID)
        #expect(contract["contractVersion"] as? String == CommunityContractIdentity.contractVersion)
        #expect(contract["fixtureDigestAlgorithm"] as? String == CommunityContractIdentity.fixtureDigestAlgorithm)
        #expect(digest == CommunityContractIdentity.fixtureDigest)
        #expect(endpoints.contains { $0["name"] as? String == CommunityContractIdentity.method })
    }

    @Test("authenticated daemon accepts the exact frozen identity fixture")
    func exactCommunityContractIdentityIsAccepted() async throws {
        let descriptor = try #require(CommunityDaemonDescriptorFile.decode(try descriptorData()))
        let response = try identityFixture(caseID: "identity-exact-match", digest: CommunityContractIdentity.fixtureDigest)
        let caller = ContractIdentityCaller(structured: response, estateID: Self.estateID)

        let verdict = await CommunityContractIdentity.verify(caller: caller, descriptor: descriptor)

        #expect(verdict == .accepted)
    }

    @Test("contract mismatch and widened identity both fail closed")
    func incompatibleOrWidenedCommunityContractIdentityIsRefused() async throws {
        let descriptor = try #require(CommunityDaemonDescriptorFile.decode(try descriptorData()))
        let mismatch = try identityFixture(caseID: "identity-digest-mismatch")
        let mismatchCaller = ContractIdentityCaller(structured: mismatch, estateID: Self.estateID)
        #expect(await CommunityContractIdentity.verify(
            caller: mismatchCaller,
            descriptor: descriptor
        ) == .incompatible)

        var widenedObject = try #require(
            identityFixture(
                caseID: "identity-exact-match",
                digest: CommunityContractIdentity.fixtureDigest
            ).objectValue
        )
        widenedObject["estatePath"] = .string("/forbidden/estate.sqlite")
        let widenedCaller = ContractIdentityCaller(
            structured: .object(widenedObject),
            estateID: Self.estateID
        )
        #expect(await CommunityContractIdentity.verify(
            caller: widenedCaller,
            descriptor: descriptor
        ) == .failed)
    }

    private static let instanceID = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
    private static let estateID = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!

    private func descriptorData() throws -> Data {
        try JSONSerialization.data(withJSONObject: descriptorObject(), options: [.sortedKeys])
    }

    private func repositoryRoot() -> URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root
    }

    private func identityFixture(caseID: String, digest: String? = nil) throws -> JSONValue {
        let fixtureURL = repositoryRoot()
            .appendingPathComponent("contracts/community/1.1/fixtures/identity.json")
        let fixture = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        let cases = try #require(fixture["cases"] as? [[String: Any]])
        let selected = try #require(cases.first { $0["id"] as? String == caseID })
        var result = try #require(selected["result"] as? [String: Any])
        if let digest { result["fixtureDigest"] = digest }
        result["daemonInstanceID"] = Self.instanceID.uuidString
        result["estateID"] = Self.estateID.uuidString
        return try JSONValue.from(result)
    }

    private func descriptorObject() throws -> [String: Any] {
        [
            "schemaVersion": DaemonContract.schemaVersion,
            "providerIdentifier": DaemonContract.providerIdentifier,
            "serviceIdentifier": DaemonContract.serviceIdentifier,
            "endpoint": DaemonContract.firstPartyEndpoint,
            "authProtocol": DaemonContract.authProtocol,
            "authKeyIdentifier": DaemonContract.authKeyIdentifier,
            "publishedAt": 1_766_000_000,
            "instanceIdentifier": Self.instanceID.uuidString,
            "estateIdentifier": Self.estateID.uuidString,
            "binaryVersion": "1.1.0",
            "contractRevision": DaemonContract.supportedContractRevision,
            "mcpProtocolVersion": DaemonContract.mcpProtocolVersion,
            "capabilities": DaemonCapability.allCases.map(\.rawValue).sorted(),
            "credentialGeneration": "7",
            "descriptorGeneration": "11",
            "descriptorMAC": FirstPartyAuthProtocol.base64URLEncode(
                [UInt8](repeating: 0xA5, count: FirstPartyAuthProtocol.macByteCount)
            ),
        ]
    }
}

private actor ContractIdentityCaller: MootEstateCalling {
    nonisolated let serverName = "ARIA_MCP"
    nonisolated let estateIdentity: EstateIdentity
    private let structured: JSONValue

    init(structured: JSONValue, estateID: UUID) {
        self.structured = structured
        estateIdentity = .daemon(estate: estateID, service: DaemonContract.serviceIdentifier)
    }

    func call(method: String, params: JSONValue?) async -> GatewayCall {
        failure("unsupported-call")
    }

    func callToolFull(_ name: String, arguments: [String: JSONValue]) async -> GatewayCall {
        guard name == CommunityContractIdentity.method, arguments.isEmpty else {
            return failure("unexpected-call")
        }
        return GatewayCall(
            requestJSON: "{}",
            responseJSON: "{}",
            text: "",
            structured: structured,
            isError: false
        )
    }

    func toolsList() async -> JSONValue { .object(["tools": .array([])]) }
    func handle(_ request: JSONRPCRequest) async -> JSONRPCResponse? { nil }

    private func failure(_ reason: String) -> GatewayCall {
        GatewayCall(
            requestJSON: "{}",
            responseJSON: "{}",
            text: reason,
            structured: nil,
            isError: true
        )
    }
}
