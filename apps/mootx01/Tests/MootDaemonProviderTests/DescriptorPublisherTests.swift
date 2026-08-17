import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

// MARK: - P8 descriptor publication

/// A valid, MAC-sealed schema-2 descriptor for tests.
func sealedDescriptor(
    instance: UUID = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!,
    estate: UUID = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
    credentialGeneration: UInt64 = 1,
    descriptorGeneration: UInt64 = 1,
    capabilities: [String] = ["authenticated-first-party", "resident-estate", "tool-surface"],
    root: [UInt8] = [UInt8](repeating: 5, count: 32)
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
    descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
        key: FirstPartyAuthProtocol.descriptorKey(installationRoot: root),
        message: descriptor.macInput()
    )
    return descriptor
}

@Suite("Descriptor encoding")
struct DescriptorEncodingTests {

    @Test("encode/decode round-trips the full schema-2 record")
    func roundTrip() {
        let descriptor = sealedDescriptor()
        let decoded = DescriptorPublisher.decode(DescriptorPublisher.encode(descriptor))
        #expect(decoded == descriptor)
    }

    @Test("the encoding is deterministic")
    func deterministic() {
        let descriptor = sealedDescriptor()
        #expect(DescriptorPublisher.encode(descriptor) == DescriptorPublisher.encode(descriptor))
    }

    @Test("the encoded record carries exactly the sixteen schema-2 fields and no secret")
    func fieldSetExact() throws {
        let data = DescriptorPublisher.encode(sealedDescriptor())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set((object ?? [:]).keys)
        #expect(keys == [
            "schemaVersion", "providerIdentifier", "serviceIdentifier", "endpoint",
            "authProtocol", "authKeyIdentifier", "publishedAt", "instanceIdentifier",
            "estateIdentifier", "binaryVersion", "contractRevision", "mcpProtocolVersion",
            "capabilities", "credentialGeneration", "descriptorGeneration", "descriptorMAC",
        ])
        // No path-shaped or root-shaped content anywhere in the serialization.
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("/Library/"))
        #expect(!text.contains("sqlite"))
    }

    @Test("generations are decimal strings on the wire, exact at UInt64.max")
    func generationsAreStrings() throws {
        let descriptor = sealedDescriptor(credentialGeneration: UInt64.max, descriptorGeneration: UInt64.max - 1)
        let data = DescriptorPublisher.encode(descriptor)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["credentialGeneration"] as? String == "18446744073709551615")
        #expect(object?["descriptorGeneration"] as? String == "18446744073709551614")
        let decoded = DescriptorPublisher.decode(data)
        #expect(decoded?.credentialGeneration == UInt64.max)
    }

    @Test("malformed records decode as nil")
    func malformedNil() {
        #expect(DescriptorPublisher.decode(Data("garbage".utf8)) == nil)
        #expect(DescriptorPublisher.decode(Data("{}".utf8)) == nil)
        #expect(DescriptorPublisher.decode(Data()) == nil)
    }

    @Test("a tampered published record fails MAC verification")
    func tamperFailsMAC() {
        let root = [UInt8](repeating: 5, count: 32)
        var descriptor = sealedDescriptor(root: root)
        #expect(descriptor.verifyMAC(installationRoot: root))
        descriptor.binaryVersion = "9.9.9"
        #expect(!descriptor.verifyMAC(installationRoot: root))
    }
}

@Suite("Descriptor publication preconditions (Perkins P8)")
struct DescriptorPublishTests {

    private func makePublisher() -> (ScratchDirectory, DescriptorPublisher, URL, ProviderLockHandle) {
        let scratch = ScratchDirectory()
        let file = scratch.url.appendingPathComponent("daemon-descriptor.v2.json")
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
        let descriptor = sealedDescriptor()
        try publisher.publish(
            descriptor, lockProof: handle.proof,
            estateReady: estateProof,
            bind: BindProof(host: "127.0.0.1", port: 4242),
            authenticator: readiness
        )
        #expect(DescriptorPublisher.decode(try Data(contentsOf: file)) == descriptor)
        handle.release()
    }

