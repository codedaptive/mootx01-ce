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
import Security
import ArgumentParser
import AriaMCP
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import MootInstallerCore
import MootEstateOpen
import MootProductIdentity
import AriaResident
import FactExtractionKit
import FactExtractionKitProviders
import MootFactExtractorActivation
import Darwin


struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start the ARIA MCP server (stdio, or resident HTTP when --http / MOOTX01_HTTP_PORT is set)."
    )

    @Option(name: .long, help: "Estate to serve: a registered name, or <dir>/<name> for a transient estate. Default: the active estate.")
    var db: String?

    /// Either a decimal port number (exact — fails if busy) or the literal
    /// string "auto" (hunts upward from the default port, same as Rust).
    /// Also readable from MOOTX01_HTTP_PORT (numeric only from the environment).
    @Option(name: .long, help: "Resident HTTP port on 127.0.0.1, or 'auto' to hunt from \(MootPaths.defaultResidentPort) upward (also MOOTX01_HTTP_PORT). When set, runs the resident daemon (HTTP + autonomic governor + telemetry) instead of stdio.")
    var http: String?

    @Flag(name: .long, help: "Serve the estate as a read-only snapshot (also MOOTX01_FROZEN=1): no background workers, no recall traces or reward marks, mutating tools refused. stdio only — refused with --http.")
    var frozen = false

    /// Benchmark harness posture (C1): the estate is served from the InMemory
    /// backend and exists only for this process. An explicit flag, never an
    /// environment value; a durable estate never selects it.
    @Flag(name: .customLong("in-memory"), help: "Serve the estate from the in-memory backend: same protocol and algorithms, no filesystem, the estate lives and dies with this process. Accuracy sweeps only.")
    var inMemory = false

    func run() async throws {
        let environment = ProcessInfo.processInfo.environment

        // The catalog is the one place that knows which estates exist and
        // where. `--db` selects a registered estate by name or attaches a
        // transient one by path; absent, the active estate serves. Nothing
        // here computes a path.
        let catalog: EstateCatalog
        do {
            catalog = try EstateOpen.catalog(selecting: db)
        } catch {
            Logging.stderr.log("mootx01 serve fatal: \(error)")
            throw ExitCode.failure
        }
        let estate = catalog.active
        let estateName = estate.name
        let estateURL = estate.databaseURL
        // Install-wide files (resident port, bundled models) live in the
        // configuration directory; estate files live with the estate.
        let dataDir = EstateCatalog.configurationDirectory

        // Resident HTTP transport when a port is configured (--http flag or
        // MOOTX01_HTTP_PORT); otherwise stdio (the default — existing client
        // configs that run `mootx01` keep working unchanged).
        let residentPort = try Self.resolveResidentPort(flag: http, environment: environment)
        Logging.stderr.log("mootx01 serve starting (estate: \(estateName) [\(estate.kind.rawValue)] at \(estate.directory.path), transport: \(residentPort.map { "HTTP :\($0)" } ?? "stdio"))")

        // Frozen posture: `--frozen` wins, else MOOTX01_FROZEN=1. A frozen serve
        // is a read-only, side-effect-free snapshot: no detached dreamer or
        // drainer, no periodic dreamer, `moot_memory_search` with internal
        // origin (no trace rows, no dreaming enqueue), no reward mark on
        // dereference, every mutating tool refused. The resident daemon's
        // autonomic governor is a background worker by definition, so the
        // combination with HTTP is refused rather than served half-frozen.
        let posture = EstatePosture.resolve(frozenFlag: frozen, environment: environment)
        if posture == .frozen {
            if residentPort != nil {
                Logging.stderr.log("mootx01 serve fatal: --frozen / MOOTX01_FROZEN=1 cannot be combined with --http / MOOTX01_HTTP_PORT — the resident daemon runs background workers. Serve a frozen estate over stdio.")
                throw ExitCode.failure
            }
            Logging.stderr.log("mootx01 serve: \(EstatePosture.frozenLogLine)")
        }

        // The resident's PID marker lives with the estate it serves (resident-only,
        // written below). "Is this estate served" is a fact about the estate.
        let pidURL = estate.pidURL
        // PID writes, the T4 forward probe, and the dreamer apply only when the
        // estate lives on disk as SQLite. An in-memory estate is ephemeral: the
        // estate directory never holds a pid file, no dreamer persists its output,
        // and T4 forwarding is irrelevant — there is no resident to forward to.
        let onDisk = !inMemory && estate.backend == .sqlite

        // T4 — forward, don't collide. If a LIVE resident already serves THIS
        // estate, an stdio `serve` must not open the same estate as a second
        // direct writer (that would desync the resident's in-RAM derived state).
        // Instead it forwards its stdin JSON-RPC to the resident over loopback
        // HTTP — the same bridge `mootx01 proxy` uses — so all traffic funnels
        // through the one resident writer. "Same estate" = a live PID marker in
        // THIS estate's directory. If no live resident serves this estate, fall
        // through and open it directly (joining the WAL pool; the drain lease
        // (T3) keeps multiple direct stdio writers from double-draining).
        #if os(macOS)
        if residentPort == nil, onDisk,
           Self.residentServesEstate(pidURL: pidURL) {
            let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
            if await Self.residentReachable(port: port) {
                // A frozen serve never forwards: the resident is a live, mutating
                // server and forwarding would hand the client exactly what the
                // flag promised it would not get.
                if posture == .frozen {
                    Logging.stderr.log("mootx01 serve fatal: a live resident already serves this estate on 127.0.0.1:\(port); a frozen serve cannot forward to a live daemon. Stop the resident or freeze a clone.")
                    throw ExitCode.failure
                }
                Logging.stderr.log("mootx01 serve: a live resident already serves this estate — forwarding stdio to the daemon on 127.0.0.1:\(port) instead of opening a second writer (T4)")
                var proxy = ProxyCommand()
                proxy.http = "http://127.0.0.1:\(port)"
                try await proxy.run()
                return
            }
            // A live PID marker but nothing answering on the port: the resident is
            // between states or wedged. Open the estate directly.
            Logging.stderr.log("mootx01 serve: a live resident PID is recorded for this estate but none is reachable on 127.0.0.1:\(port) — opening the estate directly")
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
        if residentPort != nil, onDisk,
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
        // The PID marker is RESIDENT-only: it is the signal a stdio `serve` reads
        // (T4) to decide it should forward to the live resident for THIS estate
        // instead of opening a second writer. stdio writes nothing — it is either
        // forwarding or an ephemeral direct opener. In-memory estates never write
        // a PID marker: the estate directory may not exist and there is no
        // on-disk resident to forward to.
        if residentPort != nil, onDisk {
            try? String(ProcessInfo.processInfo.processIdentifier).write(
                to: pidURL, atomically: true, encoding: .utf8)
        }
        defer {
            if residentPort != nil, onDisk {
                try? FileManager.default.removeItem(at: pidURL)
            }
        }

        // The SQLite backend creates parent dirs and the file on first open;
        // check pre-existence to decide whether to call create (first-run only).
        // An in-memory estate is ALWAYS first-run: nothing persists between
        // processes, so create-then-open every time.
        let isFirstRun = !FileManager.default.fileExists(atPath: estateURL.path) || inMemory
        if isFirstRun && posture == .frozen {
            throw EstateError.substrateUnavailable("frozen serve requires an existing estate")
        }

        // Estate key-material lifetime (estate-key-lifetime fix, 2026-07-29).
        // The catalog decided what kind of estate this is, and the kind decides
        // every Keychain question. A REGISTERED estate is owned by this machine:
        // its Ed25519 identity lives in the Keychain and it may be encrypted with
        // a Keychain-held key. A TRANSIENT estate (`--db <dir>/<name>`) never
        // touches the Keychain: identity store in memory, no federation, opened
        // plaintext (or with the harness key file beside it in harness builds),
        // and no charter drawers seeded into it.
        //
        // `--in-memory` is served as a transient estate whatever the record
        // says (R8, 2026-09-08). Nothing survives the process, so there is no
        // identity for a peer to address later and no charter map to outlive
        // the run — and a benchmark RAM arm measures the pool it imported and
        // nothing else. The record is still resolved first, so a `--db` naming
        // no estate is refused before the backend is chosen. Same rule in the
        // Rust port and in both ports of `aria-mcp`.
        let registered = estate.kind == .registered && !inMemory
        let identityKeyStore: (any EstateIdentityKeyStore)? =
            registered ? nil : InMemoryEstateIdentityKeyStore()

        // MOOTX01_RESIDENCY controls both the residency hint and the resident-index
        // admission budget. See `parseResidencyConfig` for the full grammar.
        // Default: ram-resident with a 25% ceiling on physical RAM.
        let (residencyHint, residentIndexBudget) = Self.parseResidencyConfig(
            rawValue: environment["MOOTX01_RESIDENCY"] ?? ""
        )

        // Backend selection and at-rest posture. The in-memory branch is entered
        // before the posture block so that --in-memory never contacts the Keychain.
        // The record was already resolved above, so a bad --db is refused before
        // this branch is reached. The on-disk path resolves the at-rest posture
        // before opening SQLite; the in-memory path skips it entirely.
        //
        // encryption is the resolved on-disk posture, nil for an in-memory serve.
        // EstateManifestRefresh.afterPrepare below runs only when it is non-nil,
        // so an in-memory serve writes nothing into the estate directory. The
        // Rust port never refreshes the manifest from serve either.
        let encryption: EstateEncryptionConfig?
        let storage: any Storage
        if inMemory {
            // C1 (benchmark reset, RAM accuracy shape): --in-memory serves the
            // estate from PersistenceKit's InMemory backend — same protocol, same
            // algorithms, no filesystem in the measurement path. The estate lives
            // and dies with this process (accuracy sweeps only; timing always
            // measures the real disk path). No Keychain contact: the .inMemory
            // backend resolves the in-memory identity key store, and no db key
            // exists to mint. Intended for the benchmark harness; a durable estate
            // never selects it, and no environment value turns it on.
            // No on-disk posture: nothing is loaded and nothing is written back.
            encryption = nil
            let configuration = EstateConfiguration(
                estateID: UUID(),
                backend: .inMemory,
                residencyHint: residencyHint,
                residentIndexBudget: residentIndexBudget
            )
            storage = InMemoryStorage(configuration: configuration)
            Logging.stderr.log(
                "mootx01 serve: IN-MEMORY backend (--in-memory) — "
                + "estate exists only for this process; accuracy-measurement posture "
                + "(transient: identity in memory, no federation, no charters, no Keychain writes).")
        } else {
            // At-rest posture. A new registered estate is created encrypted; an
            // already-encrypted one loads its existing key; a plaintext one keeps
            // opening as plaintext. serve runs under launchd with NO TTY, so this
            // must never prompt and never migrate — migration is `mootx01 upgrade`.
            let resolved: (encryption: EstateEncryptionConfig, posture: EstateOpenPosture.Posture)
            do {
                resolved = try EstateOpenPosture.resolve(for: estate)
            } catch {
                // Fail closed. Never fall back to a plaintext open of an encrypted
                // estate: that would silently downgrade at-rest protection.
                Logging.stderr.log("mootx01 serve fatal: estate encryption posture unavailable: \(error)")
                throw ExitCode.failure
            }
            encryption = resolved.encryption
            if !registered {
                Logging.stderr.log("mootx01 serve: transient estate — identity in memory, no federation, no Keychain writes")
            } else if resolved.posture == .newPlaintextDeclared {
                // A declared-plaintext open must never be silent: name the posture
                // AND its source, so a downgrade caused by an altered manifest is
                // visible in the serve log (Codex fe2cf887).
                Logging.stderr.log(
                    "mootx01 serve: creating estate UNENCRYPTED — its manifest \(estate.manifestURL.path) declares plaintext. Run `mootx01 upgrade` to encrypt.")
            }
            let configuration = EstateConfiguration(
                estateID: UUID(),
                backend: .sqlite(url: estateURL, busyTimeout: 5.0),
                encryptionConfig: resolved.encryption,
                residencyHint: residencyHint,
                residentIndexBudget: residentIndexBudget
            )
            do {
                storage = try SQLiteStorage(configuration: configuration)
            } catch {
                Logging.stderr.log("mootx01 serve fatal: SQLite open failed: \(error)")
                throw ExitCode.failure
            }
        }

        let owner = OwnerCredentials(
            ownerIdentifier: MootPaths.defaultOwnerIdentifier
        )
        let kit = GeniusLocusKit()
        // Production model-directory resolver, installed before the estate is
        // opened and wired: `wireGLKSubstores` acts on the manifest's
        // `embedding_provider = "encoder"` by building the span encoder from
        // the active registry row, and it can only find the bundled model
        // through this resolver (the kit's default answers nil for every id,
        // which leaves recall lexical-only).
        await kit.setModelDirectoryResolver(BundledModelDirectoryResolver(dataDirectory: dataDir))
        let handle: EstateHandle
        do {
            if isFirstRun {
                Logging.stderr.log("first-run: creating estate '\(estateName)' at \(estateURL.path)")
                _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
            }
            // identityKeyStore is nil for a registered estate (resolved per storage
            // backend — Keychain for SQLite) and in memory for a transient one, so
            // a transient estate's Ed25519 key never touches the Keychain and it
            // never federates.
            handle = try await kit.open(storage: storage, owner: owner,
                                        identityKeyStore: identityKeyStore, federate: registered, frozen: posture == .frozen)
            // A fresh estate is born with the span encoder as its default recall
            // stage; existing estates get the key from `mootx01 upgrade`, never
            // from a serve open (an operator who cleared it stays lexical-only).
            if isFirstRun {
                try await kit.provisionDefaultEncoderIfAbsent(for: handle)
            }
            if posture == .frozen {
                guard try await EstateFormatStore(storage: storage).readIfPresent() == .current else {
                    throw EstateError.substrateUnavailable("frozen estate requires migration before serving")
                }
            } else {
            let preparation = try await GLKMigrationCatalog.prepare(
                kit: kit, handle: handle, now: Date())
            // The manifest must say what is on disk: after a migration, or for an
            // estate that predates manifests, rewrite estate.json. Only an on-disk
            // serve has a posture to record; an in-memory serve (encryption nil)
            // writes nothing into the estate directory.
            if let encryption, try EstateManifestRefresh.afterPrepare(
                preparation, estate: estate, encryption: encryption, now: Date()) {
                Logging.stderr.log("mootx01 serve: estate manifest refreshed (format \(preparation.format), schema \(GeniusLocusKitSchema.version))")
            }
            }
            // `open` admits a BARE estate — it does not register a Corpus or
            // VectorStore, so dense vector recall and distillation are dark. Wire
            // the GLK semantic layer (Corpus + VectorStore + encode queue) here so
            // a served estate is fully live. Idempotent on reopen; does not
            // re-stamp the manifest (which is why we wire rather than `provision`).
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage, frozen: posture == .frozen)
            // Seed the seven default wings if they are not already present.
            // `seedDefaultWings` is idempotent: it reads existing charter drawers
            // and skips wings that are already seeded, so calling it on every open
            // is safe for both fresh estates (wings missing) and previously-served
            // estates (wings present). `Date()` is acceptable here — this is an app
            // entry point, not a deterministic engine.
            // Subject rider — ON BY DEFAULT (rider-default ruling,
            // 2026-08-02): register the Apple miniLLM subject producer
            // unless the operator disabled it at install
            // (MOOTX01_SUBJECT_RIDER=0 → --subject-rider-off). Model
            // unavailability (no Apple Intelligence, model not
            // downloaded, pre-26 OS) logs and continues — a served
            // estate must never fail to start over an optional rider.
            // Dreaming dispatches the actual backfill sweeps.
            if ToolProjection.subjectRiderEnabled {
                do {
                    try await kit.enableAppleSubjectRider(for: handle)
                    FileHandle.standardError.write(Data(
                        "mootx01 serve: subject rider enabled (minillm-v1)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data(
                        "mootx01 serve: subject rider unavailable — continuing without it (\(error))\n".utf8))
                }
            }
            // Charters seed only into a registered estate. A transient estate
            // holds exactly what was imported into it (2026-08-24 ruling).
            if registered && posture != .frozen {
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
            }
            // Load the derived accelerators (matrix tier) in the background so the
            // server starts accepting MCP calls immediately. Matrix recall returns
            // zeros until the load finishes — correct degradation. The dreaming
            // cycle refreshes and re-persists it later.
            //
            // The isolated GLK worker loads normalized records, folds counts
            // forward, recomputes time-dependent decay, and publishes a complete
            // generation. No whole-matrix BLOB is decoded or rewritten.
            //
            // RESIDENT ONLY: the matrix tier is a long-lived brain-layer structure
            // that only the resident daemon's recall scoring + dreaming consume. A
            // one-shot stdio `query` subprocess does NOT need it, so skip it in stdio
            // mode — stdio recall runs with degraded (zero) matrix scoring, which is
            // correct one-shot behaviour, and a one-shot must not pay even the load
            // cost or write records it will never reuse.
            if residentPort != nil, onDisk {
                Task {
                    do {
                        try await kit.rebuildDerivedAccelerators(for: handle, frozen: posture == .frozen)
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
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
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
            updateAdvisoryProvider: updateAdvisoryProvider,
            posture: posture
        )
        let dispatcher = ARIA_MCPDispatcher(info: info, tooling: tooling)

        if let port = residentPort {
            // FIRST-PARTY LANE: DELIBERATELY DARK HERE.
            //
            // This command is the raw CLI/resident host. It is NOT an eligible
            // first-party provider and must never present itself as one: a raw,
            // unsigned, Homebrew-built, or self-built executable cannot claim the
            // team Keychain access group, so it cannot hold the installation root
            // that the authenticated lane's whole argument rests on.
            //
            // It therefore passes NO first-party root, NO provider, and NO
            // descriptor. The lane stays closed structurally rather than by
            // convention: `AriaResident.runResidentDaemon` builds its `HTTPServer`
            // with `firstPartyAuth` defaulted to nil, and its dispatcher with
            // `firstPartyIdentity` defaulted to nil. With those nil the entire
            // `/mcp/first-party` subtree 404s and `initialize` never claims the
            // `authenticated-first-party` capability — there is no flag to
            // misconfigure and no branch to take by accident.
            //
            // This host remains fully eligible for the existing third-party MCP
            // lane, whose behaviour is unchanged.
            //
            // MACD-2c supplies the signed, provisioned daemon bundle that IS an
            // eligible provider, along with the provider lock and descriptor
            // publication. MACD-3 performs the atomic production routing
            // conversion. Neither is in scope here, and enabling this lane in the
            // raw resident host is explicitly not authorized.
            //
            // Resident daemon: HTTP transport + autonomic governor + telemetry/monitoring
            // gate via the shared AriaResident runner (identical wiring to
            // aria-mcp). The estate is the durable SQLite opened above, so dreaming
            // persists. Telemetry store at the canonical path computed by
            // MootPaths.daemonStatsStorePath — the same location moot-mgr reads
            // and the launchd plist no longer needs to carry the path in its env
            // (R6: ARIA_MCP_STATS_STORE moves from env to configuration).
            // The master switch and selected provider are estate-owned. A
            // transient benchmark estate reads only its own optional config;
            // registered estates read the product configuration directory.
            // `provisionedPreference` returns the key's default for an absent
            // value, so the only error it can raise is a storage error; that
            // error is fatal here and never substituted with a default, because
            // a daemon running on defaults it was never configured with would
            // silently misreport what the estate asked for.
            let factSettingsDirectory = estate.kind == .registered
                ? EstateCatalog.configurationDirectory : estate.directory
            let factExtractor: (any FactExtractor)?
            do {
                let factExtractionSetting = try await kit.provisionedPreference(
                    .factExtraction, for: handle)
                let factExtractorSetting = try await kit.provisionedPreference(
                    .factExtractor, for: handle)
                guard let workerExecutableURL = Self.resolvedCurrentExecutableURL() else {
                    Logging.stderr.log("mootx01 serve fatal: could not resolve current executable path for fact extraction")
                    throw ExitCode.failure
                }
                factExtractor = FactExtractorBuilder.build(
                    masterSetting: factExtractionSetting,
                    extractorSetting: factExtractorSetting,
                    settingsDirectory: factSettingsDirectory,
                    workerExecutableURL: workerExecutableURL)
            } catch {
                Logging.stderr.log("mootx01 serve fatal: fact-extraction preference read failed: \(error)")
                throw ExitCode.failure
            }
            // Batch limits and the Signal 14 cadence come from the same settings
            // directory (§ DUTY_LIFECYCLE); the stdio path installs the limits
            // here, the resident path hands them to the daemon config below.
            let dutySettings = MootProductIdentity.Settings.load(configurationDirectory: factSettingsDirectory)
            await kit.configureDutyLimits(DutyLimits(settings: dutySettings), for: handle)

            let config = AriaResident.ResidentConfig(
                port: port,
                maxBodyBytes: AriaResident.httpMaxBodyBytes(env: environment),
                brainTickMs: AriaResident.brainTickMs(env: environment),
                monitoringPollMs: AriaResident.monitoringPollMs(env: environment),
                statsStorePath: MootPaths.daemonStatsStorePath(dataDir: dataDir),
                vaultPath: AriaResident.vaultPath(env: environment),
                vaultEstatePollSeconds: AriaResident.vaultEstatePollSeconds(env: environment),
                factExtractor: factExtractor,
                factExtractionCadenceSeconds: TimeInterval(dutySettings.dutyFactExtractionCadenceSeconds),
                dutyLimits: DutyLimits(settings: dutySettings)
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
            // A stdio serve spawns no background process (§ DUTY_LIFECYCLE):
            // no startup, exit, or periodic dreamer, no exit drainer. A caller
            // that wants debt paid runs `mootx01 drain` or `mootx01 dream`.
            // `mountDreamingQueue` mounts the persisted queue so the drain
            // report's dreaming lane reads the real backlog. Idempotent.
            if onDisk { await kit.mountDreamingQueue(for: handle) }

            let server = StdioServer(dispatcher: dispatcher)
            Logging.stderr.log("mootx01 serve ready (\(dispatcher.tools.count) tools, stdio)")
            await server.run()

            Logging.stderr.log("mootx01 serve exiting (stdin closed)")
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

        // Decode up to the NUL terminator; the buffer is sized by the first
        // _NSGetExecutablePath call and is always terminated.
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard path.first == "/" else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// True when a live resident serves this estate (T4): the estate's own PID
    /// marker names a live, identity-verified mootx01 process other than us. The
    /// marker lives in the estate directory, so it can only ever describe THIS
    /// estate. macOS only (stdio→resident forwarding is a desktop concern; iOS
    /// has no resident daemon).
    #if os(macOS)
    static func residentServesEstate(pidURL: URL) -> Bool {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != ProcessInfo.processInfo.processIdentifier
        else { return false }
        return ProcessIdentity.isLiveProcess(pid)
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

    /// Parse the `MOOTX01_RESIDENCY` environment variable into a residency hint and
    /// a resident-index admission budget.
    ///
    /// This is the entire operator-facing contract for the residency feature.
    /// Grammar (case-insensitive):
    ///
    ///   unset, or "ram"      — ram-resident, default budget (25% of physical RAM).
    ///   "disk"               — disk-backed; no float-lane index held in heap.
    ///                          Behaves exactly as the original `MOOTX01_RESIDENCY=disk`.
    ///   "ram:<N>mb"          — ram-resident, explicit ceiling of N mebibytes.
    ///                          N must be a positive integer.
    ///   "ram:<N>gb"          — ram-resident, explicit ceiling of N gibibytes.
    ///                          N must be a positive integer.
    ///   "ram:<N>%"           — ram-resident, ceiling of N percent of physical RAM.
    ///                          N must be a positive integer from 1 to 100 inclusive.
    ///   "ram:unbounded"      — ram-resident, no admission bound (pre-RS-01 behaviour).
    ///
    /// Reject conditions (malformed → warn to stderr, then fall back to the default):
    ///   — a zero or negative N
    ///   — a non-numeric N
    ///   — a percentage above 100
    ///   — any value that matches none of the patterns above
    ///
    /// Silent fallback is not acceptable: an operator who mistypes a ceiling must
    /// not believe a cap is in force when it is not. The warning names the value
    /// that was rejected so the operator can correct it.
    static func parseResidencyConfig(
        rawValue: String
    ) -> (hint: ResidencyHint, budget: ResidentIndexBudget) {
        let lowered = rawValue.lowercased()

        // Disk-backed: exact match. The budget is irrelevant when no index is
        // loaded into RAM, but carry the default to keep the type consistent.
        if lowered == "disk" {
            return (.diskBacked, .systemFraction(0.25))
        }

        // Plain "ram" or unset: ram-resident with the 25% default budget.
        if lowered.isEmpty || lowered == "ram" {
            return (.ramResident, .systemFraction(0.25))
        }

        // All remaining valid values begin with the "ram:" prefix.
        guard lowered.hasPrefix("ram:") else {
            Logging.stderr.log(
                "mootx01 serve: MOOTX01_RESIDENCY='\(rawValue)' is not recognised; "
                + "expected one of: disk, ram, ram:<N>mb, ram:<N>gb, ram:<N>%, ram:unbounded. "
                + "Falling back to ram-resident with the default 25% budget.")
            return (.ramResident, .systemFraction(0.25))
        }

        let suffix = String(lowered.dropFirst("ram:".count))

        // Explicit opt-out of the admission bound (pre-RS-01 behaviour).
        if suffix == "unbounded" {
            return (.ramResident, .unbounded)
        }

        // Percentage ceiling: ram:<N>%
        if suffix.hasSuffix("%") {
            let numStr = String(suffix.dropLast())
            if let n = Int(numStr), n > 0, n <= 100 {
                return (.ramResident, .systemFraction(Double(n) / 100.0))
            }
            Logging.stderr.log(
                "mootx01 serve: MOOTX01_RESIDENCY='\(rawValue)' has a malformed percentage "
                + "(must be a positive integer from 1 to 100); "
                + "falling back to ram-resident with the default 25% budget.")
            return (.ramResident, .systemFraction(0.25))
        }

        // Mebibyte ceiling: ram:<N>mb  (1 MiB = 1,048,576 bytes)
        if suffix.hasSuffix("mb") {
            let numStr = String(suffix.dropLast(2))
            // `n * 1024 * 1024` TRAPS on overflow in Swift, and `n` comes straight
            // from operator-supplied environment text, so an absurd value such as
            // "ram:99999999999999999mb" would abort the daemon at startup. Use the
            // reporting multiply and treat an overflow as malformed input.
            if let n = Int(numStr), n > 0 {
                let (bytes, overflow) = n.multipliedReportingOverflow(by: 1024 * 1024)
                if !overflow {
                    return (.ramResident, .bytes(bytes))
                }
            }
            Logging.stderr.log(
                "mootx01 serve: MOOTX01_RESIDENCY='\(rawValue)' has a malformed mebibyte value "
                + "(must be a positive integer); "
                + "falling back to ram-resident with the default 25% budget.")
            return (.ramResident, .systemFraction(0.25))
        }

        // Gibibyte ceiling: ram:<N>gb  (1 GiB = 1,073,741,824 bytes)
        if suffix.hasSuffix("gb") {
            let numStr = String(suffix.dropLast(2))
            // Same overflow guard as the mebibyte branch above: the multiply traps
            // on overflow and the operand is operator-supplied text.
            if let n = Int(numStr), n > 0 {
                let (bytes, overflow) = n.multipliedReportingOverflow(by: 1024 * 1024 * 1024)
                if !overflow {
                    return (.ramResident, .bytes(bytes))
                }
            }
            Logging.stderr.log(
                "mootx01 serve: MOOTX01_RESIDENCY='\(rawValue)' has a malformed gibibyte value "
                + "(must be a positive integer); "
                + "falling back to ram-resident with the default 25% budget.")
            return (.ramResident, .systemFraction(0.25))
        }

        // Unrecognised suffix after "ram:".
        Logging.stderr.log(
            "mootx01 serve: MOOTX01_RESIDENCY='\(rawValue)' is not recognised; "
            + "expected one of: disk, ram, ram:<N>mb, ram:<N>gb, ram:<N>%, ram:unbounded. "
            + "Falling back to ram-resident with the default 25% budget.")
        return (.ramResident, .systemFraction(0.25))
    }

    /// Resolve the resident HTTP port: the `--http` flag wins, else
    /// `MOOTX01_HTTP_PORT` from the environment (the launchd plist sets it). nil →
    /// stdio. An out-of-range value is rejected (logged) and falls back to stdio.
    static func resolveResidentPort(flag: String?, environment: [String: String]) throws -> UInt16? {
        if let flag {
            if flag == "auto" {
                // Hunt from the default port upward until a free socket is found.
                // Delegates to ServePortHunt (MootInstallerCore) so the probe and
                // hunt logic are exercised by unit tests without importing this
                // executable target. Mirrors Rust serve.rs §3.
                let base = MootPaths.defaultResidentPort
                if let port = ServePortHunt.hunt(from: UInt16(base)) {
                    if port != UInt16(base) {
                        Logging.stderr.log("mootx01 serve: port \(base) busy; hunted to \(port)")
                    }
                    return port
                }
                // No free port found: exit 1, matching Rust serve.rs exhaustion.
                Logging.stderr.log("mootx01: no free port in \(base)–\(Int(base) + Int(ServePortHunt.huntRange))")
                throw ExitCode.failure
            }
            guard let port = UInt16(flag), port > 0 else {
                Logging.stderr.log("mootx01 serve: --http '\(flag)' is not a valid TCP port (1–65535) or 'auto'; using stdio")
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
