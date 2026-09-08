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
// makeCommunityDispatch(host:layoutURL:state:) constructs
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

    /// Stable MCP identity consumed by signed Community/Pro clients during
    /// their authenticated readiness handshake.
    public static let dispatcherServerName = "ARIA_MCP"

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
    public static func run(
        additionalCapabilities: [String] = [],
        firstPartyToolHost: (any FirstPartyToolHost)? = nil
    ) async -> (code: Int32, output: String) {
        #if canImport(Security)
        return await runProduction(
            additionalCapabilities: additionalCapabilities,
            firstPartyToolHost: firstPartyToolHost
        )
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
    private static func runProduction(
        additionalCapabilities: [String],
        firstPartyToolHost: (any FirstPartyToolHost)?
    ) async -> (code: Int32, output: String) {
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
        // The daemon's estate is the catalog's active record, opened once through
        // GeniusLocusKit by this host; the provider's activate() opens it for the
        // readiness proof and every coordinator below shares the same open.
        let estate: CommunityEstateHost
        do {
            estate = try buildEstateHost()
        } catch {
            let out = encodedFailure("estate-host-init-failed: \(error)")
            return (DaemonShellMain.ExitCode.failure.rawValue, out)
        }
        let bind = ProductionBind(reservedFD: preBound.fd, reservedPort: preBound.port)
        let sessions = ProductionSessions()

        // ── Step 3: activate ─────────────────────────────────────────────────
        let provider = DaemonProvider(
            configuration: DaemonProviderConfiguration(
                instanceIdentifier: instanceID,
                binaryVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.1.0",
                capabilities: Array(Set([
                    DescriptorPublisher.authenticatedFirstPartyCapability,
                    "resident-estate",
                    "tool-surface",
                ] + additionalCapabilities)).sorted(),
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

        // Product tools are process infrastructure, so startup belongs to the
        // resident daemon after provider activation and before the HTTP server
        // begins accepting requests. A listener failure tears the provider down
        // and fails startup; the daemon never advertises partial readiness.
        if let firstPartyToolHost {
            do {
                try await firstPartyToolHost.start()
            } catch {
                _ = try? await provider.shutdown()
                let out = encodedFailure("first-party-tool-host-start-failed: \(error)")
                return (DaemonShellMain.ExitCode.failure.rawValue, out)
            }
        }

        // ── Step 4: build real dispatcher + auth server + HTTP server ────────
        let providerState = CommunityProviderState(
            instanceIdentifier: activation.descriptor.instanceIdentifier,
            estateIdentifier: activation.descriptor.estateIdentifier
        )

        // Build all six coordinator families via the shared composition function.
        // The same function is called by mootx01-daemon-contract-host so the
        // harness certifies the composition production runs.
        // The daemon's own state (sidecar JSON files) lives beside the catalog,
        // in the configuration directory, as moot-mgr's stats store does.
        let productionLayoutURL = Self.daemonStateDirectory
        do {
            try FileManager.default.createDirectory(at: productionLayoutURL, withIntermediateDirectories: true)
        } catch {
            let out = encodedFailure("daemon-state-directory-unavailable: \(error)")
            return (DaemonShellMain.ExitCode.failure.rawValue, out)
        }
        let communityDispatch: CommunityContractDispatch
        do {
            communityDispatch = try await CommunityResidentMain.makeCommunityDispatch(
                host: estate,
                layoutURL: productionLayoutURL,
                state: providerState
            )
        } catch {
            await firstPartyToolHost?.stop()
            _ = try? await provider.shutdown()
            let out = encodedFailure("coordinator-init-failed: \(error)")
            return (DaemonShellMain.ExitCode.failure.rawValue, out)
        }

        let dispatcher = ARIA_MCPDispatcher(
            info: ARIA_MCPDispatcher.ServerInfo(
                name: dispatcherServerName,
                version: activation.descriptor.binaryVersion
            ),
            communityHandler: communityDispatch,
            firstPartyHandler: firstPartyToolHost
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
            serverName: dispatcherServerName,
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
        await firstPartyToolHost?.stop()
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

    /// The daemon's state directory: `<configuration directory>/community-daemon`,
    /// beside `estatecatalog.json`. Sidecar JSON files (capture ledger, review
    /// state, Obsidian authorization and state, LAN state, estate metadata and
    /// operation state) live here; the estate lives where its catalog record says.
    static var daemonStateDirectory: URL {
        EstateCatalog.configurationDirectory.appendingPathComponent("community-daemon", isDirectory: true)
    }

    /// Build the CommunityEstateHost over the catalog's active record.
    ///
    /// The catalog, not a path, is the authority: `EstateCatalog.open()` finds
    /// (or on first run creates) the family's catalog in the configuration
    /// directory and its active record is the daemon's estate. The record is
    /// registered, so the host creates it encrypted under the estate key
    /// service and shared access group every other opener on this machine
    /// reads, loads the EXISTING key on reopen and fails closed when that key
    /// is missing rather than minting a wrong one. The owner identifier is the
    /// signed team identifier. Called before DaemonProvider.activate(), whose
    /// step 6 opens the estate through this host under the provider lock.
    private static func buildEstateHost() throws -> CommunityEstateHost {
        let record = try EstateCatalog.open().active
        let ownerIdentifier: String
        if let identity = try? SecCodeEntitlementReadback().processIdentity() {
            ownerIdentifier = identity.teamIdentifier ?? "unknown"
        } else {
            ownerIdentifier = "unknown"
        }
        return CommunityEstateHost(record: record, kit: GeniusLocusKit(), ownerIdentifier: ownerIdentifier)
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
    ///   - host: The daemon's estate host over the catalog record. Opened here
    ///     once (Obsidian sync and transfer need the open handle at
    ///     construction); the lifecycle, capture and review coordinators share
    ///     the same open. A transient record (contract tests, proof hosts) is
    ///     plaintext with its identity in memory, so a terminated test host
    ///     leaves no Keychain residue; a registered record (production) is the
    ///     machine's own.
    ///   - layoutURL: The daemon's state directory for the sidecar JSON files.
    ///     In production `<configuration directory>/community-daemon/`; in
    ///     contract tests a temp dir.
    ///   - state: The provider state (instance + estate UUIDs). In production, sourced
    ///     from `ProviderActivation.descriptor`; in contract tests, synthetic UUIDs.
    ///   - obsidianWatcherPollSeconds: Watcher poll interval for `CommunityObsidianCoordinator`.
    ///     Production uses the default (10 s); contract tests pass a large value (600 s)
    ///     to suppress background activity that would interfere with deterministic tests.
    ///   - obsidianEstatePollSeconds: Estate poll interval for obsidian. Same intent.
    ///   - obsidianHealthCheckSeconds: Health-check interval for obsidian. Same intent.
    public static func makeCommunityDispatch(
        host: CommunityEstateHost,
        layoutURL: URL,
        state: CommunityProviderState,
        obsidianWatcherPollSeconds: Int = 10,
        obsidianEstatePollSeconds: Int = 60,
        obsidianHealthCheckSeconds: Int = 30
    ) async throws -> CommunityContractDispatch {
        // lifecycle + capture + review share the host and the state directory.
        // None of them perform IO at init time; they reach the estate through
        // the host on first tool call.
        let lifecycle = CommunityEstateLifecycleCoordinator(host: host, layoutURL: layoutURL)
        let capture = CommunityCaptureCoordinator(host: host, layoutURL: layoutURL)
        let review = CommunityReviewCoordinator(host: host, layoutURL: layoutURL)
        // obsidian + transfer compose on GeniusLocusKit and need the open handle
        // now: one estate, the same the coordinators above read and write.
        let handle: EstateHandle
        do {
            handle = try await host.handle()
        } catch {
            throw CommunityResidentError.estateOpenFailed(error)
        }
        let kit = host.kit
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
    case estateOpenFailed(Error)
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
