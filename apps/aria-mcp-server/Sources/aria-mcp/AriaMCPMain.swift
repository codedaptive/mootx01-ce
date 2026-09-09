import Foundation
import AriaMCP
import CorpusKit
import CorpusKitProviders
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitPostgreSQL
import SynapseKit
import AriaResident

// Entry point for the ARIA_MCP server (stdio or loopback HTTP transport,
// selected by MOOTX01_HTTP_PORT).
//
// The estate is selected the way every mootx01 command selects one: through
// the estate catalog. No environment value names a database.
//
//   aria-mcp                       the catalog's active estate
//   aria-mcp --db <name>           a registered estate by name
//   aria-mcp --db <dir>/<name>     a transient estate at that directory,
//                                  attached for this process only
//   aria-mcp --in-memory           the selected estate served from the
//                                  in-memory backend: same protocol and
//                                  algorithms, no filesystem, gone at exit
//
// The record decides the backend. A SQLite record opens `estate.sqlite` in
// its directory under the posture the file requires (EstateOpenPosture: an
// existing encrypted estate loads its existing key and fails closed when it
// is missing; a registered estate is created encrypted; a transient estate
// is plaintext). A PostgreSQL record opens its connection string with a lazy
// pool; the first real I/O is Estate.create, so an unreachable server fails
// there before any tool is dispatched, the same lifecycle point where
// SQLiteStorage.init fails for an unusable file.
//
// Registered estates are this machine's: their Ed25519 identity lives in the
// Keychain and they federate. Transient estates keep their identity in
// memory, never touch the Keychain, and never federate.
//
// The JSON-RPC wire surface (tools, schemas, methods) is the same on every
// backend. Clients do not know or care which backend is active.
//
// Per ARIA_MCP_SPEC §5, stdout is reserved for JSON-RPC frames; all logging
// routes through Logging.stderr.

@main
struct AriaMCPMain {
    static func main() async {
        await AriaMCPMain.run()
    }

    /// The two arguments the binary takes. Anything else is a usage error:
    /// this server has no other configuration on its command line.
    struct Arguments: Equatable {
        var db: String?
        var inMemory = false

        static let usage = "usage: aria-mcp [--db <name> | --db <dir>/<name>] [--in-memory]"

        init(_ arguments: [String]) throws {
            var rest = arguments[...]
            while let argument = rest.popFirst() {
                switch argument {
                case "--db":
                    guard db == nil, let value = rest.popFirst(), !value.hasPrefix("--") else {
                        throw UsageError(argument)
                    }
                    db = value
                case "--in-memory":
                    inMemory = true
                default:
                    throw UsageError(argument)
                }
            }
        }

        struct UsageError: Error, CustomStringConvertible {
            let argument: String
            init(_ argument: String) { self.argument = argument }
            var description: String { "unexpected argument '\(argument)'. \(Arguments.usage)" }
        }
    }

