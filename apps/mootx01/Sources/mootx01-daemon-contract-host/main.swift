// mootx01-daemon-contract-host/main.swift
//
// DEDICATED HEADLESS CONTRACT-TEST HOST (F3)
//
// This binary is the ONLY place in the mootx01 product that runs the headless
// contract-test path. It is spawned by ContractDaemonHarness and exercises the
// same coordinator composition that the production mootx01-daemon runs via the
// shared CommunityResidentMain.makeCommunityDispatch function (F2).
//
// The production mootx01-daemon binary contains NO env-var branches that skip
// DaemonProvider.activate() / provider lock / Keychain custody. This target is
// the only place env-var overrides live.
//
// CONTRACT-TEST ENVIRONMENT VARIABLES:
//   MOOT_CONTRACT_TEST_ESTATE_DIR    — temp directory for estate files + descriptor.
//   MOOT_CONTRACT_TEST_AUTH_ROOT_HEX — 64-char hex encoding of the 32-byte test root.
//   MOOT_CONTRACT_TEST_HTTP_PORT     — requested bind port (0 = OS-assigned, default).
//
// The headless path:
//   1. Reads env vars; refuses with exit 1 on missing/malformed values.
//   2. Binds to the requested port (0 → OS picks a free port).
//   3. Constructs a FirstPartyDescriptor with the actual bound port and writes it
//      to estateDir/daemon-descriptor.v2.json via DescriptorPublisher.encode()
//      (publish() enforces port 4242 and cannot be used for dynamic-port tests).
//   4. Calls CommunityResidentMain.makeCommunityDispatch with plaintext key provider
//      and slow poll intervals — the SAME composition function production uses,
//      so the harness certifies production coordinator wiring.
//   5. Builds a FirstPartyAuthServer using FixedFirstPartyRootProvider (test root,
//      no Keychain) and an ARIA_MCPDispatcher backed by the community dispatch.
//   6. Installs a SIGTERM handler and serves until signalled.
//      serve(withFD:) shuts down cooperatively and waits for the accept thread
//      before returning — so the process exits cleanly on SIGTERM.

import Foundation
import AriaMCP
import MootDaemonProvider
import MootCommunityDaemon
import PersistenceKit
import PersistenceKitSQLite
import LocusKit
import GeniusLocusKit

// MARK: - Entry point

// Swift @main is unavailable in top-level files; use the conventional
// top-level async runner instead (swift-argument-parser style but without
// the framework dependency — this binary has a single implicit mode).
let exitCode = await runContractHost()
exit(exitCode)

// MARK: - Main async body

