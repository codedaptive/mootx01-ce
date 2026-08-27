// CommunityContractTests.swift
//
// Wave A1b: Contract identity endpoint tests.
//
// Test coverage:
//   A1b-CT1  SHA-256 fixture-bundle digest matches embedded constant AND
//            the frozen value in contracts/community/1.1/fixture-bundle.sha256.
//   A1b-C1   Identity endpoint returns exact contract identity with live estateID.
//   A1b-C2   Unknown moot_community_* method → methodNotFound.
//   A1b-C3   Non-empty arguments → invalidParams (fail-closed).
//   A1b-C4   FirstPartyAuthServer challenge/establish handshake with live descriptor.
//   A1b-C5   self-report mode never constructs an auth server (darkness check).
//
// Method: RED → GREEN. Tests were written before the production code, verified
// red on stub sources, then made green by the Wave A1b implementation.

import Testing
import Foundation
import CryptoKit
@testable import MootCommunityDaemon
import MootDaemonProvider
import AriaMCP
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

// MARK: - Helpers

/// Root URL of the repository (derived from this test file's path).
/// Used to locate contracts/community/1.1/ without hard-coding absolute paths.
private var repoRoot: URL {
    URL(filePath: #filePath)
        .deletingLastPathComponent()  // CommunityContractTests.swift dir
        .deletingLastPathComponent()  // Tests/MootCommunityDaemonTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // apps/mootx01/
        .deletingLastPathComponent()  // apps/
}

/// The contracts/community/1.1 directory.
private var contractRoot: URL {
    repoRoot.appendingPathComponent("contracts/community/1.1")
}

/// Plaintext key provider for test estates. No encryption, no Keychain.
private let plaintextProvider: @Sendable (URL) throws -> EstateEncryptionConfig = { _ in .plaintext }

/// Per-test scratch directory for estate files.
private struct Scratch {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("a1b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    var estateURL: URL { url.appendingPathComponent("estate.sqlite") }
    func remove() { try? FileManager.default.removeItem(at: url) }
}

/// The A1b test's fixed test UUIDs (not production values).
private let testInstanceID = UUID(uuidString: "A1B00000-0000-0000-0000-000000000001")!

// MARK: - A1b-CT1: Digest honesty

@Test("A1b-CT1: fixture-bundle digest matches embedded constant and frozen sha256 file")
func fixtureDigestHonesty() throws {
    // Recompute the digest using the same algorithm as verify_contract.py:
    //   SHA-256 over the concatenation of, for each file in order
    //   [contract.json, fixtures/*.json sorted]:
    //     (relative-path-bytes + "\n" + canonical-JSON-bytes + "\n")
    // "Canonical JSON" = json.dumps(value, sort_keys=True,
    //   ensure_ascii=False, separators=(",",":")) in Python.

    let contractFile = contractRoot.appendingPathComponent("contract.json")
    let fixturesDir = contractRoot.appendingPathComponent("fixtures")

    // Build the ordered file list: contract.json first, then fixtures/*.json sorted.
    let fixtureFiles = (try FileManager.default.contentsOfDirectory(atPath: fixturesDir.path))
        .filter { $0.hasSuffix(".json") }
        .sorted()
        .map { fixturesDir.appendingPathComponent($0) }
    let orderedFiles = [contractFile] + fixtureFiles

    var hasher = SHA256()
    for fileURL in orderedFiles {
        let data = try Data(contentsOf: fileURL)

        // Relative path from contractRoot (NOT from repoRoot), matching Python's
        // path.relative_to(ROOT).as_posix() where ROOT = contracts/community/1.1/.
        // Produces "contract.json" and "fixtures/<name>.json", which is exactly
        // what verify_contract.py feeds to SHA-256.
        let relativePath = fileURL.path.hasPrefix(contractRoot.path + "/")
            ? String(fileURL.path.dropFirst(contractRoot.path.count + 1))  // drop base + "/"
            : fileURL.lastPathComponent
        guard let relativeBytes = relativePath.data(using: .utf8) else {
            throw TestError.encodingFailed(relativePath)
        }

        // Parse JSON and re-encode in canonical form (sort_keys=True, no whitespace).
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        let canonical = try JSONSerialization.data(
            withJSONObject: parsed,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )

        // Feed: relative-path-bytes + newline + canonical-JSON-bytes + newline.
        hasher.update(data: relativeBytes)
        hasher.update(data: Data([0x0A]))   // "\n"
        hasher.update(data: canonical)
        hasher.update(data: Data([0x0A]))   // "\n"
    }
    let digest = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()

    // Assert against the embedded constant (what the daemon will report).
    #expect(
        digest == CommunityContractConstants.fixtureDigest,
        "Recomputed digest \(digest) does not match CommunityContractConstants.fixtureDigest"
    )

    // Assert against the frozen file (what verify_contract.py wrote).
    let frozenFile = contractRoot.appendingPathComponent("fixture-bundle.sha256")
    let frozenDigest = try String(contentsOf: frozenFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(
        digest == frozenDigest,
        "Recomputed digest \(digest) does not match fixture-bundle.sha256 (\(frozenDigest))"
    )
}

private enum TestError: Error {
    case encodingFailed(String)
}

// MARK: - A1b-C1: Identity endpoint returns live estateID

@Test("A1b-C1: identity endpoint returns exact contract identity with live estate UUID")
func identityEndpointReturnsLiveEstateID() async throws {
    let scratch = try Scratch()
    defer { scratch.remove() }

    // Open a real estate to get a live estateID.
    let host = CommunityEstateHost(
        estateURL: scratch.estateURL,
        ownerIdentifier: "com.mootx01.daemon.test",
        keyProvider: plaintextProvider
    )
    let proof = try await host.openEstate()

    // Build the community-only dispatcher with the live estate UUID.
    let state = CommunityProviderState(
        instanceIdentifier: testInstanceID,
        estateIdentifier: proof.estateIdentifier
    )
    let handler = CommunityContractDispatch(state: state)
    let info = ARIA_MCPDispatcher.ServerInfo(name: "mootx01", version: "1.1.0")
    let dispatcher = ARIA_MCPDispatcher(info: info, communityHandler: handler)

    // Dispatch the identity tool.
    let request = JSONRPCRequest(
        id: .integer(1),
        method: "tools/call",
        params: .object([
            "name": .string("moot_community_contract_identity"),
            "arguments": .object([:]),
        ])
    )
    let response = await dispatcher.handle(request)
    // JSONRPCResponse.Payload has cases .result(JSONValue) and .error(JSONRPCError).
    guard let resp = response, case .result(let result) = resp.payload else {
        Issue.record("Expected ok response, got: \(String(describing: response))")
        return
    }
    #expect(resp.id == .integer(1))

    // Extract structuredContent from the result.
    guard case .object(let outer) = result,
          case .object(let sc) = outer["structuredContent"] else {
        Issue.record("No structuredContent in result: \(result)")
        return
    }

    // Assert all fields. JSONValue type annotation avoids Swift 6 inference
    // ambiguity in #expect macro expressions.
    #expect(sc["contractID"] == JSONValue.string(CommunityContractConstants.contractID))
    #expect(sc["contractVersion"] == JSONValue.string(CommunityContractConstants.contractVersion))
    #expect(sc["fixtureDigestAlgorithm"] == JSONValue.string(CommunityContractConstants.fixtureDigestAlgorithm))
    #expect(sc["fixtureDigest"] == JSONValue.string(CommunityContractConstants.fixtureDigest))

    // UUIDs must be lowercase hyphenated.
    let expectedInstanceID = testInstanceID.uuidString.lowercased()
    let expectedEstateID = proof.estateIdentifier.uuidString.lowercased()
    #expect(sc["daemonInstanceID"] == JSONValue.string(expectedInstanceID))
    #expect(sc["estateID"] == JSONValue.string(expectedEstateID))
}

// MARK: - A1b-C2: Unknown method → methodNotFound

@Test("A1b-C2: unknown moot_community_* method returns methodNotFound")
func unknownCommunityMethodFails() async throws {
    let state = CommunityProviderState(
        instanceIdentifier: testInstanceID,
        estateIdentifier: UUID()
    )
    let handler = CommunityContractDispatch(state: state)
    let info = ARIA_MCPDispatcher.ServerInfo(name: "mootx01", version: "1.1.0")
    let dispatcher = ARIA_MCPDispatcher(info: info, communityHandler: handler)

    let request = JSONRPCRequest(
        id: .integer(2),
        method: "tools/call",
        params: .object([
            "name": .string("moot_community_nonexistent_tool"),
            "arguments": .object([:]),
        ])
    )
    let response = await dispatcher.handle(request)
    // Payload.error carries the JSONRPCError; .failure/_id is the static factory, not a case.
    guard let resp = response, case .error(let error) = resp.payload else {
        Issue.record("Expected error response")
        return
    }
    #expect(error.code == JSONRPCErrorCode.methodNotFound)
}

// MARK: - A1b-C3: Extra args → invalidParams (fail-closed)

@Test("A1b-C3: non-empty arguments to identity tool returns invalidParams")
func extraArgsFailClosed() async throws {
    let state = CommunityProviderState(
        instanceIdentifier: testInstanceID,
        estateIdentifier: UUID()
    )
    let handler = CommunityContractDispatch(state: state)
    let info = ARIA_MCPDispatcher.ServerInfo(name: "mootx01", version: "1.1.0")
    let dispatcher = ARIA_MCPDispatcher(info: info, communityHandler: handler)

    // Inject an unknown field in arguments — fail closed.
    let request = JSONRPCRequest(
        id: .integer(3),
        method: "tools/call",
        params: .object([
            "name": .string("moot_community_contract_identity"),
            "arguments": .object(["unexpected_key": .string("value")]),
        ])
    )
    let response = await dispatcher.handle(request)
    guard let resp = response, case .error(let error) = resp.payload else {
        Issue.record("Expected error response for extra args")
        return
    }
    #expect(error.code == JSONRPCErrorCode.invalidParams)
}

// MARK: - A1b-C4: FirstPartyAuthServer real auth lane

@Test("A1b-C4: FirstPartyAuthServer challenge/establish succeeds with live descriptor")
func firstPartyAuthLaneWorks() async throws {
    // The fixed test root: (0..<32).map { UInt8($0) } — test-only; never production.
    let testRoot: [UInt8] = (0..<32).map { UInt8($0) }

    // Build a descriptor that is MAC-valid under the test root.
    // Uses the same vector pattern as FirstPartyAuthServerTests.signedDescriptor().
    var descriptor = FirstPartyDescriptor(
        schemaVersion: 2,
        providerIdentifier: FirstPartyAuthProtocol.providerIdentifier,
        serviceIdentifier: FirstPartyAuthProtocol.serviceIdentifier,
        endpoint: FirstPartyAuthProtocol.endpoint,
        authProtocol: FirstPartyAuthProtocol.authProtocolIdentifier,
        authKeyIdentifier: FirstPartyAuthProtocol.authKeyIdentifier,
        publishedAt: 1_766_000_000,
        instanceIdentifier: testInstanceID,
        estateIdentifier: UUID(uuidString: "A1B00000-0000-0000-0000-000000000002")!,
        binaryVersion: "1.1.0",
        contractRevision: FirstPartyAuthProtocol.contractRevision,
        mcpProtocolVersion: FirstPartyAuthProtocol.mcpProtocolVersion,
        capabilities: [FirstPartyAuthProtocol.serviceIdentifier],
        credentialGeneration: 1,
        descriptorGeneration: 1,
        descriptorMAC: []
    )
    // Compute the genuine MAC under the test root.
    descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
        key: FirstPartyAuthProtocol.descriptorKey(installationRoot: testRoot),
        message: descriptor.macInput()
    )

    // Build auth server with the fixed root provider (in-process, no Keychain).
    // `let` (not `var`) so Swift 6 allows capture in the @Sendable `now` closure.
    let clockSeconds: UInt64 = 1_766_000_100
    let authServer = FirstPartyAuthServer(
        rootProvider: FixedFirstPartyRootProvider(root: testRoot),
        descriptor: descriptor,
        serverName: "mootx01",
        now: { clockSeconds },
        randomBytes: { count in (0..<count).map { UInt8($0 & 0xFF) } }
    )

    // Step 1: challenge — the client presents the descriptor digest.
    let clientNonce: [UInt8] = [UInt8](repeating: 0xC1, count: 32)
    let challenged = try await authServer.challenge(
        clientNonce: clientNonce,
        descriptorDigest: descriptor.digest()
    )

    // Step 2: establish — client derives its proof and sends it.
    let transcript = FirstPartyAuthProtocol.sessionTranscript(
        descriptorDigest: descriptor.digest(),
        providerIdentifier: descriptor.providerIdentifier,
        serviceIdentifier: descriptor.serviceIdentifier,
        endpoint: descriptor.endpoint,
        instanceIdentifier: descriptor.instanceIdentifier,
        estateIdentifier: descriptor.estateIdentifier,
        binaryVersion: descriptor.binaryVersion,
        descriptorSchemaVersion: descriptor.schemaVersion,
        contractRevision: descriptor.contractRevision,
        mcpProtocolVersion: descriptor.mcpProtocolVersion,
        credentialGeneration: descriptor.credentialGeneration,
        descriptorGeneration: descriptor.descriptorGeneration,
        clientNonce: clientNonce,
        serverNonce: challenged.serverNonce,
        sessionIdentifier: challenged.sessionIdentifier,
        issuedAt: challenged.issuedAt,
        idleExpiry: challenged.idleExpiry,
        absoluteExpiry: challenged.absoluteExpiry
    )
    let authKey = FirstPartyAuthProtocol.authKey(
        installationRoot: testRoot,
        descriptorDigest: descriptor.digest()
    )
    let clientProof = FirstPartyAuthProtocol.clientProof(authKey: authKey, transcript: transcript)

    // Establish: must not throw — a correct proof on the real auth lane succeeds.
    let _ = try await authServer.establish(
        sessionIdentifier: challenged.sessionIdentifier,
        clientProof: clientProof
    )

    // Auth lane established — the real FirstPartyAuthServer did NOT bypass auth.
    // Any error above would propagate as a test failure.
}

// MARK: - A1b-C5: self-report mode is dark (no HTTP server)

@Test("A1b-C5: self-report mode exits 0 without constructing an HTTP server")
func selfReportModeDark() async {
    // self-report must return exit 0 and the canonical JSON, without binding a port
    // or constructing any HTTP server. Verified by checking the exit code and that
    // the output contains the expected keys, NOT by checking that port 4242 is free
    // (that would be fragile on machines already running a daemon).
    let (code, output) = await DaemonShellMain.runCollecting(arguments: ["self-report"])
    #expect(code == 0)
    #expect(!output.isEmpty)
    // The output must be valid JSON with the moduleDigest key.
    guard let data = output.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        Issue.record("self-report output is not valid JSON: \(output)")
        return
    }
    #expect(json["moduleDigest"] != nil, "moduleDigest missing from self-report output")
    // No firstPartyAuth constructed — the output cannot contain "authenticated-first-party".
    #expect(!output.contains("authenticated-first-party"))
}
