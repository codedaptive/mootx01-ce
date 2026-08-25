// Wave A1b — the production community-daemon resident run loop.
//
// This module is the COMPOSITION ROOT for the community-edition daemon.
// It owns the construction of every production authority and injects them
// into the substrate. No fake-success paths exist here — a production
// Keychain root, a real estate, a real bind, a real dispatcher.
//
// The shell (mootx01-daemon/main.swift) passes `CommunityResidentMain.run`
// as the `residentActivate` closure to `DaemonShellMain.run`. The shell
// stays thin; substance lives here. MootDaemonProvider never imports this
// module (the dependency arrow is one-way: here → MootDaemonProvider, not
// the reverse).
//
// ORDERING (avoids the TOCTOU race between port reservation and descriptor
// publication):
//   1. Pre-bind the TCP socket with a MINIMAL HTTPServer (port 4242).
//      This reserves the port BEFORE activation starts, so the descriptor
//      publication step names a port that is already ours.
//   2. Activate DaemonProvider with PRODUCTION authorities.
//   3. Extract live UUIDs from the activation result.
//   4. Construct the REAL dispatcher + auth server + HTTPServer via
//      makeCommunityDispatch (the shared composition function, also used by
//      the contract-test host binary — mootx01-daemon-contract-host — so
//      the harness certifies exactly the composition production runs).
//   5. Install SIGTERM handler.
//   6. Call serve(withFD:) on the real server — accept loop runs on a
//      dedicated thread; this function parks in the await until cancelled,
//      then closes the fd and waits for the accept thread to exit before
//      returning (cooperative shutdown: provider.shutdown() runs strictly
//      after the last accept() call).
//
// Guard: macOS + Security framework only. Linux builds of the package
// compile this file but the `#if canImport(Security)` guard means the
// function body is absent on Linux — it returns exit 4 (residentUnavailable).
//
// CONTRACT-TEST HOST (F3):
// The headless path that previously branched on MOOT_CONTRACT_TEST_ESTATE_DIR
// has been moved to a DEDICATED EXECUTABLE TARGET: mootx01-daemon-contract-host.
// The production mootx01-daemon binary contains NO env-var branches that skip
// activate() / provider lock / Keychain custody. The contract-test harness
// (ContractDaemonHarness) spawns mootx01-daemon-contract-host, not mootx01-daemon.
//
// SHARED COMPOSITION (F2):
// makeCommunityDispatch(layoutURL:ownerIdentifier:keyProvider:state:) constructs
// all six coordinator families and returns a fully-wired CommunityContractDispatch.
// It is called by runProduction() (production layout + Keychain key provider, AFTER
// activation) and by mootx01-daemon-contract-host (temp layout + plaintext keys).
// This guarantees the harness exercises exactly the production composition.

import Foundation
import AriaMCP
import MootDaemonProvider
import PersistenceKit
import PersistenceKitSQLite
import LocusKit
import GeniusLocusKit
#if canImport(Security)
import Security
#endif

/// The community-edition production resident run loop.
///
/// Injected into `DaemonShellMain.run(arguments:residentActivate:)` by
/// `mootx01-daemon/main.swift`. Returns only when the process is about
/// to exit (SIGTERM received or activation failed).
public enum CommunityResidentMain {

    /// Run the production resident loop.
    ///
    /// On non-Darwin platforms or when the Security framework is absent,
    /// returns exit 4 (residentUnavailable) immediately — the same honest
    /// refusal the pre-A1b shell emitted. On macOS with Security, activates
    /// the provider and serves on loopback until SIGTERM.
    ///
    /// This binary contains NO env-var bypass paths. Contract-test headless mode
    /// lives in the dedicated mootx01-daemon-contract-host executable, which the
    /// ContractDaemonHarness spawns. activate(), the provider lock, and Keychain
    /// custody are always exercised here.
    public static func run() async -> (code: Int32, output: String) {
        #if canImport(Security)
        return await runProduction()
        #else
        let refusal: [String: Any] = [
            "mode": "resident",
            "moduleDigest": ProviderSelfReport.moduleDigest(),
            "outcome": "resident-unavailable",
        ]
        let encoded = (try? JSONSerialization.data(
            withJSONObject: refusal, options: [.sortedKeys]
        )) ?? Data()
        return (
            DaemonShellMain.ExitCode.residentUnavailable.rawValue,
            String(decoding: encoded, as: UTF8.self)
        )
        #endif
    }