    static func run() async {
        let arguments: Arguments
        do {
            arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("ARIA_MCP fatal: \(error)\n", stderr)
            exit(1)
        }

        let environment = ProcessInfo.processInfo.environment
        let frozen = EstatePosture.resolve(frozenFlag: false, environment: environment) == .frozen
        if frozen && (arguments.inMemory || !(environment["MOOTX01_HTTP_PORT"] ?? "").isEmpty) {
            fputs("ARIA_MCP fatal: frozen mode requires an existing estate over stdio.\n", stderr)
            exit(1)
        }

        // The catalog is the one place that knows which estates exist and
        // where. `--db` selects a registered estate by name or attaches a
        // transient one by path; absent, the active estate serves.
        let catalog: EstateCatalog
        do {
            catalog = try arguments.db.map { try EstateCatalog.open(selecting: $0) } ?? EstateCatalog.open()
        } catch {
            fputs("ARIA_MCP fatal: \(error)\n", stderr)
            exit(1)
        }
        let estate = catalog.active
        let registered = estate.kind == .registered

        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")

        // The catalog decided what kind of estate this is, and the kind decides
        // every Keychain question. nil lets Estate.open resolve the identity
        // store per backend (the Keychain for SQLite); a transient estate's
        // Ed25519 key stays in memory.
        let identityKeyStore: (any EstateIdentityKeyStore)? =
            registered ? nil : InMemoryEstateIdentityKeyStore()

        // The at-rest posture, resolved only for a SQLite record that is going
        // to open its file. Kept for the manifest refresh after prepare.
        var encryption: EstateEncryptionConfig?
        // A PostgreSQL connection string may carry user:password; it is never
        // logged and is redacted from any error text that might echo it.
        var redactedSecret: String?

        let storage: any Storage
        if arguments.inMemory {
            // The estate lives and dies with this process. No Keychain contact:
            // the .inMemory backend resolves the in-memory identity store and no
            // db key exists to mint. Accuracy sweeps only; a durable estate never
            // selects it, and no environment value turns it on.
            Logging.stderr.log("ARIA_MCP starting (estate: \(estate.name) [\(estate.kind.rawValue)], IN-MEMORY backend — exists only for this process)")
            storage = InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        } else {
            switch estate.backend {
            case .postgresql(let connectionString):
                // Lazy pool: no TCP connection is opened here. Pool defaults are
                // PersistenceKit's BackendConfiguration.postgresql defaults
                // (poolSize 10, connectionTimeout 5 s, idleTimeout 300 s). The
                // host is the only part of the connection string that is logged.
                redactedSecret = connectionString
                let host = URL(string: connectionString)?.host ?? "configured"
                Logging.stderr.log("ARIA_MCP starting (estate: \(estate.name) [\(estate.kind.rawValue)], PostgreSQL backend: \(host))")
                storage = PostgreSQLStorage(configuration: EstateConfiguration(
                    estateID: UUID(),
                    backend: .postgresql(connectionString: connectionString)))
            case .sqlite:
                Logging.stderr.log("ARIA_MCP starting (estate: \(estate.name) [\(estate.kind.rawValue)] at \(estate.directory.path), SQLite backend)")
                // Fail closed: never fall back to a plaintext open of an encrypted
                // estate, and never create a new estate over one that would not open.
                if frozen && !FileManager.default.fileExists(atPath: estate.databaseURL.path) {
                    fputs("ARIA_MCP fatal: frozen mode requires an existing estate.\n", stderr)
                    exit(1)
                }
                let resolved: (encryption: EstateEncryptionConfig, posture: EstateOpenPosture.Posture)
                do {
                    resolved = try EstateOpenPosture.resolve(for: estate)
                } catch {
                    fputs("ARIA_MCP fatal: estate encryption posture unavailable: \(error)\n", stderr)
                    exit(1)
                }
                encryption = resolved.encryption
                if !registered {
                    Logging.stderr.log("ARIA_MCP: transient estate — identity in memory, no federation, no Keychain writes")
                } else if resolved.posture == .newPlaintextDeclared {
                    // A declared-plaintext open is never silent: name the posture and
                    // its source, so a downgrade caused by an altered manifest shows.
                    Logging.stderr.log("ARIA_MCP: creating estate UNENCRYPTED — its manifest \(estate.manifestURL.path) declares plaintext. Run `mootx01 upgrade` to encrypt.")
                }
                // busyTimeout 5.0 s is PersistenceKit's sqlite default; enough for
                // one server process with no concurrent writers. The backend creates
                // the directory and the file on first open.
                do {
                    storage = try SQLiteStorage(configuration: EstateConfiguration(
                        estateID: UUID(),
                        backend: .sqlite(url: estate.databaseURL, busyTimeout: 5.0),
                        encryptionConfig: resolved.encryption))
                } catch {
                    fputs("ARIA_MCP fatal: cannot open SQLite at '\(estate.databaseURL.path)': \(error)\n", stderr)
                    exit(1)
                }
            }
        }

        /// Error text with the connection string, if any, replaced.
        func redacted(_ error: any Error) -> String {
            let text = String(describing: error)
            guard let secret = redactedSecret, !secret.isEmpty else { return text }
            return text.replacingOccurrences(of: secret, with: "[REDACTED]")
        }

        // Production model-directory resolver, installed before the estate is
        // opened and wired: the semantic-recall wiring acts on the manifest's
        // `embedding_provider = "encoder"` by building the span encoder from
        // the active registry row, and it can only find the bundled model
        // through this resolver (the kit's default answers nil for every id,
        // which leaves recall lexical-only). Install-wide files such as the
        // bundled models live in the configuration directory; estate files
        // live with the estate.
        await kit.setModelDirectoryResolver(
            BundledModelDirectoryResolver(dataDirectory: EstateCatalog.configurationDirectory))

        let handle: EstateHandle
        do {
            // Estate.create opens the schema idempotently (DrawerStore uses
            // upsert for manifest keys), so calling it on an existing SQLite
            // or PostgreSQL estate is safe: it re-stamps owner_identifier and
            // leaves all other manifest values intact. The subsequent kit.open
            // validates the bitmap layout version and issues the EstateHandle.
            // For PostgreSQL this is where the lazy pool opens its first TCP
            // connection, so an unreachable server surfaces here.
            if !frozen { _ = try await LocusKit.Estate.create(storage: storage, owner: owner) }
            handle = try await kit.open(storage: storage, owner: owner,
                                        identityKeyStore: identityKeyStore, federate: registered, frozen: frozen)
            // This entry point creates on every open (Estate.create above is an
            // idempotent re-stamp), so the create-time default belongs here too:
            // the span encoder becomes the recall stage of an estate that names
            // no provider; an estate that already names one is left alone.
            if !frozen { try await kit.provisionDefaultEncoderIfAbsent(for: handle) }
        } catch {
            Logging.stderr.log("ARIA_MCP fatal: failed to open estate: \(redacted(error))")
            exit(1)
        }

        // Semantic recall wiring, every backend.
        //
        // `kit.open` admits the estate and issues the handle, but it does NOT
        // register a Corpus or VectorStore — so on a bare open the BM25 + vector
        // recall lanes are DARK and `moot_memory_search` degrades to LocusKit
        // row recall. The full composition normally lands at `kit.provision`
        // (EstateLifecycle), which wires Corpus + VectorStore for a `.glk` estate.
        //
        // `provision` is not called here: it also re-stamps the manifest (estate
        // name, kind-prefixed framework profile, zoom window) and is the
        // create-from-scratch surface. Re-running aria-mcp against an EXISTING
        // estate must stay idempotent, as `Estate.create + open` is. Instead the
        // shared `wireGLKSubstores` seam runs — the one canonical post-open
        // wiring path `provision` and `mootx01 serve` also use: build a Corpus
        // and a standalone VectorStore on the same backing storage, register
        // both, and mount the estate's encode queue. `Corpus(storage:models:)`
        // and `VectorStore(storage:)` apply their schema through the backend's
        // idempotent `migrate`, so reopening re-registers against migrated
        // tables and re-reads persisted vectors; nothing is dropped or rewritten.
        do {
            if frozen {
                guard try await EstateFormatStore(storage: storage).readIfPresent() == .current else {
                    throw EstateError.substrateUnavailable("frozen estate requires migration before serving")
                }
            } else {
            let preparation = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: Date())
            // The manifest must say what is on disk: after a migration, or for
            // an estate that predates manifests, rewrite estate.json. Only a
            // SQLite record has a file whose posture the manifest describes.
            if let encryption, try EstateManifestRefresh.afterPrepare(
                preparation, estate: estate, encryption: encryption, now: Date()) {
                Logging.stderr.log("ARIA_MCP: estate manifest refreshed (format \(preparation.format), schema \(GeniusLocusKitSchema.version))")
            }
            }
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage, frozen: frozen)
            // Rebuild + register the matrix tier from the persisted audit log so
            // matrix-driven recall (co-occurrence/temporal scoring — the
            // matrixAware scoring and the matrix/lattice/weighted-all
            // compositions) is live from the FIRST query on a reopened estate.
            // Like Corpus/VectorStore above, the matrix tier is an in-memory
            // DERIVED accelerator rebuilt from durable ground truth (the audit
            // log), not persisted state: a fresh process has matrixTiers[handle]
            // = nil, so without this every matrix score column reads 0.0 until
            // the next in-process dreaming cycle. Same rebuild moot_dream performs
            // as its "un-starving" step; deterministic, so idempotent.
            try await kit.rebuildDerivedAccelerators(for: handle, frozen: frozen)
            Logging.stderr.log("ARIA_MCP recall lit: LocusKit semantic recall (structural/BM25) + CorpusKit/SynapseKit vector recall + matrix tier registered.")
        } catch {
            fputs("ARIA_MCP fatal: cannot wire semantic recall: \(redacted(error))\n", stderr)
            exit(1)
        }

        let info = ARIA_MCPDispatcher.ServerInfo(name: "ARIA_MCP", version: "0.1.0")
        // Server identity injected so facts/memories filed via this host are
        // stamped "aria-mcp-server" — the standalone reference MCP server.
        let tooling = ToolDispatcher(kit: kit, handle: handle, serverIdentity: "aria-mcp-server")
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)

        // Transport select. stdio is the default (testing, migrations, PoC). When
        // MOOTX01_HTTP_PORT is set, run the resident loopback HTTP MCP transport
        // via the shared AriaResident runner — the v1 primary transport for the
        // resident daemon (ARIA_MCP_SPEC §5). Both transports drive the same
        // dispatcher; the JSON-RPC surface is identical. Resident HTTP mode is
        // long-lived (launchd); stdio exits on stdin close.
        let rawHTTPPort = ProcessInfo.processInfo.environment["MOOTX01_HTTP_PORT"] ?? ""
        if !rawHTTPPort.isEmpty {
            guard let portValue = UInt16(rawHTTPPort) else {
                fputs("ARIA_MCP fatal: MOOTX01_HTTP_PORT='\(rawHTTPPort)' is not a valid TCP port (0–65535).\n", stderr)
                exit(1)
            }
            // Resident HTTP mode: pass useDefault: true so the daemon wires
            // PersistenceStatsSink to the moot-mgr default path when
            // ARIA_MCP_STATS_STORE is not set. Telemetry is durable by default
            // in resident mode; stdio mode stays opt-in.
            let statsStorePath = AriaResident.statsStorePathFromEnv(useDefault: true)
            let config = AriaResident.ResidentConfig(
                port: portValue,
                maxBodyBytes: AriaResident.httpMaxBodyBytes(),
                brainTickMs: AriaResident.brainTickMs(),
                monitoringPollMs: AriaResident.monitoringPollMs(),
                statsStorePath: statsStorePath,
                vaultPath: AriaResident.vaultPath(),
                vaultEstatePollSeconds: AriaResident.vaultEstatePollSeconds()
            )
            let gateSuffix = (statsStorePath != nil) ? " + monitoring gate" : ""
            Logging.stderr.log("ARIA_MCP ready (\(dispatcher.tools.count) tools, HTTP transport + autonomic governor\(gateSuffix))")
            do {
                // Resident: returns only on bind failure (the runner otherwise
                // never returns; launchd/SIGTERM ends the process). The runner
                // throws rather than exit()-ing so the caller owns lifecycle.
                try await AriaResident.runResidentDaemon(
                    dispatcher: dispatcher, kit: kit, handle: handle, config: config
                )
            } catch {
                fputs("ARIA_MCP fatal: cannot bind HTTP transport on 127.0.0.1:\(portValue): \(error)\n", stderr)
                exit(1)
            }
            Logging.stderr.log("ARIA_MCP exiting (HTTP transport stopped)")
        } else {
            // stdio: ephemeral, per-client. Startup-once telemetry only (no
            // continuous gate — the process does not outlive the client session).
            // useDefault: false → telemetry off unless ARIA_MCP_STATS_STORE is set.
            let statsStorePath = AriaResident.statsStorePathFromEnv(useDefault: false)
            _ = await AriaResident.installManagerTelemetry(storePath: statsStorePath)
            let server = StdioServer(dispatcher: dispatcher)
            Logging.stderr.log("ARIA_MCP ready (\(dispatcher.tools.count) tools, stdio transport)")
            await server.run()
            Logging.stderr.log("ARIA_MCP exiting (stdin closed)")
        }
    }
}
