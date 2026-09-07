import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

typealias ProviderVersionVector = MootDaemonProvider.ProviderVersionVector

// MARK: - P8 descriptor publication

/// A valid, MAC-sealed schema-3 (descriptor, vector) pair for tests.
///
/// The descriptor's `descriptorMAC` is the SCHEMA-3 MAC covering both the
/// descriptor fields (via `descriptor.macInput()`) and the vector's 7 wire
/// scalar fields (via `vector.appendWire1Fields`).  Schema-2 golden vectors
/// in FirstPartyAuthProtocolTests use literal `schemaVersion: 2` and the
/// schema-2 HMAC path to prove schema-2 MAC bytes are unchanged (R1).
func sealedDescriptor(
    instance: UUID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!,
    estate: UUID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
    credentialGeneration: UInt64 = 1,
    descriptorGeneration: UInt64 = 1,
    capabilities: [String] = ["authenticated-first-party", "resident-estate", "tool-surface"],
    root: [UInt8] = [UInt8](repeating: 5, count: 32),
    vector: ProviderVersionVector = .current
) -> FirstPartyDescriptor {
    var descriptor = FirstPartyDescriptor(
        schemaVersion: FirstPartyAuthProtocol.descriptorSchemaVersion,
        providerIdentifier: FirstPartyAuthProtocol.providerIdentifier,
        serviceIdentifier: FirstPartyAuthProtocol.serviceIdentifier,
        endpoint: FirstPartyAuthProtocol.endpoint,
        authProtocol: FirstPartyAuthProtocol.authProtocolIdentifier,
        authKeyIdentifier: FirstPartyAuthProtocol.authKeyIdentifier,
        publishedAt: 1_700_000_000,
        instanceIdentifier: instance,
        estateIdentifier: estate,
        binaryVersion: "1.0.18",
        contractRevision: FirstPartyAuthProtocol.contractRevision,
        mcpProtocolVersion: FirstPartyAuthProtocol.mcpProtocolVersion,
        capabilities: capabilities.sorted(),
        credentialGeneration: credentialGeneration,
        descriptorGeneration: descriptorGeneration,
        descriptorMAC: []
    )
    // Schema-3 MAC: descriptor.macInput() + vector.wire1Fields (R1 — macInput() unchanged).
    descriptor.descriptorMAC = ProviderVersionVector.schema3MAC(
        descriptor: descriptor, vector: vector, installationRoot: root
    )
    return descriptor
}

@Suite("Descriptor encoding")
struct DescriptorEncodingTests {

    @Test("encode/decode round-trips the full schema-3 record")
    func roundTrip() {
        let vector = ProviderVersionVector.current
        let descriptor = sealedDescriptor(vector: vector)
        let decoded = DescriptorPublisher.decode(DescriptorPublisher.encode(descriptor, vector: vector))
        #expect(decoded?.descriptor == descriptor)
        #expect(decoded?.vector == vector)
    }