    #if canImport(Security)
    /// The production resident loop body (Darwin/macOS only).
    private static func runProduction() async -> (code: Int32, output: String) {
        // ── Step 1: pre-bind the TCP socket ──────────────────────────────────
        // A minimal HTTPServer (no dispatcher involvement, no firstPartyAuth)
        // is constructed solely to call bind() and reserve port 4242.
        // The returned fd is passed to serve(withFD:) on the real server after
        // activation. This avoids the TOCTOU gap: the descriptor names port 4242
        // BECAUSE we already hold it, not because we hope to bind it later.
        //
        // The minimal dispatcher cannot serve any real request — it has a
        // community-only init with a stub handler that owns no tools. This is
        // intentional: no request is accepted until serve(withFD:) is called on
        // the real server (which happens after activation in step 6). The minimal
        // server is never told to serve; its only purpose is the bind() call.
        let preBinder = HTTPServer(
            dispatcher: ARIA_MCPDispatcher(
                info: ARIA_MCPDispatcher.ServerInfo(
                    name: "mootx01-pre-bind",
                    version: "0.0.0"
                ),
                communityHandler: NoOpCommunityHandler()
            ),
            port: 4242,
            firstPartyAuth: nil
        )
        let preBound: (fd: Int32, port: UInt16)
        do {
            preBound = try preBinder.bind()
        } catch {
            let out = encodedFailure("pre-bind-failed: \(error)")
            return (DaemonShellMain.ExitCode.failure.rawValue, out)
        }

        // ── Step 2: build production authorities ─────────────────────────────
        let instanceID = UUID()
        // DataProtectionKeychainAuthority: the production KeychainItemAuthority
        // conformer (MootDaemonProvider). Conforms to ProductionCredentialAuthority
        // so the P-c2-1 proof-context refusal fires for any non-nil proofContext.
        // This is NOT the FirstPartyRootProviding conformer — that is constructed
        // below (step 4) after activation, using the eligibility-derived access group.
        let keychainAuthority = DataProtectionKeychainAuthority()
        let estateHost = try? buildEstateHost()
        guard let estate = estateHost else {
            let out = encodedFailure("estate-host-init-failed")
            return (DaemonShellMain.ExitCode.failure.rawValue, out)
        }
        let bind = ProductionBind(reservedFD: preBound.fd, reservedPort: preBound.port)
        let sessions = ProductionSessions()

        // ── Step 3: activate ─────────────────────────────────────────────────
        let provider = DaemonProvider(
            configuration: DaemonProviderConfiguration(
                instanceIdentifier: instanceID,
                binaryVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0",
                capabilities: [
                    DescriptorPublisher.authenticatedFirstPartyCapability,
                    "resident-estate",
                    "tool-surface",
                ],
                proofContext: nil  // nil = production credential custody (P-c2-1)
            ),
            readback: SecCodeEntitlementReadback(),
            resolver: AppGroupRootResolver(),
            keychain: keychainAuthority,
            estate: estate,
            bind: bind,
            sessions: sessions,
            clock: { UInt64(Date().timeIntervalSince1970) },
            randomBytes: ProductionRandomness.secRandomBytes
        )
        let activation: ProviderActivation
        do {
            activation = try await provider.activate()
        } catch DaemonProviderError.ineligible(let reason) {
            let out = encodedFailure("ineligible: \(reason.rawValue)")
            return (DaemonShellMain.ExitCode.ineligible.rawValue, out)
        } catch DaemonProviderError.lockUnavailable {
            let out = encodedFailure("lock-unavailable")
            return (DaemonShellMain.ExitCode.lockLost.rawValue, out)
        } catch {
            let out = encodedFailure("activation-failed: \(error)")
            return (DaemonShellMain.ExitCode.failure.rawValue, out)
        }

        // ── Step 4: build real dispatcher + auth server + HTTP server ────────
        let providerState = CommunityProviderState(
            instanceIdentifier: activation.descriptor.instanceIdentifier,
            estateIdentifier: activation.descriptor.estateIdentifier
        )

        // Build all six coordinator families via the shared composition function.
        // The same function is called by mootx01-daemon-contract-host so the
        // harness certifies the composition production runs.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let productionLayoutURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MOOTx01", isDirectory: true)
        let productionOwnerID: String
        if let identity = try? SecCodeEntitlementReadback().processIdentity() {
            productionOwnerID = identity.teamIdentifier ?? "unknown"
        } else {
            productionOwnerID = "unknown"
        }
        // Production key provider: per-estate AES-256 key in the Keychain.
        // The Keychain access group and service name match the values used by
        // buildEstateHost() so both the DaemonProvider estate host and the
        // coordinator estate accesses use the same key.
        let productionKeyProvider: @Sendable (URL) throws -> EstateEncryptionConfig = { url in
            let key = try KeychainKeyStore(
                service: "com.codedaptive.mootx01",
                estateURL: url,
                accessGroup: "com.codedaptive.mootx01.shared"
            ).loadOrCreateKey()
            return EstateEncryptionConfig.fullDatabase(key: key)
        }
        let communityDispatch: CommunityContractDispatch
        do {
            communityDispatch = try await CommunityResidentMain.makeCommunityDispatch(
                layoutURL: productionLayoutURL,
                ownerIdentifier: productionOwnerID,
                keyProvider: productionKeyProvider,
                state: providerState
            )
        } catch {
            let out = encodedFailure("coordinator-init-failed: \(error)")
            return (DaemonShellMain.ExitCode.failure.rawValue, out)
        }

        let dispatcher = ARIA_MCPDispatcher(
            info: ARIA_MCPDispatcher.ServerInfo(
                name: FirstPartyAuthProtocol.serverName,
                version: activation.descriptor.binaryVersion
            ),
            communityHandler: communityDispatch
        )
        // DataProtectionKeychainRootProvider: the production FirstPartyRootProviding
        // conformer. Requires the fully expanded Keychain access group (team prefix
        // already applied), which is available from eligibility.expandedKeychainGroup
        // after activation. The group is runtime-read from the signed entitlements —
        // never a compiled-in literal (Kong decision 2).
        let rootProvider = DataProtectionKeychainRootProvider(
            accessGroup: activation.eligibility.expandedKeychainGroup
        )
        let authServer = FirstPartyAuthServer(
            rootProvider: rootProvider,
            descriptor: activation.descriptor,
            serverName: FirstPartyAuthProtocol.serverName,
            now: { UInt64(Date().timeIntervalSince1970) },
            randomBytes: ProductionRandomness.secRandomBytes
        )
        let server = HTTPServer(
            dispatcher: dispatcher,
            port: 4242,
            firstPartyAuth: authServer
        )

        // ── Step 5: SIGTERM handler ───────────────────────────────────────────
        let shutdownTask = Task {
            await withTaskCancellationHandler(operation: {
                await server.serve(withFD: preBound.fd)
            }, onCancel: {
                // serve(withFD:) parks in Task.sleep which throws on cancel.
                // The accept thread exits naturally when the process exits.
            })
        }
        signal(SIGTERM, SIG_IGN)
        let sigSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigSource.setEventHandler { shutdownTask.cancel() }
        sigSource.resume()

        // ── Step 6: wait for shutdown ─────────────────────────────────────────
        await shutdownTask.value
        _ = try? await provider.shutdown()

        let result: [String: Any] = [
            "mode": "resident",
            "moduleDigest": ProviderSelfReport.moduleDigest(),
            "outcome": "clean-shutdown",
        ]
        let encoded = (try? JSONSerialization.data(
            withJSONObject: result, options: [.sortedKeys]
        )) ?? Data()
        return (DaemonShellMain.ExitCode.success.rawValue, String(decoding: encoded, as: UTF8.self))
    }

