import Foundation
import AriaMCP
import CorpusKit
import CorpusKitProviders
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitPostgreSQL
import VectorKit
import AriaResident

// Entry point for the ARIA_MCP server (stdio or loopback HTTP transport,
// selected by MOOTX01_HTTP_PORT).
//
// Backend selection follows a four-state precedence ladder driven by two
// environment variables. No trimming on either variable — a whitespace-only
// value is treated as a non-empty string and fails fast as a config error,
// not a silent fallback (byte-for-byte parity with the Rust server's from_env).
//
// Precedence table (evaluated at startup, in order):
//
//   Both ARIA_MCP_POSTGRES_URL and ARIA_MCP_SQLITE_PATH set (non-empty)
//     → Ambiguous config: clear stderr message naming both vars; exit 1.
//       Never pick silently — the operator must resolve the ambiguity.
//
//   Only ARIA_MCP_POSTGRES_URL set (non-empty)
//     → PostgreSQLStorage at that connection string (pooled, lazy — the
//       pool opens connections on first use; a connectivity failure
//       surfaces at Estate.create/kit.open, before any tool is dispatched).
//       Pool defaults: poolSize=10, connectionTimeout=5s, idleTimeout=300s
//       (PersistenceKit BackendConfiguration defaults; read from
//       EstateConfiguration.BackendConfiguration.postgresql parameters).
//
//   Only ARIA_MCP_SQLITE_PATH set (non-empty)
//     → SQLiteStorage at that path (WAL-mode, durable across restarts).
//       Parent directories are created automatically. An unusable path
//       causes a clear stderr message and a nonzero exit.
//
//   Neither set (both absent or empty)
//     → InMemoryStorage (ephemeral, discarded on exit; v1.0 default).
//
// The JSON-RPC wire surface (tools, schemas, methods) is unchanged for all
// backends. Clients do not need to know or care which backend is active.
//
// Per ARIA_MCP_SPEC_v0.2 §5, stdout is reserved for JSON-RPC frames;
// all logging routes through Logging.stderr.
//
// Lazy-vs-probe decision (PostgreSQL): PostgreSQLStorage uses a lazy
// connection pool — no TCP connection is opened in the constructor.
// The first real I/O occurs at Estate.create (which calls storage.open),
// so an unreachable server surfaces at startup before any tool call is
// dispatched. No explicit probe is needed; the estate-open call IS the
// probe. This is the same fail-fast point as SQLite (SQLiteStorage.init
// is the probe there). Both backends fail fast at the same lifecycle stage.

@main
struct AriaMCPMain {
    static func main() async {
        await AriaMCPMain.run()
    }