    @Test("the encoding is deterministic")
    func deterministic() {
        let vector = ProviderVersionVector.current
        let descriptor = sealedDescriptor(vector: vector)
        #expect(
            DescriptorPublisher.encode(descriptor, vector: vector) ==
            DescriptorPublisher.encode(descriptor, vector: vector)
        )
    }

    @Test("the encoded record carries exactly the twenty-three schema-3 fields and no secret")
    func fieldSetExact() throws {
        let vector = ProviderVersionVector.current
        let data = DescriptorPublisher.encode(sealedDescriptor(vector: vector), vector: vector)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set((object ?? [:]).keys)
        #expect(keys == [
            // Schema-2 fields (16)
            "schemaVersion", "providerIdentifier", "serviceIdentifier", "endpoint",
            "authProtocol", "authKeyIdentifier", "publishedAt", "instanceIdentifier",
            "estateIdentifier", "binaryVersion", "contractRevision", "mcpProtocolVersion",
            "capabilities", "credentialGeneration", "descriptorGeneration", "descriptorMAC",
            // Schema-3 additions (7)
            "providerReleaseGeneration",
            "managementRevisionMinimum", "managementRevisionMaximum",
            "dataPlaneRevisionMinimum", "dataPlaneRevisionMaximum",
            "estateSchemaMinimum", "estateSchemaMaximum",
        ])
        // No path-shaped or root-shaped content anywhere in the serialization.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("/Library/"))
        #expect(!text.contains("sqlite"))
    }

    @Test("generations are decimal strings on the wire, exact at UInt64.max")
    func generationsAreStrings() throws {
        let vector = ProviderVersionVector.current
        let descriptor = sealedDescriptor(
            credentialGeneration: UInt64.max,
            descriptorGeneration: UInt64.max - 1,
            vector: vector
        )
        let data = DescriptorPublisher.encode(descriptor, vector: vector)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["credentialGeneration"] as? String == "18446744073709551615")
        #expect(object?["descriptorGeneration"] as? String == "18446744073709551614")
        let decoded = DescriptorPublisher.decode(data)
        #expect(decoded?.descriptor.credentialGeneration == UInt64.max)
    }

    @Test("providerReleaseGeneration is a decimal string on the wire")
    func releaseGenerationIsString() throws {
        let vector = ProviderVersionVector.current
        let data = DescriptorPublisher.encode(sealedDescriptor(vector: vector), vector: vector)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let raw = object?["providerReleaseGeneration"] as? String
        #expect(raw != nil)
        #expect(raw == "\(ProviderVersionVector.releaseGeneration)")
    }

    @Test("malformed records decode as nil")
    func malformedNil() {
        #expect(DescriptorPublisher.decode(Data("garbage".utf8)) == nil)
        #expect(DescriptorPublisher.decode(Data("{}".utf8)) == nil)
        #expect(DescriptorPublisher.decode(Data()) == nil)
    }

    @Test("a schema-2 record decodes as nil — exact-set check rejects 16-key records")
    func schema2DecodesAsNilFailClosed() {
        // A schema-2 descriptor has 16 keys; the schema-3 decoder requires exactly
        // 23.  The exact-set check fails, returning nil — correct fail-closed
        // behaviour (D1/R4).  The legacy classification is provided separately by
        // ProviderVersionVector.isLegacyDescriptor (covered in VersionVectorTests).
        let schema2Object: [String: Any] = [
            "schemaVersion": 2, "providerIdentifier": "com.mootx01.mgr",
            "serviceIdentifier": "com.mootx01.daemon",
            "endpoint": "http://127.0.0.1:4242/mcp/first-party",
            "authProtocol": "hmac-sha256-hkdf-v1", "authKeyIdentifier": "installation-root-v1",
            "publishedAt": NSNumber(value: 1_700_000_000 as UInt64),
            "instanceIdentifier": "CCCCCCCC-0000-0000-0000-000000000003",
            "estateIdentifier": "AAAAAAAA-0000-0000-0000-000000000001",
            "binaryVersion": "1.0.0", "contractRevision": 2, "mcpProtocolVersion": "2025-11-25",
            "capabilities": ["authenticated-first-party"], "credentialGeneration": "1",
            "descriptorGeneration": "1", "descriptorMAC": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: schema2Object, options: [.sortedKeys])) ?? Data()
        #expect(DescriptorPublisher.decode(data) == nil)
    }

    @Test("a tampered published record fails MAC verification")
    func tamperFailsMAC() {
        let root = [UInt8](repeating: 5, count: 32)
        let vector = ProviderVersionVector.current
        var descriptor = sealedDescriptor(root: root, vector: vector)
        // Verify the schema-3 MAC is correct.
        let expected = ProviderVersionVector.schema3MAC(
            descriptor: descriptor, vector: vector, installationRoot: root
        )
        #expect(descriptor.descriptorMAC == expected)
        // Tampering any field changes the schema-2 macInput() and therefore the
        // schema-3 MAC.
        descriptor.binaryVersion = "9.9.9"
        let tampered = ProviderVersionVector.schema3MAC(
            descriptor: descriptor, vector: vector, installationRoot: root
        )
        #expect(descriptor.descriptorMAC != tampered)
    }
}