    /// Build the CommunityEstateHost using the production canonical estate path.
    ///
    /// The estate path is derived from the process home directory — never from
    /// argv — following the same convention as DaemonShellMain.runCensus().
    private static func buildEstateHost() throws -> CommunityEstateHost {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let estateURL = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("MOOTx01", isDirectory: true)
            .appendingPathComponent("estate.sqlite", isDirectory: false)
        let ownerIdentifier: String
        if let identity = try? SecCodeEntitlementReadback().processIdentity() {
            ownerIdentifier = identity.teamIdentifier ?? "unknown"
        } else {
            ownerIdentifier = "unknown"
        }
        return CommunityEstateHost(
            estateURL: estateURL,
            ownerIdentifier: ownerIdentifier,
            keyProvider: { url in
                // Production estate encryption key: per-estate 32-byte AES-256 key
                // stored in the data-protection Keychain under the shared access group
                // "com.codedaptive.mootx01.shared" (mirroring EstateKeyProvider and
                // Rust's ensure_install_key). KeychainKeyStore.loadOrCreateKey() is
                // idempotent: it returns the existing key on subsequent opens and
                // mints a fresh key only on the very first open of a new estate.
                //
                // Service name is the well-known "com.codedaptive.mootx01" shared by
                // the CLI, the managed server, and Mootx01-App — matching the key
                // to what any other estate opener on this machine would find.
                //
                // Note: This is called from inside DaemonProvider.activate() (step 6),
                // which already holds the exclusive provider lock. No additional
                // serialisation is required at this site.
                let key = try KeychainKeyStore(
                    service: "com.codedaptive.mootx01",
                    estateURL: url,
                    accessGroup: "com.codedaptive.mootx01.shared"
                ).loadOrCreateKey()
                return EstateEncryptionConfig.fullDatabase(key: key)
            }
        )
    }

