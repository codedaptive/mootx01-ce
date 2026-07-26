// ServeCommand.swift
//
// Start the ARIA MCP server over stdio. This is the default behaviour
// when `mootx01` is invoked with stdin as a pipe and no explicit
// subcommand — so existing client configs that use `"command": "mootx01"`
// continue to work without modification.
//
// The serve path is macOS-only: AriaMCP, GeniusLocusKit, and the SQLite
// backend all declare `.macOS(.v15)`. Linux builds include all other
// subcommands (install, uninstall, db, status, query) but omit serve.
// On Linux, MootMain.swift excludes ServeCommand from the subcommand
// list, so this file is only compiled on macOS.

#if os(macOS)
import Foundation
import ArgumentParser
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import MootInstallerCore
import AriaResident
import Darwin

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the ARIA MCP server (stdio, or resident HTTP when --http / MOOTX01_HTTP_PORT is set)."
    )

    @Option(name: .long, help: "Named estate to serve. Default: active estate.")
    var db: String?

    @Option(name: .long, help: "Resident HTTP port on 127.0.0.1 (also MOOTX01_HTTP_PORT). When set, runs the resident daemon (HTTP + autonomic governor + telemetry) instead of stdio.")
    var http: Int?

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = MootPaths.resolveDataDirectory(
            environment: environment,
            homeDirectory: home
        )

        // Resolve estate name: --db flag overrides the active estate pointer.
        let estateName: String
        if let dbFlag = db {
            estateName = dbFlag
        } else {
            estateName = (try? DatabaseManager.activeEstateName(in: dataDir)) ?? "default"
        }

        let estateURL: URL
        if let envPath = environment["ARIA_MCP_SQLITE_PATH"], !envPath.isEmpty {
            estateURL = URL(fileURLWithPath: envPath)
            Logging.stderr.log("estate path override via ARIA_MCP_SQLITE_PATH: \(envPath)")
        } else {
            estateURL = DatabaseManager.estateURL(for: estateName, in: dataDir)
        }

        // Resident HTTP transport when a port is configured (--http flag or
        // MOOTX01_HTTP_PORT); otherwise stdio (the default — existing client
        // configs that run `mootx01` keep working unchanged).
        let residentPort = Self.resolveResidentPort(flag: http, environment: environment)
        Logging.stderr.log("mootx01 serve starting (estate: \(estateName), data dir: \(dataDir.path), transport: \(residentPort.map { "HTTP :\($0)" } ?? "stdio"))")

        // PID + served-estate markers (resident-only, written below).
        let pidURL = dataDir.appendingPathComponent("mootx01.pid", isDirectory: false)
        let estateMarkerURL = dataDir.appendingPathComponent("mootx01.estate", isDirectory: false)

        // T4 — forward, don't collide. If a LIVE resident already serves THIS
        // estate, an stdio `serve` must not open the same estate as a second
        // direct writer (that would desync the resident's in-RAM derived state).
        // Instead it forwards its stdin JSON-RPC to the resident over loopback
        // HTTP — the same bridge `mootx01 proxy` uses — so all traffic funnels
        // through the one resident writer. "Same estate" = the resident's recorded
        // estate path matches ours; liveness = its PID file is alive. If no live
        // resident serves this estate, fall through and open it directly (joining
        // the WAL pool; the drain lease (T3) keeps multiple direct stdio writers
        // from double-draining).
        #if os(macOS)
        if residentPort == nil,
           Self.residentServesEstate(estateURL, markerURL: estateMarkerURL) {
            let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
            if await Self.residentReachable(port: port) {
                Logging.stderr.log("mootx01 serve: a live resident already serves this estate — forwarding stdio to the daemon on 127.0.0.1:\(port) instead of opening a second writer (T4)")
                var proxy = ProxyCommand()
                proxy.http = "http://127.0.0.1:\(port)"
                try await proxy.run()
                return
            }
            // Marker present but nothing is answering on the port: the resident
            // exited uncleanly and left a stale marker. Open the estate directly.
            Logging.stderr.log("mootx01 serve: estate marker present but no resident reachable on 127.0.0.1:\(port) (stale marker) — opening the estate directly")
        }
        #endif
        // Single-writer guard (resident only): the estate has exactly one writer —
        // the resident AutonomicGovernor (see bounded loopback HTTP). Refuse to start the resident
        // daemon if another LIVE process already holds this estate's PID file.
        // stdio is not guarded here: when a resident is live it FORWARDS to it
        // (T4, above) rather than opening a second writer, and when none is live it
        // opens the estate directly and the drain lease (T3) prevents double-drain.
        //
        // Liveness is IDENTITY-VERIFIED (ProcessIdentity), not a bare
        // kill(pid, 0): PIDs recycle across reboots, so a stale PID file
        // left by a crash can point at an unrelated live process, and a
        // bare existence check then refuses to start forever — under
        // launchd that is a crash loop. A recycled PID fails the identity
        // check and its stale file is removed here so status stops
        // reporting a phantom "running" server.
        if residentPort != nil,
           let existing = try? String(contentsOf: pidURL, encoding: .utf8),
           let existingPID = Int32(existing.trimmingCharacters(in: .whitespacesAndNewlines)),
           existingPID != ProcessInfo.processInfo.processIdentifier {
            if ProcessIdentity.isLiveProcess(existingPID) {
                Logging.stderr.log("mootx01 serve fatal: estate '\(estateName)' is already served by a live process (PID \(existingPID)). One resident writer per estate — stop it first.")
                throw ExitCode.failure
            }
            Logging.stderr.log("mootx01 serve: stale PID file (PID \(existingPID) is not a live mootx01 process) — clearing the writer lock and starting")
            try? FileManager.default.removeItem(at: pidURL)
        }
        // PID + served-estate markers are RESIDENT-only: together they are the
        // signal a stdio `serve` reads (T4) to decide it should forward to the
        // live resident for THIS estate instead of opening a second writer. stdio
        // writes neither — it is either forwarding or an ephemeral direct opener.
        if residentPort != nil {
            try? String(ProcessInfo.processInfo.processIdentifier).write(
                to: pidURL, atomically: true, encoding: .utf8)
            try? estateURL.path.write(to: estateMarkerURL, atomically: true, encoding: .utf8)
        }
        defer {
            if residentPort != nil {
                try? FileManager.default.removeItem(at: pidURL)
                try? FileManager.default.removeItem(at: estateMarkerURL)
            }
        }

        // The SQLite backend creates parent dirs and the file on first open;
        // check pre-existence to decide whether to call create (first-run only).
        let isFirstRun = !FileManager.default.fileExists(atPath: estateURL.path)

        // At-rest posture. A new estate is created encrypted; an already-encrypted
        // estate loads its existing key; a plaintext estate keeps opening as
        // plaintext. serve runs under launchd with NO TTY, so this must never
        // prompt and never migrate — migration is `mootx01 upgrade` only.
        let encryption: EstateEncryptionConfig
        do {
            let resolved = try EstateKeyProvider.resolveOpenPosture(for: estateURL)
            encryption = resolved.encryption
            // A plaintext-by-marker open must never be silent: name the posture
            // AND its source, so a downgrade caused by a stale or planted
            // no-encrypt marker is visible in the serve log instead of being
            // discovered months later (Codex fe2cf887).
            if resolved.posture == .newPlaintextByOptOut {
                Logging.stderr.log(
                    "mootx01 serve: creating estate UNENCRYPTED — opt-out marker present at \(EstateKeyProvider.encryptionOptOutMarkerURL(forEstateAt: estateURL).path). Run `mootx01 upgrade` to encrypt.")
            }
        } catch {
            // Fail closed, in the same style the SQLite open failure below uses.
            // Never fall back to a plaintext open: that would silently downgrade
            // at-rest protection, and for an encrypted estate it would look like
            // the estate had vanished.
            Logging.stderr.log("mootx01 serve fatal: estate encryption key unavailable: \(error)")
            throw ExitCode.failure
        }

        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0),
            encryptionConfig: encryption
        )
        let storage: SQLiteStorage
        do {
            storage = try SQLiteStorage(configuration: configuration)
        } catch {
            Logging.stderr.log("mootx01 serve fatal: SQLite open failed: \(error)")
            throw ExitCode.failure
        }

        let owner = OwnerCredentials(
            ownerIdentifier: MootPaths.defaultOwnerIdentifier
        )
        let kit = GeniusLocusKit()
        let handle: EstateHandle
        do {
            if isFirstRun {
                Logging.stderr.log("first-run: creating estate '\(estateName)' at \(estateURL.path)")
                _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
            }
            handle = try await kit.open(storage: storage, owner: owner)
            // `open` admits a BARE estate — it does not register a Corpus or
            // VectorStore, so dense vector recall and distillation are dark. Wire
            // the GLK semantic layer (Corpus + VectorStore + encode queue) here so
            // a served estate is fully live. Idempotent on reopen; does not
            // re-stamp the manifest (which is why we wire rather than `provision`).
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
            // Seed the seven default wings if they are not already present.
            // `seedDefaultWings` is idempotent: it reads existing charter drawers
            // and skips wings that are already seeded, so calling it on every open
            // is safe for both fresh estates (wings missing) and previously-served
            // estates (wings present). `Date()` is acceptable here — this is an app
            // entry point, not a deterministic engine.
            do {
                try await kit.seedDefaultWings(for: handle, now: Date())
            } catch {
                // Seeding failure is non-fatal for a running serve: the estate is
                // open and functional; worst case a fresh agent sees no charter map.
                // Log the failure and continue. (Provision failure IS fatal because
                // a provision that produces a wing-less estate is malformed; a serve
                // open of an existing estate is not.)
                Logging.stderr.log("mootx01 serve warning: default wing seeding failed: \(error) — continuing")
            }
            // Load the derived accelerators (matrix tier) in the background so the
            // server starts accepting MCP calls immediately. Matrix recall returns
            // zeros until the load finishes — correct degradation. The dreaming
            // cycle refreshes and re-persists it later.
            //
            // rebuildDerivedAccelerators LOADS the persisted on-disk matrix snapshot
            // (MatrixSnapshotStore) and folds only the audit tail past its watermark
            // forward — it does NOT recompute the whole matrix from the audit log on
            // every launch. The first launch on a fresh estate full-rebuilds once and
            // persists; every launch after that is a cheap load + tail fold.
            //
            // RESIDENT ONLY: the matrix tier is a long-lived brain-layer structure
            // that only the resident daemon's recall scoring + dreaming consume. A
            // one-shot stdio `query` subprocess does NOT need it, so skip it in stdio
            // mode — stdio recall runs with degraded (zero) matrix scoring, which is
            // correct one-shot behaviour, and a one-shot must not pay even the load
            // cost or write a snapshot it will never reuse.
            if residentPort != nil {
                Task {
                    do {
                        try await kit.rebuildDerivedAccelerators(for: handle)
                        Logging.stderr.log("derived accelerators rebuilt (background)")
                    } catch {
                        Logging.stderr.log("warning: derived accelerator rebuild failed: \(error)")
                    }
                }
            }
        } catch {
            Logging.stderr.log("mootx01 serve fatal: estate open/wiring failed: \(error)")
            throw ExitCode.failure
        }

        let info = ARIA_MCPDispatcher.ServerInfo(
            name: "mootx01",
            version: "1.0.0"
        )
        // computed once at startup (not per-call) and threaded
        // into every tool response via ToolDispatcher.versionSkewAdvisory.
        // nil whenever no plugin is detected or its version matches this
        // binary — the common case, which leaves ping/status unchanged.
        let versionSkewAdvisory = VersionSkewAdvisory.compute(
            pluginID: "mootx01@mootx01",
            binaryVersion: Mootx01.currentVersion,
            homeDirectory: home
        )
        // Upstream-release advisory (`update_available` in ping/status):
        // resident daemons only. A resident outlives releases, so this must
        // be evaluated lazily at ping/status time — UpdateAdvisor rate-limits
        // the release-feed probe to once per 24h and collapses failures to
        // silence. stdio one-shots stay network-free on purpose: ping is
        // documented as returning immediately, and an offline probe timeout
        // there would break that; every plugin-capable host talks to the
        // resident over HTTP anyway. Repo slug honors the same
        // MOOTX01_REPO override as `mootx01 upgrade`.
        let updateAdvisoryProvider: (@Sendable () async -> String?)?
        if residentPort != nil {
            let advisor = UpdateAdvisor(installedVersion: Mootx01.currentVersion) {
                try await ReleaseDownloader(
                    repo: UpgradeCommand.repoSlug(),
                    currentVersion: Mootx01.currentVersion
                ).latestTag()
            }
            updateAdvisoryProvider = { await advisor.advisory() }
        } else {
            updateAdvisoryProvider = nil
        }
        // Server identity injected so facts/memories filed via this host are
        // stamped "mootx01" — the product binary running mootx01 serve.
        let tooling = ToolDispatcher(
            kit: kit, handle: handle, serverIdentity: "mootx01",
            versionSkewAdvisory: versionSkewAdvisory,
            updateAdvisoryProvider: updateAdvisoryProvider
        )
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)

        if let port = residentPort {
            // Resident daemon: HTTP transport + autonomic governor + telemetry/monitoring
            // gate via the shared AriaResident runner (identical wiring to
            // aria-mcp). The estate is the durable SQLite opened above, so dreaming
            // persists. Telemetry store from ARIA_MCP_STATS_STORE (set by the
            // launchd plist at install).
            let config = AriaResident.ResidentConfig(
                port: port,
                maxBodyBytes: AriaResident.httpMaxBodyBytes(env: environment),
                brainTickMs: AriaResident.brainTickMs(env: environment),
                monitoringPollMs: AriaResident.monitoringPollMs(env: environment),
                statsStorePath: environment["ARIA_MCP_STATS_STORE"]
            )
            Logging.stderr.log("mootx01 serve ready (\(dispatcher.tools.count) tools, resident HTTP on 127.0.0.1:\(port))")
            do {
                try await AriaResident.runResidentDaemon(
                    dispatcher: dispatcher, kit: kit, handle: handle, config: config
                )
            } catch {
                Logging.stderr.log("mootx01 serve fatal: cannot bind HTTP transport on 127.0.0.1:\(port): \(error)")
                throw ExitCode.failure
            }
            Logging.stderr.log("mootx01 serve exiting (HTTP transport stopped)")
        } else {
            //  — on-startup dreaming trigger: if the
            // dreaming queue already has pending items from a prior session
            // (jobs in queue.sqlite that were not processed before the last
            // serve exited), fork a detached dreamer immediately so they are
            // not left stale until the next autonomic governor cycle.
            // This is stdio-only: the resident daemon's autonomic governor
            // handles this path for HTTP serves via its timer-gated pump.
            //
            // `mountDreamingQueue` force-mounts the queue from queue.sqlite so
            // `dreamingQueuePendingCount` reflects the persisted backlog rather
            // than the in-session state (which is zero at startup). Idempotent.
            await kit.mountDreamingQueue(for: handle)
            if let startupPending = await kit.dreamingQueuePendingCount(for: handle),
               startupPending > 0 {
                Logging.stderr.log(
                    "mootx01 serve: \(startupPending) dreaming job(s) pending from prior session — " +
                    "spawning a detached dreamer (T10 on-startup trigger)"
                )
                Self.spawnDetachedDream(estateName: estateName, environment: environment)
            }

            let server = StdioServer(dispatcher: dispatcher)
            Logging.stderr.log("mootx01 serve ready (\(dispatcher.tools.count) tools, stdio)")
            await server.run()

            // T5 — this is a DIRECT-open stdio serve (the forward path returned
            // earlier). The client may SIGKILL us the moment stdin closes, which
            // would kill the in-process encode drain mid-flight. If encode work is
            // still pending, hand it to a detached `drain` finisher that outlives
            // us (it takes the T3 lease and drains to empty, or stands by if a
            // resident has since taken over). Skip when nothing is pending.
            let remaining = (try? await kit.drainStatuses(handle)) ?? []
            if remaining.contains(where: { $0.isDraining }) {
                Logging.stderr.log("mootx01 serve: encode work still pending at stdio exit — spawning a detached drainer to finish (T5)")
                Self.spawnDetachedDrain(estateName: estateName, environment: environment)
            }

            //  — on-exit dreaming trigger: if the dreaming
            // queue has pending items at stdio exit (from recall events during this
            // session, or from a prior session not yet processed), fork a detached
            // dreamer to run one REM-ALPHA cycle before the estate closes. Mirrors
            // the T5 encode on-exit pattern.
            //
            // Post-recall corollary: if any recall verb during this session
            // co-recalled ≥ 2 drawers and enqueued a dreaming item, that item is
            // now in the dreaming queue. The on-exit check catches it here — we
            // do not need a per-request hook in the stdio dispatcher because all
            // in-session dreaming jobs are collected and handed off on exit.
            //
            // Note: `dreamingQueuePendingCount` returns nil when the dreaming queue
            // was never mounted (no qualifying recall in this session AND no prior
            // session backlog). In that case, no dreamer is spawned.
            if let exitPending = await kit.dreamingQueuePendingCount(for: handle),
               exitPending > 0 {
                Logging.stderr.log(
                    "mootx01 serve: \(exitPending) dreaming job(s) pending at stdio exit — " +
                    "spawning a detached dreamer to finish (T10 on-exit trigger)"
                )
                Self.spawnDetachedDream(estateName: estateName, environment: environment)
            }

            Logging.stderr.log("mootx01 serve exiting (stdin closed)")
        }
    }

    /// Launch a detached `mootx01 drain` to finish the encode queue after a
    /// direct-open stdio serve exits (T5). The child `setsid`s itself into its own
    /// session so a process-group kill aimed at this serve does not reach it; we
    /// do not wait on it. The estate is passed via `--db` and the inherited
    /// environment (so an `ARIA_MCP_SQLITE_PATH` override targets the same file).
    static func spawnDetachedDrain(estateName: String, environment: [String: String]) {
        guard let executableURL = resolvedCurrentExecutableURL() else {
            Logging.stderr.log("mootx01 serve: failed to spawn detached drainer: could not resolve current executable path")
            return
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["drain", "--db", estateName]
        process.environment = environment
        // Detach the child's stdio from our pipes.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()  // fire-and-forget — never `waitUntilExit`
        } catch {
            Logging.stderr.log("mootx01 serve: failed to spawn detached drainer: \(error)")
        }
    }

    /// Launch a detached `mootx01 dream` to run one REM-ALPHA dreaming cycle
    /// after a direct-open stdio serve exits or starts with pending dreaming
    /// queue items. The child `setsid`s itself into its
    /// own session so a process-group kill aimed at this serve does not reach it;
    /// we do not wait on it. The estate is passed via `--db` and the inherited
    /// environment (so an `ARIA_MCP_SQLITE_PATH` override targets the same file).
    ///
    /// The dreamer acquires its own `"dreaming"` DrainLease — independent of the
    /// encode drain's `"encode.drain.lease"` — so both can run concurrently
    /// without blocking each other.
    static func spawnDetachedDream(estateName: String, environment: [String: String]) {
        guard let executableURL = resolvedCurrentExecutableURL() else {
            Logging.stderr.log("mootx01 serve: failed to spawn detached dreamer: could not resolve current executable path")
            return
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["dream", "--db", estateName]
        process.environment = environment
        // Detach the child's stdio from our pipes.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()  // fire-and-forget — never `waitUntilExit`
        } catch {
            Logging.stderr.log("mootx01 serve: failed to spawn detached dreamer: \(error)")
        }
    }

    /// Resolve this process's executable from kernel/bundle metadata instead of
    /// trusting `argv[0]`, which may be a relative command name from PATH and
    /// therefore attacker-controlled via the current working directory.
    static func resolvedCurrentExecutableURL() -> URL? {
        if let bundleURL = Bundle.main.executableURL,
           bundleURL.isFileURL,
           bundleURL.path.first == "/" {
            return bundleURL
        }

        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(size))
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            _NSGetExecutablePath(pointer.baseAddress, &size)
        }
        guard result == 0 else { return nil }

        let path = String(cString: buffer)
        guard path.first == "/" else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// True when the live resident's recorded estate path matches the estate this
    /// stdio `serve` would open (T4). Guards against forwarding to a resident that
    /// serves a DIFFERENT estate (e.g. under an `ARIA_MCP_SQLITE_PATH` override).
    /// macOS only (stdio→resident forwarding is a desktop concern; iOS has no
    /// resident daemon).
    #if os(macOS)
    static func residentServesEstate(_ estateURL: URL, markerURL: URL) -> Bool {
        guard let served = try? String(contentsOf: markerURL, encoding: .utf8) else { return false }
        return served.trimmingCharacters(in: .whitespacesAndNewlines) == estateURL.path
    }

    /// True when a resident is actually answering on the loopback port — one quick
    /// JSON-RPC POST with a short timeout (T4 liveness). A port probe, not a PID
    /// check: it confirms the daemon is genuinely serving and is uniform with the
    /// Rust port (which cannot do dep-free PID-liveness). Used to fall back to a
    /// direct open when the estate marker is stale.
    static func residentReachable(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 1.5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let session = URLSession(configuration: .ephemeral)
        return (try? await session.data(for: request)) != nil
    }
    #endif

    /// Resolve the resident HTTP port: the `--http` flag wins, else
    /// `MOOTX01_HTTP_PORT` from the environment (the launchd plist sets it). nil →
    /// stdio. An out-of-range value is rejected (logged) and falls back to stdio.
    static func resolveResidentPort(flag: Int?, environment: [String: String]) -> UInt16? {
        if let flag {
            guard flag > 0, let port = UInt16(exactly: flag) else {
                Logging.stderr.log("mootx01 serve: --http \(flag) is not a valid TCP port (1–65535); using stdio")
                return nil
            }
            return port
        }
        guard let raw = environment["MOOTX01_HTTP_PORT"], !raw.isEmpty else { return nil }
        guard let port = UInt16(raw), port > 0 else {
            Logging.stderr.log("mootx01 serve: MOOTX01_HTTP_PORT='\(raw)' is not a valid TCP port (1–65535); using stdio")
            return nil
        }
        return port
    }
}
#endif