@Suite("Descriptor publication preconditions (Perkins P8)")
struct DescriptorPublishTests {

    private func makePublisher() -> (ScratchDirectory, DescriptorPublisher, URL, ProviderLockHandle) {
        let scratch = ScratchDirectory()
        let file = scratch.url.appendingPathComponent("daemon-descriptor.v3.json")
        let publisher = DescriptorPublisher(descriptorFile: file)
        let handle = try! ProviderLock.acquire(at: scratch.url.appendingPathComponent("provider.lock"))
        return (scratch, publisher, file, handle)
    }

    private var estateProof: EstateReadyProof {
        EstateReadyProof(
            estateIdentifier: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            schemaVersion: 12
        )
    }

    private var readiness: AuthenticatorReadiness {
        AuthenticatorReadiness(capabilities: ["authenticated-first-party", "resident-estate", "tool-surface"])
    }

    @Test("a fully proven publication writes the record atomically")
    func provenPublish() throws {
        let (scratch, publisher, file, handle) = makePublisher()
        defer { withExtendedLifetime(scratch) {} }
        let vector = ProviderVersionVector.current
        let descriptor = sealedDescriptor(vector: vector)
        try publisher.publish(
            descriptor, vector: vector, lockProof: handle.proof,
            estateReady: estateProof,
            bind: BindProof(host: "127.0.0.1", port: 4242),
            authenticator: readiness
        )
        let decoded = DescriptorPublisher.decode(try Data(contentsOf: file))
        #expect(decoded?.descriptor == descriptor)
        #expect(decoded?.vector == vector)
        handle.release()
    }

    @Test("republication atomically replaces the record")
    func replace() throws {
        let (scratch, publisher, file, handle) = makePublisher()
        defer { withExtendedLifetime(scratch) {} }
        let vector = ProviderVersionVector.current
        try publisher.publish(
            sealedDescriptor(descriptorGeneration: 1, vector: vector), vector: vector,
            lockProof: handle.proof,
            estateReady: estateProof, bind: BindProof(host: "127.0.0.1", port: 4242),
            authenticator: readiness
        )
        let second = sealedDescriptor(descriptorGeneration: 2, vector: vector)
        try publisher.publish(
            second, vector: vector, lockProof: handle.proof,
            estateReady: estateProof, bind: BindProof(host: "127.0.0.1", port: 4242),
            authenticator: readiness
        )
        #expect(DescriptorPublisher.decode(try Data(contentsOf: file))?.descriptor.descriptorGeneration == 2)
        _ = second
        handle.release()
    }

    @Test("a bind readback that is not exactly the contracted endpoint refuses")
    func bindMismatch() throws {
        let (scratch, publisher, file, handle) = makePublisher()
        defer { withExtendedLifetime(scratch) {} }
        let vector = ProviderVersionVector.current
        for bad in [BindProof(host: "0.0.0.0", port: 4242),
                    BindProof(host: "127.0.0.1", port: 4243),
                    BindProof(host: "localhost", port: 4242),
                    BindProof(host: "::1", port: 4242)] {
            #expect(throws: DaemonProviderError.publishPreconditionFailed(.bindMismatch)) {
                try publisher.publish(
                    sealedDescriptor(vector: vector), vector: vector,
                    lockProof: handle.proof,
                    estateReady: estateProof, bind: bad, authenticator: readiness
                )
            }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        handle.release()
    }

    @Test("an estate proof for a different estate refuses")
    func estateMismatch() throws {
        let (scratch, publisher, file, handle) = makePublisher()
        defer { withExtendedLifetime(scratch) {} }
        let vector = ProviderVersionVector.current
        #expect(throws: DaemonProviderError.publishPreconditionFailed(.estateNotReady)) {
            try publisher.publish(
                sealedDescriptor(vector: vector), vector: vector,
                lockProof: handle.proof,
                estateReady: EstateReadyProof(estateIdentifier: UUID(), schemaVersion: 12),
                bind: BindProof(host: "127.0.0.1", port: 4242),
                authenticator: readiness
            )
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        handle.release()
    }