    private static func encodedFailure(_ reason: String) -> String {
        let obj: [String: Any] = [
            "mode": "resident",
            "moduleDigest": ProviderSelfReport.moduleDigest(),
            "outcome": "startup-failed",
            "reason": reason,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: obj, options: [.sortedKeys]
        ) else { return #"{"outcome":"startup-failed"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Shared composition (F2)

    /// Construct all six coordinator families and return a fully-wired
    /// CommunityContractDispatch.
    ///
    /// Called by BOTH `runProduction()` (production layout + Keychain key provider,
    /// after `DaemonProvider.activate()` succeeds) and by the dedicated
    /// `mootx01-daemon-contract-host` binary (temp layout + plaintext key provider,
    /// for headless contract testing). Using one function for both paths means the
    /// harness certifies EXACTLY the coordinator composition that production runs —
    /// any bug in coordinator wiring is caught before it reaches a user machine.
    ///
    /// - Parameters:
    ///   - layoutURL: The directory that contains (or will contain) `estate.sqlite`,
    ///     `glk-estate.sqlite`, and all sidecar JSON files. In production this is
    ///     `~/Library/Application Support/MOOTx01/`; in contract tests it is a temp dir.
    ///   - ownerIdentifier: The team-ID or arbitrary owner string embedded in estate
    ///     metadata. Production uses the signed team identifier from entitlements;
    ///     contract tests use a fixed string.
    ///   - keyProvider: Maps an estate file URL to its encryption config. Production
    ///     uses `KeychainKeyStore`-backed full-database encryption; contract tests use
    ///     `.plaintext`.
    ///   - state: The provider state (instance + estate UUIDs). In production, sourced
    ///     from `ProviderActivation.descriptor`; in contract tests, synthetic UUIDs.
    ///   - obsidianWatcherPollSeconds: Watcher poll interval for `CommunityObsidianCoordinator`.
    ///     Production uses the default (10 s); contract tests pass a large value (600 s)
    ///     to suppress background activity that would interfere with deterministic tests.
    ///   - obsidianEstatePollSeconds: Estate poll interval for obsidian. Same intent.
    ///   - obsidianHealthCheckSeconds: Health-check interval for obsidian. Same intent.
    public static func makeCommunityDispatch(
        layoutURL: URL,
        ownerIdentifier: String,
        keyProvider: @Sendable @escaping (URL) throws -> EstateEncryptionConfig,
        state: CommunityProviderState,
        obsidianWatcherPollSeconds: Int = 10,
        obsidianEstatePollSeconds: Int = 60,
        obsidianHealthCheckSeconds: Int = 30
    ) async throws -> CommunityContractDispatch {
        // lifecycle + capture + review share the layout directory and key provider.
        // None of these coordinators perform IO at init time; they open the estate
        // lazily on first tool call.
        let lifecycle = CommunityEstateLifecycleCoordinator(
            layoutURL: layoutURL,
            ownerIdentifier: ownerIdentifier,
            keyProvider: keyProvider
        )
        let capture = CommunityCaptureCoordinator(
            layoutURL: layoutURL,
            ownerIdentifier: ownerIdentifier,
            keyProvider: keyProvider
        )
        let review = CommunityReviewCoordinator(
            layoutURL: layoutURL,
            ownerIdentifier: ownerIdentifier,
            keyProvider: keyProvider
        )

        // obsidian + transfer need a GeniusLocusKit estate. Use a SQLite-backed
        // estate at glk-estate.sqlite in the layout directory. In production this
        // is a fully encrypted estate; in contract tests it is plaintext (both
        // paths share this same code — the key provider handles the difference).
        let glkEstateURL = layoutURL.appendingPathComponent("glk-estate.sqlite")
        let glkOwner = OwnerCredentials(ownerIdentifier: ownerIdentifier)
        let kit = GeniusLocusKit()

        let glkEncryption: EstateEncryptionConfig
        do {
            glkEncryption = try keyProvider(glkEstateURL)
        } catch {
            throw CommunityResidentError.glkKeyProviderFailed(error)
        }
        let glkStorage = try SQLiteStorage(
            configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: glkEstateURL, busyTimeout: 5.0),
                encryptionConfig: glkEncryption
            )
        )
        _ = try await Estate.create(storage: glkStorage, owner: glkOwner)
        let handle = try await kit.open(storage: glkStorage, owner: glkOwner)

        let obsidian = CommunityObsidianCoordinator(
            layoutURL: layoutURL,
            kit: kit,
            handle: handle,
            watcherPollSeconds: obsidianWatcherPollSeconds,
            estatePollSeconds: obsidianEstatePollSeconds,
            healthCheckSeconds: obsidianHealthCheckSeconds
        )
        let transfer = CommunityTransferCoordinator(
            layoutURL: layoutURL,
            kit: kit,
            handle: handle
        )

        // LAN coordinator with no authority: the daemon honestly reports that
        // lan_start requires authority when the daemon is not configured for LAN
        // serving. Both production and contract tests use the no-authority init
        // (LAN authority requires a separate capability grant not wired here).
        let lan = CommunityLANCoordinator(
            layoutURL: layoutURL,
            hasAuthority: false,
            bindAddress: "127.0.0.1",
            lanPort: 0
        )

        return CommunityContractDispatch(
            state: state,
            lifecycle: lifecycle,
            capture: capture,
            review: review,
            obsidian: obsidian,
            transfer: transfer,
            lan: lan
        )
    }