    static func run() async {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")

        // Read both env vars. No trimming on either — exact parity with the
        // Rust server's from_env. Present and non-empty → the operator
        // intended that backend; a whitespace-only value is a config error
        // that fails fast, not a silent fallback.
        let rawPostgresURL = ProcessInfo.processInfo.environment["ARIA_MCP_POSTGRES_URL"] ?? ""
        let rawSQLitePath = ProcessInfo.processInfo.environment["ARIA_MCP_SQLITE_PATH"] ?? ""

        let storage: any Storage

        // All three backends wire the LocusKit semantic recall lane and the
        // CorpusKit/VectorKit vector recall lane after `open`. LocusKit owns
        // LocusKit-native semantic recall (structural, BM25, matrix-tier).
        // CorpusKit + VectorStore own the dense float vector recall lane (Lane D).
        //
        // Lane D uses CorpusEnsemble.defaultEnsemble() — the canonical 1.0
        // five-signal recall ensemble (RI / PPMI / LSA / NMF / FDC). All five
        // are model-free and self-contained: the trainable distributional /
        // matrix signals (RI/PPMI/LSA/NMF) train on the estate's own corpus and
        // persist their bases; FDC is a stateless lattice co-classification
        // signal. Each signal embeds under its own modelID and the dense lane
        // fuses them, so recall reflects honest distributional + taxonomic
        // structure — not a single surface/lexical hash.
        //
        // The learned semantic vector (MiniLM/MPNet/Gemma model providers) is an
        // ADDITIVE v1.1 on-device lane for richer similarity — it does not replace
        // this default ensemble. Being model-dependent, those learned providers
        // cannot serve as a federation-reproducible vector (weights differ across
        // devices); the five-signal ensemble is reproducible cross-port.
        //
        // The wiring step that happens after `open` below sets this to true;
        // each backend branch sets `wireSemanticRecall = true` unconditionally.
        var wireSemanticRecall = false

        if !rawPostgresURL.isEmpty && !rawSQLitePath.isEmpty {
            // Ambiguous config: both vars set. Never pick silently — the
            // operator must resolve the ambiguity by unsetting one of them.
            fputs(
                "ARIA_MCP fatal: ambiguous config — both ARIA_MCP_POSTGRES_URL and " +
                "ARIA_MCP_SQLITE_PATH are set. Unset one to select the intended backend.\n",
                stderr
            )
            exit(1)
        } else if !rawPostgresURL.isEmpty {
            // Only ARIA_MCP_POSTGRES_URL set → PostgreSQL-backed estate.
            // PostgreSQLStorage uses a lazy connection pool (no TCP connection
            // opened here). The pool defaults match PersistenceKit's
            // BackendConfiguration.postgresql defaults:
            //   poolSize: 10, connectionTimeout: 5.0s, idleTimeout: 300.0s
            // A connectivity failure surfaces at Estate.create/kit.open below.
            // Redact userinfo before logging — rawPostgresURL may contain
            // user:password@host which would leak credentials to stderr/log aggregators.
            // URL(string:) parses standard postgres:// format; keyword-value strings
            // (e.g. "host=... user=... password=...") are not URL-parseable and fall
            // back to "configured" so no connection details appear in logs.
            let redactedHost = URL(string: rawPostgresURL)?.host ?? "configured"
            Logging.stderr.log("ARIA_MCP starting (stdio, PostgreSQL backend: \(redactedHost))")
            let configuration = EstateConfiguration(
                estateID: UUID(),
                backend: .postgresql(connectionString: rawPostgresURL)
            )
            // PostgreSQLStorage.init is non-throwing (lazy pool); errors
            // surface at Estate.create / kit.open when the first connection
            // is attempted. Semantic recall is wired after open using the
            // same storage handle (shared pool connection, same PG schema).
            storage = PostgreSQLStorage(configuration: configuration)
            wireSemanticRecall = true
        } else if !rawSQLitePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Only ARIA_MCP_SQLITE_PATH set → SQLite-backed durable estate.
            let dbURL = URL(fileURLWithPath: rawSQLitePath)
            Logging.stderr.log("ARIA_MCP starting (stdio, SQLite backend: \(rawSQLitePath))")

            // Create parent directories so the caller does not need to
            // pre-create them. Bare filenames (no directory component) skip
            // creation entirely — exact parity with the Rust server's
            // empty-parent guard (server.rs from_env) — so a read-only cwd
            // does not fail a path that needs no directory created.
            if rawSQLitePath.contains("/") {
                let parentDir = dbURL.deletingLastPathComponent()
                do {
                    try FileManager.default.createDirectory(
                        at: parentDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                } catch {
                    fputs(
                        "ARIA_MCP fatal: cannot create parent directory '\(parentDir.path)': \(error)\n",
                        stderr
                    )
                    exit(1)
                }
            }

            // Construct the SQLite storage. busyTimeout of 5.0 seconds is
            // the PersistenceKit BackendConfiguration.sqlite default; sufficient
            // for a single-process server with no concurrent writers.
            // Whole-file encryption (ADR-014): open the estate as FullDatabase
            // with this estate's per-estate key from the Keychain (keyed by the
            // estate file path), so the file — schema and content — is
            // SQLCipher-encrypted at rest. The app and this server point at the
            // same file, so they derive the same account and load the same key;
            // the shared keychain access group (verified on a signed build) lets
            // them read the same item.
            do {
                let dbKey = try KeychainKeyStore(service: "com.codedaptive.mootx01", estateURL: dbURL).loadOrCreateKey()
                let configuration = EstateConfiguration(
                    estateID: UUID(),
                    backend: .sqlite(url: dbURL, busyTimeout: 5.0),
                    encryptionConfig: .fullDatabase(key: dbKey)
                )
                storage = try SQLiteStorage(configuration: configuration)
            } catch {
                fputs(
                    "ARIA_MCP fatal: cannot open SQLite at '\(rawSQLitePath)': \(error)\n",
                    stderr
                )
                exit(1)
            }
            // Durable, explicit-path estate → wire LocusKit semantic recall
            // (structural/BM25) and CorpusKit/VectorKit deterministic vector
            // recall (Lane D) after `open`.
            wireSemanticRecall = true
        } else {
            // Neither set → in-memory ephemeral estate. The estate UUID is
            // fresh each run so the server serves one ephemeral estate per
            // process, matching the v1.0 owner-by-default credential model.
            // Both recall lanes (LocusKit semantic + CorpusKit/VectorKit vector)
            // are wired after open using the same InMemoryStorage handle — all
            // tables coexist in one instance. BM25 + deterministic Lane D are
            // live from the first capture, same as the SQLite branch.
            Logging.stderr.log("ARIA_MCP starting (stdio, in-memory backend)")
            let configuration = EstateConfiguration(estateID: UUID(), backend: .inMemory)
            storage = InMemoryStorage(configuration: configuration)
            wireSemanticRecall = true
        }

        let handle: EstateHandle
        do {
            // Estate.create opens the schema idempotently (DrawerStore uses
            // upsert for manifest keys), so calling it on an existing SQLite
            // or PostgreSQL estate is safe: it re-stamps owner_identifier and
            // leaves all other manifest values intact. The subsequent kit.open
            // validates the bitmap layout version and issues the EstateHandle.
            // For PostgreSQL, this is also the point where the lazy pool opens
            // its first real TCP connection — a connectivity failure surfaces
            // here as a thrown error.
            _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
            handle = try await kit.open(storage: storage, owner: owner)
        } catch {
            // Redact the raw PostgreSQL connection string from error descriptions —
            // storage errors may propagate the full connection string (which can contain
            // user:password) when the URL fails to parse or the connection is refused.
            // Replace any verbatim occurrence of rawPostgresURL with "[REDACTED]"
            // before logging so credentials never appear in stderr.
            let safeDescription = rawPostgresURL.isEmpty
                ? String(describing: error)
                : String(describing: error).replacingOccurrences(of: rawPostgresURL, with: "[REDACTED]")
            Logging.stderr.log("ARIA_MCP fatal: failed to open estate: \(safeDescription)")
            exit(1)
        }

        // Semantic recall wiring (all backends: in-memory, SQLite, PostgreSQL).
        //
        // `kit.open` admits the estate and issues the handle, but it does NOT
        // register a Corpus or VectorStore — so on a bare open the BM25 + vector
        // recall lanes are DARK and `moot_memory_search` degrades to LocusKit
        // row recall. The full composition normally lands at `kit.provision`
        // (EstateLifecycle), which wires Corpus + VectorStore for a `.glk` estate.
        //
        // We do NOT call `provision` here: `provision` also re-stamps the manifest
        // (estate name, kind-prefixed framework profile, zoom window) and is the
        // create-from-scratch surface. Re-running aria-mcp against an EXISTING
        // on-disk estate must remain idempotent — today's `Estate.create + open`
        // is idempotent and we must not regress that. Instead we call the shared
        // `wireGLKSubstores` seam — the single canonical post-open wiring path that
        // `provision` and `mootx01 serve` also use: build a Corpus and a standalone
        // VectorStore on the same backing storage, register both, and mount the
        // estate's encode queue.
        //
        // Backend-specific notes:
        // - SQLite: Corpus + VectorStore share the same storage instance as the
        //   DrawerStore. Schema migrations are idempotent; re-opening the same
        //   path re-registers against already-migrated tables without data loss.
        // - In-memory: Corpus + VectorStore share the same InMemoryStorage
        //   instance as the DrawerStore. Tables are disjoint namespaces within
        //   the single in-process store. Ephemeral — discarded on process exit.
        // - PostgreSQL: Corpus + VectorStore are wired on the same
        //   PostgreSQLStorage handle (same lazy connection pool, same PG schema).
        //   Schema migrations are idempotent. The pool acquires connections on
        //   first use; wiring itself does not open a TCP connection.
        //
        // Idempotent across restarts (SQLite + PostgreSQL): `Corpus(storage:models:)`
        // and `VectorStore(storage:)` apply their schema declarations via the
        // backend's idempotent `migrate`, and `registerCorpus`/`registerVectorStore`
        // are plain registry writes. Re-opening the same on-disk estate re-registers
        // against already-migrated tables and re-reads persisted vectors — no data
        // is dropped, no schema is rewritten. In-memory is not persistent so
        // idempotency across restarts is not applicable.
        //
        // The encode queue is mounted eagerly by `wireGLKSubstores` (idempotent
        // with the mode-aware `capture` verb's lazy mount). The gauntlet's
        // impatient writes still ingest into the Corpus inline.
        //
        // Embedding ensemble: `CorpusEnsemble.defaultEnsemble()` — the canonical
        // 1.0 five-signal recall default (RI / PPMI / LSA / NMF / FDC). The
        // trainable distributional signals train and persist on first ingest /
        // reindex under their own modelIDs; FDC is stateless and live immediately.
        // The dense float lane fuses all five honest signals, so recall is the
        // multi-signal default — not pinned to a single hash lane — from the first
        // capture on every backend.
        if wireSemanticRecall {
            do {
                // Shared seam: Corpus + VectorStore + encode queue, the same wiring
                // `provision` and `mootx01 serve` perform. Idempotent on reopen.
                try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
                // Rebuild + register the matrix tier from the persisted audit log
                // so matrix-driven recall (co-occurrence/temporal scoring — the
                // matrixAware scoring and the matrix/lattice/weighted-all
                // compositions) is live from the FIRST query on a reopened estate.
                // Like Corpus/VectorStore above, the matrix tier is an in-memory
                // DERIVED accelerator rebuilt from durable ground truth (the audit
                // log), not persisted state: a fresh process has matrixTiers[handle]
                // = nil, so without this every matrix score column reads 0.0 and
                // matrix recall is dark after a restart until the next in-process
                // dreaming cycle. This is the same rebuild moot_dream performs as
                // its "un-starving" step; doing it on open makes the durable estate
                // correct from the first recall. Idempotent — rebuild from the same
                // log is deterministic, and the dreaming cycle refreshes it later.
                try await kit.rebuildDerivedAccelerators(for: handle)
                Logging.stderr.log("ARIA_MCP recall lit: LocusKit semantic recall (structural/BM25) + CorpusKit/VectorKit vector recall (five-signal honest ensemble Lane D — RI/PPMI/LSA/NMF/FDC, trained on-corpus and fused) + matrix tier registered. Learned semantic embedding (MiniLM/MPNet/Gemma): additive v1.1 on-device lane, not wired here.")
            } catch {
                fputs("ARIA_MCP fatal: cannot wire semantic recall: \(error)\n", stderr)
                exit(1)
            }
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
                statsStorePath: statsStorePath
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