    @Test("an incomplete authenticator refuses: missing capability or capability disagreement")
    func authenticatorIncomplete() throws {
        let (scratch, publisher, file, handle) = makePublisher()
        defer { withExtendedLifetime(scratch) {} }
        let vector = ProviderVersionVector.current
        // Missing the authenticated-first-party capability entirely.
        #expect(throws: DaemonProviderError.publishPreconditionFailed(.authenticatorIncomplete)) {
            try publisher.publish(
                sealedDescriptor(vector: vector), vector: vector,
                lockProof: handle.proof,
                estateReady: estateProof, bind: BindProof(host: "127.0.0.1", port: 4242),
                authenticator: AuthenticatorReadiness(capabilities: ["resident-estate", "tool-surface"])
            )
        }
        // Capabilities that disagree with the descriptor's.
        #expect(throws: DaemonProviderError.publishPreconditionFailed(.authenticatorIncomplete)) {
            try publisher.publish(
                sealedDescriptor(vector: vector), vector: vector,
                lockProof: handle.proof,
                estateReady: estateProof, bind: BindProof(host: "127.0.0.1", port: 4242),
                authenticator: AuthenticatorReadiness(capabilities: ["authenticated-first-party"])
            )
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        handle.release()
    }

    @Test("a malformed descriptor refuses: wrong schema, wrong endpoint, wrong identity, wrong MAC width")
    func malformedDescriptorRefused() throws {
        let (scratch, publisher, file, handle) = makePublisher()
        defer { withExtendedLifetime(scratch) {} }
        let vector = ProviderVersionVector.current
        var wrongSchema = sealedDescriptor(vector: vector)
        wrongSchema.schemaVersion = 1
        var wrongEndpoint = sealedDescriptor(vector: vector)
        wrongEndpoint.endpoint = "http://localhost:4242/mcp/first-party"
        var wrongProvider = sealedDescriptor(vector: vector)
        wrongProvider.providerIdentifier = "com.evil.mgr"
        var wrongMAC = sealedDescriptor(vector: vector)
        wrongMAC.descriptorMAC = [1, 2, 3]
        for bad in [wrongSchema, wrongEndpoint, wrongProvider, wrongMAC] {
            #expect(throws: DaemonProviderError.publishPreconditionFailed(.descriptorMalformed)) {
                try publisher.publish(
                    bad, vector: vector, lockProof: handle.proof,
                    estateReady: estateProof, bind: BindProof(host: "127.0.0.1", port: 4242),
                    authenticator: readiness
                )
            }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        handle.release()
    }
}

@Suite("Shutdown removal (Perkins P8: remove own only)")
struct DescriptorRemovalTests {

    private func published(
        _ descriptor: FirstPartyDescriptor,
        vector: ProviderVersionVector = .current
    ) -> (ScratchDirectory, DescriptorPublisher, URL) {
        let scratch = ScratchDirectory()
        let file = scratch.url.appendingPathComponent("daemon-descriptor.v3.json")
        try! DescriptorPublisher.encode(descriptor, vector: vector).write(to: file)
        return (scratch, DescriptorPublisher(descriptorFile: file), file)
    }