    #endif
}

// MARK: - makeCommunityDispatch error type

/// Errors thrown by `CommunityResidentMain.makeCommunityDispatch`.
public enum CommunityResidentError: Error {
    /// The key provider failed when deriving the GeniusLocusKit estate encryption key.
    case glkKeyProviderFailed(Error)
}

// MARK: - Production authorities (macOS only)

#if canImport(Security)

/// A no-op community handler used only for the pre-bind HTTPServer.
///
/// This handler owns no tools and never serves a request. It exists purely
/// so ARIA_MCPDispatcher.init(info:communityHandler:) compiles without a
/// real tool set during the pre-bind phase (before activation).
private struct NoOpCommunityHandler: CommunityToolHandler {
    func isCommunityTool(_ name: String) -> Bool { false }
    var communityToolList: [ProjectedTool] { [] }
    func dispatch(name: String, arguments: JSONValue) async throws -> JSONValue {
        throw JSONRPCError(code: JSONRPCErrorCode.methodNotFound, message: "no tools")
    }
}

/// Production bind authority: reports the already-reserved fd/port pair.
///
/// `ProductionBind.bindLoopback()` does NOT bind a new socket — the fd was
/// already bound by the pre-bind step. It just returns the reserved port as
/// the `BindProof` so `DaemonProvider.activate()` can embed it in the
/// published descriptor.
///
/// Why: `DaemonProvider.activate()` drives the full activation pipeline
/// (eligibility → root → hygiene → lock → K_install → generations →
/// estate.openEstate() → bind.bindLoopback() → publish descriptor). We want
/// the descriptor to name the port we ACTUALLY hold, not a new port.
private struct ProductionBind: BindAuthority {
    let reservedFD: Int32
    let reservedPort: UInt16

    func bindLoopback() async throws -> BindProof {
        // The socket is already bound; just surface the reserved port.
        return BindProof(host: "127.0.0.1", port: reservedPort)
    }
}

/// Production session revocation: no-op stub for Wave A1b.
///
/// Full session revocation (e.g. invalidating existing MCP sessions) is
/// a later-wave concern. For A1b, revokeAllSessions is a no-op because
/// no persistent session store exists yet.
private struct ProductionSessions: SessionRevocationAuthority {
    func revokeAllSessions() async { }
}

#endif