func runContractHost() async -> Int32 {
    // ── Read env vars ──────────────────────────────────────────────────────────
    guard let estateDirPath = ProcessInfo.processInfo.environment["MOOT_CONTRACT_TEST_ESTATE_DIR"] else {
        fputs("mootx01-daemon-contract-host: MOOT_CONTRACT_TEST_ESTATE_DIR not set\n", stderr)
        return 1
    }
    guard let rootHex = ProcessInfo.processInfo.environment["MOOT_CONTRACT_TEST_AUTH_ROOT_HEX"] else {
        fputs("mootx01-daemon-contract-host: MOOT_CONTRACT_TEST_AUTH_ROOT_HEX not set\n", stderr)
        return 1
    }
    let portStr = ProcessInfo.processInfo.environment["MOOT_CONTRACT_TEST_HTTP_PORT"] ?? "0"
    let requestedPort = UInt16(portStr) ?? 0

    // ── Parse test root ────────────────────────────────────────────────────────
    // Decode the 64-char hex string into 32 bytes. Provided by ContractDaemonHarness.
    guard let testRoot = hexToBytes(rootHex), testRoot.count == 32 else {
        fputs("mootx01-daemon-contract-host: MOOT_CONTRACT_TEST_AUTH_ROOT_HEX must be 64 hex chars\n", stderr)
        return 1
    }

    let estateDir = URL(fileURLWithPath: estateDirPath)

    // ── Step 1: bind socket ────────────────────────────────────────────────────
    // Port 0 lets the OS assign a free port, preventing collisions when multiple
    // contract-test processes run in parallel (the test suite is .serialized, but
    // the OS-assigned port provides an extra safety margin).
    let preBinder = HTTPServer(
        dispatcher: ARIA_MCPDispatcher(
            info: ARIA_MCPDispatcher.ServerInfo(
                name: "mootx01-contract-host-pre-bind",
                version: "0.0.0"
            ),
            communityHandler: ContractHostNoOpHandler()
        ),
        port: requestedPort,
        firstPartyAuth: nil
    )
    let preBound: (fd: Int32, port: UInt16)
    do {
        preBound = try preBinder.bind()
    } catch {
        fputs("mootx01-daemon-contract-host: pre-bind failed: \(error)\n", stderr)
        return 1
    }

    // ── Step 2: build and write the descriptor ─────────────────────────────────
    // Embed the ACTUAL bound port so the auth ceremony targets the right port.
    // DescriptorPublisher.publish() enforces port 4242 and cannot be used here;
    // encode() is the unconditional serialiser.
    let instanceID = UUID()
    // Estate ID placeholder: the lifecycle coordinator opens the real estate on
    // first inspect/create call and returns its UUID then. Shape validation does
    // not compare UUIDs across contract calls.
    let estateID = UUID()
    let actualEndpoint = "http://127.0.0.1:\(preBound.port)\(FirstPartyAuthProtocol.requestPath)"

    var descriptor = FirstPartyDescriptor(
        schemaVersion: FirstPartyAuthProtocol.descriptorSchemaVersion,
        providerIdentifier: FirstPartyAuthProtocol.providerIdentifier,
        serviceIdentifier: FirstPartyAuthProtocol.serviceIdentifier,
        endpoint: actualEndpoint,
        authProtocol: FirstPartyAuthProtocol.authProtocolIdentifier,
        authKeyIdentifier: FirstPartyAuthProtocol.authKeyIdentifier,
        publishedAt: UInt64(Date().timeIntervalSince1970),
        instanceIdentifier: instanceID,
        estateIdentifier: estateID,
        binaryVersion: "1.1.0",
        contractRevision: FirstPartyAuthProtocol.contractRevision,
        mcpProtocolVersion: FirstPartyAuthProtocol.mcpProtocolVersion,
        capabilities: [
            DescriptorPublisher.authenticatedFirstPartyCapability,
            "resident-estate",
            "tool-surface",
        ].sorted(),
        // credentialGeneration must match FixedFirstPartyRootProvider's value (1)
        // so the auth server accepts the root on the challenge handshake.
        credentialGeneration: 1,
        descriptorGeneration: 0,
        descriptorMAC: []
    )
    descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
        key: FirstPartyAuthProtocol.descriptorKey(installationRoot: testRoot),
        message: descriptor.macInput()
    )

    let descriptorData = DescriptorPublisher.encode(descriptor)
    let descriptorFile = estateDir.appendingPathComponent("daemon-descriptor.v2.json")
    do {
        // Atomic write: write to a temp file and rename so the harness never reads
        // a partial descriptor (the harness polls until the file is present).
        let tmp = descriptorFile.appendingPathExtension("tmp")
        try descriptorData.write(to: tmp, options: .atomic)
        try FileManager.default.moveItem(at: tmp, to: descriptorFile)
    } catch {
        fputs("mootx01-daemon-contract-host: failed to write descriptor: \(error)\n", stderr)
        return 1
    }

    // ── Step 3: build coordinators via the shared composition function ─────────
    // Uses CommunityResidentMain.makeCommunityDispatch — the SAME function the
    // production daemon calls — with a plaintext key provider (no Keychain in tests)
    // and slow poll intervals (suppress background workers that would interfere with
    // deterministic contract tests).
    let ownerID = "com.mootx01.daemon.contract-host"
    let plaintextKeyProvider: @Sendable (URL) throws -> EstateEncryptionConfig = { _ in .plaintext }
    let providerState = CommunityProviderState(
        instanceIdentifier: instanceID,
        estateIdentifier: estateID
    )
    let communityDispatch: CommunityContractDispatch
    do {
        communityDispatch = try await CommunityResidentMain.makeCommunityDispatch(
            layoutURL: estateDir,
            ownerIdentifier: ownerID,
            keyProvider: plaintextKeyProvider,
            state: providerState,
            // Slow poll intervals: background workers are irrelevant for contract tests,
            // which only exercise the sidecar and tool dispatch layer. Keeping intervals
            // high prevents spurious watcher events from racing with test assertions.
            obsidianWatcherPollSeconds: 600,
            obsidianEstatePollSeconds: 3600,
            obsidianHealthCheckSeconds: 600
        )
    } catch {
        fputs("mootx01-daemon-contract-host: coordinator init failed: \(error)\n", stderr)
        return 1
    }

    // ── Step 4: build auth server + HTTP server ────────────────────────────────
    // FixedFirstPartyRootProvider supplies the test root without Keychain access.
    // credentialGeneration must equal the value embedded in the descriptor (1).
    let rootProvider = FixedFirstPartyRootProvider(root: testRoot, credentialGeneration: 1)
    let authServer = FirstPartyAuthServer(
        rootProvider: rootProvider,
        descriptor: descriptor,
        serverName: "mootx01",
        now: { UInt64(Date().timeIntervalSince1970) },
        randomBytes: ProductionRandomness.secRandomBytes
    )
    let dispatcher = ARIA_MCPDispatcher(
        info: ARIA_MCPDispatcher.ServerInfo(name: "mootx01", version: "1.1.0"),
        communityHandler: communityDispatch
    )
    let server = HTTPServer(
        dispatcher: dispatcher,
        port: requestedPort,
        firstPartyAuth: authServer
    )

    // ── Step 5: SIGTERM handler + serve ───────────────────────────────────────
    // serve(withFD:) exits cooperatively: on Task cancellation it sets the stop
    // flag, calls shutdown()/close() on the fd, and waits for the accept thread
    // to exit before returning — so the process exits cleanly on SIGTERM.
    let shutdownTask = Task {
        await server.serve(withFD: preBound.fd)
    }
    signal(SIGTERM, SIG_IGN)
    let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigSource.setEventHandler { shutdownTask.cancel() }
    sigSource.resume()

    await shutdownTask.value

    return 0
}

// MARK: - No-op community handler (pre-bind phase only)

/// Placeholder handler for the pre-bind HTTPServer.
///
/// The pre-bind server is never told to serve; it only calls bind() to reserve
/// the port. This handler is never dispatched to.
private struct ContractHostNoOpHandler: CommunityToolHandler {
    func isCommunityTool(_ name: String) -> Bool { false }
    var communityToolList: [ProjectedTool] { [] }
    func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        throw JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "no tools")
    }
}

// MARK: - Hex conversion helper

/// Decode a lowercase hex string into a byte array.
/// Returns nil for odd-length strings or non-hex characters.
private func hexToBytes(_ hex: String) -> [UInt8]? {
    guard hex.count % 2 == 0 else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        bytes.append(byte)
        index = next
    }
    return bytes
}