    @Test("republication atomically replaces the record")
    func replace() throws {
        let (scratch, publisher, file, handle) = makePublisher()
        defer { withExtendedLifetime(scratch) {} }
        try publisher.publish(
            sealedDescriptor(descriptorGeneration: 1), lockProof: handle.proof,
            estateReady: estateProof, bind: BindProof(host: "127.0.0.1", port: 4242),
            authenticator: readiness
        )
        let second = sealedDescriptor(descriptorGeneration: 2)
        try publisher.publish(
            second, lockProof: handle.proof,
            estateReady: estateProof, bind: BindProof(host: "127.0.0.1", port: 4242),
            authenticator: readiness
        )
        #expect(DescriptorPublisher.decode(try Data(contentsOf: file))?.descriptorGeneration == 2)
        _ = second
        handle.release()
    }

    @Test("a bind readback that is not exactly the contracted endpoint refuses")
    func bindMismatch() throws {
        let (scratch, publisher, file, handle) = makePublisher()
        defer { withExtendedLifetime(scratch) {} }
        for bad in [BindProof(host: "0.0.0.0", port: 4242),
                    BindProof(host: "127.0.0.1", port: 4243),
                    BindProof(host: "localhost", port: 4242),
                    BindProof(host: "::1", port: 4242)] {
            #expect(throws: DaemonProviderError.publishPreconditionFailed(.bindMismatch)) {
                try publisher.publish(
                    sealedDescriptor(), lockProof: handle.proof,
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
        #expect(throws: DaemonProviderError.publishPreconditionFailed(.estateNotReady)) {
            try publisher.publish(
                sealedDescriptor(), lockProof: handle.proof,
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
        // Missing the authenticated-first-party capability entirely.
        #expect(throws: DaemonProviderError.publishPreconditionFailed(.authenticatorIncomplete)) {
            try publisher.publish(
                sealedDescriptor(), lockProof: handle.proof,
                estateReady: estateProof, bind: BindProof(host: "127.0.0.1", port: 4242),
                authenticator: AuthenticatorReadiness(capabilities: ["resident-estate", "tool-surface"])
            )
        }
        // Capabilities that disagree with the descriptor's.
        #expect(throws: DaemonProviderError.publishPreconditionFailed(.authenticatorIncomplete)) {
            try publisher.publish(
                sealedDescriptor(), lockProof: handle.proof,
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
        var wrongSchema = sealedDescriptor()
        wrongSchema.schemaVersion = 1
        var wrongEndpoint = sealedDescriptor()
        wrongEndpoint.endpoint = "http://localhost:4242/mcp/first-party"
        var wrongProvider = sealedDescriptor()
        wrongProvider.providerIdentifier = "com.evil.mgr"
        var wrongMAC = sealedDescriptor()
        wrongMAC.descriptorMAC = [1, 2, 3]
        for bad in [wrongSchema, wrongEndpoint, wrongProvider, wrongMAC] {
            #expect(throws: DaemonProviderError.publishPreconditionFailed(.descriptorMalformed)) {
                try publisher.publish(
                    bad, lockProof: handle.proof,
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
        _ descriptor: FirstPartyDescriptor
    ) -> (ScratchDirectory, DescriptorPublisher, URL) {
        let scratch = ScratchDirectory()
        let file = scratch.url.appendingPathComponent("daemon-descriptor.v2.json")
        try! DescriptorPublisher.encode(descriptor).write(to: file)
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
        let file = scratch.url.appendingPathComponent("daemon-descriptor.v2.json")
        try Data("squatter garbage".utf8).write(to: file)
        let publisher = DescriptorPublisher(descriptorFile: file)
        let outcome = try publisher.removeOwnDescriptor(instanceIdentifier: UUID(), descriptorGeneration: 1)
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
        try DescriptorPublisher.encode(own).write(to: elsewhere)
        let file = scratch.url.appendingPathComponent("daemon-descriptor.v2.json")
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