    @Test("own instance and generation match removes the record")
    func removesOwn() throws {
        let own = sealedDescriptor(descriptorGeneration: 7)
        let (scratch, publisher, file) = published(own)
        defer { withExtendedLifetime(scratch) {} }
        let outcome = try publisher.removeOwnDescriptor(
            instanceIdentifier: own.instanceIdentifier, descriptorGeneration: 7
        )
        #expect(outcome == .removedOwn)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a foreign instance is left in place — substitution defense")
    func leavesForeignInstance() throws {
        let foreign = sealedDescriptor(instance: UUID())
        let (scratch, publisher, file) = published(foreign)
        defer { withExtendedLifetime(scratch) {} }
        let outcome = try publisher.removeOwnDescriptor(
            instanceIdentifier: UUID(), descriptorGeneration: foreign.descriptorGeneration
        )
        #expect(outcome == .leftForeign)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a different generation is left in place — a successor already republished")
    func leavesNewerGeneration() throws {
        let own = sealedDescriptor(descriptorGeneration: 9)
        let (scratch, publisher, file) = published(own)
        defer { withExtendedLifetime(scratch) {} }
        let outcome = try publisher.removeOwnDescriptor(
            instanceIdentifier: own.instanceIdentifier, descriptorGeneration: 8
        )
        #expect(outcome == .leftForeign)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("an undecodable record is left in place — never a blind unlink")
    func leavesGarbage() throws {
        let scratch = ScratchDirectory()
        let file = scratch.url.appendingPathComponent("daemon-descriptor.v3.json")
        try Data("squatter garbage".utf8).write(to: file)
        let publisher = DescriptorPublisher(descriptorFile: file)
        let outcome = try publisher.removeOwnDescriptor(instanceIdentifier: UUID(), descriptorGeneration: 1)
        #expect(outcome == .leftForeign)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a schema-2 (legacy) record is left in place — decode returns nil for 16-key records")
    func legacyRecordLeftForeign() throws {
        // A schema-2 record on disk: the schema-3 decoder returns nil (exact-set
        // check against 23-key fieldNames fails), so removeOwnDescriptor cannot
        // match it — correct fail-closed DARK behaviour (D1/R4).
        let scratch = ScratchDirectory()
        let file = scratch.url.appendingPathComponent("daemon-descriptor.v2.json")
        let schema2Object: [String: Any] = [
            "schemaVersion": 2, "providerIdentifier": "com.mootx01.mgr",
            "serviceIdentifier": "com.mootx01.daemon",
            "endpoint": "http://127.0.0.1:4242/mcp/first-party",
            "authProtocol": "hmac-sha256-hkdf-v1", "authKeyIdentifier": "installation-root-v1",
            "publishedAt": NSNumber(value: 1_700_000_000 as UInt64),
            "instanceIdentifier": "CCCCCCCC-0000-0000-0000-000000000003",
            "estateIdentifier": "AAAAAAAA-0000-0000-0000-000000000001",
            "binaryVersion": "1.0.0", "contractRevision": 2, "mcpProtocolVersion": "2025-11-25",
            "capabilities": ["authenticated-first-party"], "credentialGeneration": "1",
            "descriptorGeneration": "1", "descriptorMAC": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==",
        ]
        let data = (try? JSONSerialization.data(withJSONObject: schema2Object, options: [.sortedKeys])) ?? Data()
        try data.write(to: file)
        let publisher = DescriptorPublisher(descriptorFile: file)
        // The instance/generation don't matter — the schema-2 record cannot be decoded.
        let outcome = try publisher.removeOwnDescriptor(
            instanceIdentifier: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!,
            descriptorGeneration: 1
        )
        #expect(outcome == .leftForeign)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("a symlinked descriptor record is never read as the published one — left in place")
    func symlinkedRecordLeft() throws {
        let scratch = ScratchDirectory()
        let own = sealedDescriptor(descriptorGeneration: 3)
        // The REAL record lives elsewhere; the descriptor path is a symlink
        // to it. Reading through the link would let an attacker point the
        // provider's own-record check at content they control — the
        // O_NOFOLLOW read refuses, and nothing is unlinked.
        let elsewhere = scratch.url.appendingPathComponent("elsewhere.json")
        try DescriptorPublisher.encode(own, vector: .current).write(to: elsewhere)
        let file = scratch.url.appendingPathComponent("daemon-descriptor.v3.json")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        let publisher = DescriptorPublisher(descriptorFile: file)
        let outcome = try publisher.removeOwnDescriptor(
            instanceIdentifier: own.instanceIdentifier, descriptorGeneration: 3
        )
        #expect(outcome == .leftForeign)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
        // The link itself is also still there: no blind unlink of any kind.
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil)
    }

    @Test("absence reports absent")
    func absent() throws {
        let scratch = ScratchDirectory()
        let publisher = DescriptorPublisher(descriptorFile: scratch.url.appendingPathComponent("none.json"))
        #expect(try publisher.removeOwnDescriptor(instanceIdentifier: UUID(), descriptorGeneration: 1) == .absent)
    }
}

// MARK: - Part B: MAC field ordering and schema-3 round-trip (MACD-3B1)

@Suite("Schema-3 MAC field ordering (MACD-3B1 Part B)")
struct Schema3MACFieldOrderingTests {

    private let root: [UInt8] = [UInt8](repeating: 9, count: 32)

    /// Manually compute the schema-3 MAC input bytes to verify the frozen field order.
    ///
    /// The MAC input is:
    ///   descriptor.macInput() (schema-2 fields, frozen per R1)
    ///   THEN 7 Wire-1 scalar fields via appendWire1Fields in the fixed order:
    ///     1. providerReleaseGeneration
    ///     2. managementRevisionMinimum
    ///     3. managementRevisionMaximum
    ///     4. dataPlaneRevisionMinimum
    ///     5. dataPlaneRevisionMaximum
    ///     6. estateSchemaMinimum
    ///     7. estateSchemaMaximum
    @Test("schema-3 MAC input is descriptor.macInput() concatenated with 7 wire fields in fixed order")
    func macFieldOrderMatchesSpec() {
        let vector = ProviderVersionVector(
            providerReleaseGeneration: 42,
            managementRevisionMinimum: 11,
            managementRevisionMaximum: 22,
            dataPlaneRevisionMinimum: 33,
            dataPlaneRevisionMaximum: 44,
            estateSchemaMinimum: 55,
            estateSchemaMaximum: 66,
            migrationTargetSchema: nil,
            capabilityRevisions: [:]
        )
        var base3Desc = FirstPartyDescriptor(
            schemaVersion: FirstPartyAuthProtocol.descriptorSchemaVersion,
            providerIdentifier: FirstPartyAuthProtocol.providerIdentifier,
            serviceIdentifier: FirstPartyAuthProtocol.serviceIdentifier,
            endpoint: FirstPartyAuthProtocol.endpoint,
            authProtocol: FirstPartyAuthProtocol.authProtocolIdentifier,
            authKeyIdentifier: FirstPartyAuthProtocol.authKeyIdentifier,
            publishedAt: 1_700_000_000,
            instanceIdentifier: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!,
            estateIdentifier: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            binaryVersion: "1.0.18",
            contractRevision: FirstPartyAuthProtocol.contractRevision,
            mcpProtocolVersion: FirstPartyAuthProtocol.mcpProtocolVersion,
            capabilities: ["authenticated-first-party", "resident-estate", "tool-surface"].sorted(),
            credentialGeneration: 1,
            descriptorGeneration: 1,
            descriptorMAC: []
        )

        // Compute the MAC using ProviderVersionVector.schema3MAC.
        base3Desc.descriptorMAC = ProviderVersionVector.schema3MAC(
            descriptor: base3Desc, vector: vector, installationRoot: root
        )

        // Now manually assemble the same input to verify the field order:
        var manual = CanonicalEncoder()
        manual.appendBytes(base3Desc.macInput())  // schema-2 fields (frozen)
        // Fixed field order for the 7 Wire-1 scalar fields:
        manual.appendUInt64(42)   // 1. providerReleaseGeneration
        manual.appendUInt64(11)   // 2. managementRevisionMinimum
        manual.appendUInt64(22)   // 3. managementRevisionMaximum
        manual.appendUInt64(33)   // 4. dataPlaneRevisionMinimum
        manual.appendUInt64(44)   // 5. dataPlaneRevisionMaximum
        manual.appendUInt64(55)   // 6. estateSchemaMinimum
        manual.appendUInt64(66)   // 7. estateSchemaMaximum
        let manualMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: root),
            message: manual.bytes
        )

        #expect(base3Desc.descriptorMAC == manualMAC)
    }

    @Test("reordering the 7 wire fields in the MAC input produces a different MAC")
    func macFieldReorderingProducesDifferentMAC() {
        // If appendWire1Fields ever reorders its output, this test breaks —
        // an intentional sentinel for the frozen field-order invariant.
        let vector = ProviderVersionVector(
            providerReleaseGeneration: 1,
            managementRevisionMinimum: 2,
            managementRevisionMaximum: 3,
            dataPlaneRevisionMinimum: 4,
            dataPlaneRevisionMaximum: 5,
            estateSchemaMinimum: 6,
            estateSchemaMaximum: 7,
            migrationTargetSchema: nil, capabilityRevisions: [:]
        )
        var correctEncoder = CanonicalEncoder()
        vector.appendWire1Fields(&correctEncoder)
        var reorderedEncoder = CanonicalEncoder()
        // Swap order 1 and 7 to produce a different byte string.
        reorderedEncoder.appendUInt64(vector.estateSchemaMaximum)     // was providerReleaseGeneration
        reorderedEncoder.appendUInt64(vector.managementRevisionMinimum)
        reorderedEncoder.appendUInt64(vector.managementRevisionMaximum)
        reorderedEncoder.appendUInt64(vector.dataPlaneRevisionMinimum)
        reorderedEncoder.appendUInt64(vector.dataPlaneRevisionMaximum)
        reorderedEncoder.appendUInt64(vector.estateSchemaMinimum)
        reorderedEncoder.appendUInt64(vector.providerReleaseGeneration)  // was estateSchemaMaximum
        // The field order matters: a reordering produces different bytes.
        #expect(correctEncoder.bytes != reorderedEncoder.bytes)
    }

    @Test("schema-3 MAC wire field count is exactly 7 scalar UInt64s (56 bytes over macInput)")
    func macWire1FieldsByteLength() {
        // appendWire1Fields writes exactly 7 × 8 = 56 bytes — one UInt64 per field,
        // no length prefixes (they are scalars, not byte strings).
        var encoder = CanonicalEncoder()
        ProviderVersionVector.current.appendWire1Fields(&encoder)
        #expect(encoder.bytes.count == 7 * 8)
    }

    @Test("schema-3 MAC is longer than schema-2 MAC input by exactly 56 bytes")
    func schema3MACInputLongerThanSchema2ByWireFields() {
        // The schema-3 extension must be exactly 7 × 8 = 56 bytes.
        let vector = ProviderVersionVector.current
        let base3Desc = FirstPartyDescriptor(
            schemaVersion: FirstPartyAuthProtocol.descriptorSchemaVersion,
            providerIdentifier: FirstPartyAuthProtocol.providerIdentifier,
            serviceIdentifier: FirstPartyAuthProtocol.serviceIdentifier,
            endpoint: FirstPartyAuthProtocol.endpoint,
            authProtocol: FirstPartyAuthProtocol.authProtocolIdentifier,
            authKeyIdentifier: FirstPartyAuthProtocol.authKeyIdentifier,
            publishedAt: 1_700_000_000,
            instanceIdentifier: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!,
            estateIdentifier: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            binaryVersion: "1.0.18",
            contractRevision: FirstPartyAuthProtocol.contractRevision,
            mcpProtocolVersion: FirstPartyAuthProtocol.mcpProtocolVersion,
            capabilities: ["authenticated-first-party", "resident-estate", "tool-surface"].sorted(),
            credentialGeneration: 1,
            descriptorGeneration: 1,
            descriptorMAC: []
        )
        let schema2InputLength = base3Desc.macInput().count
        // Schema-3 input = macInput() + 7 × UInt64 (no extra length prefix).
        var schema3Encoder = CanonicalEncoder()
        schema3Encoder.appendBytes(base3Desc.macInput())
        vector.appendWire1Fields(&schema3Encoder)
        #expect(schema3Encoder.bytes.count == schema2InputLength + 4 /*UInt32 length prefix of appendBytes*/ + 56)
    }
}
