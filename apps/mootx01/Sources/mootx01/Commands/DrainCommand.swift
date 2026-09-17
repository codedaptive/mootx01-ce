// DrainCommand.swift
//
// `mootx01 drain` — the FINISHER (GENIUSLOCUSKIT_SPEC § DUTY_LIFECYCLE). Run
// attached by an operator or a script; a stdio `serve` spawns nothing. It opens
// the estate, mounts the corpus (whose lease-gated worker drains the persisted
// encode queue), waits until that queue is empty, then pays the settle loop
// for every row-debt duty — span encode, subject backfill, fact extraction —
// until each lane owes nothing or a batch pays nothing, one progress line per
// batch on stderr. When it exits, nothing it started is still running. The T3
// encode lease keeps it from double-draining against a resident; each duty
// batch runs under its own claimed queue job.
//
// macOS-only for the same reason as ServeCommand (AriaMCP / GeniusLocusKit /
// SQLite are `.macOS(.v15)`); the Rust port carries the Windows/Linux drainer.

#if os(macOS)
import Foundation
import ArgumentParser
import AriaMCP
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import MootInstallerCore
import MootEstateOpen
import MootProductIdentity
import FactExtractionKit
import MootFactExtractorActivation
import Darwin

struct DrainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drain",
        abstract: "Finish draining an estate's encode queue, then exit (detached background finisher)."
    )

    @Option(name: .long, help: "Estate to drain: a registered name, or <dir>/<name> for a transient estate. Default: the active estate.")
    var db: String?

    /// Hard cap on total wait so a wedged drain can never hang forever.
    private static let maxWait: TimeInterval = 3600

    func run() async throws {
        // Own session: a process-group kill aimed at the script that ran this
        // finisher does not reach it mid-batch.
        setsid()

        // The catalog resolves `--db` exactly as serve did when it launched us:
        // a registered name, or a transient estate by its directory.
        let estate: EstateRecord
        do {
            estate = try EstateOpen.catalog(selecting: db).active
        } catch {
            Logging.stderr.log("mootx01 drain fatal: \(error)")
            throw ExitCode.failure
        }
        let estateName = estate.name
        let estateURL = estate.databaseURL
        // Nothing to drain if the estate file does not exist.
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return }

        // At-rest posture — the SAME shared decision serve and dream use, so the
        // three commands cannot drift. drain reaches here only when the estate
        // file already exists (guarded above), so in practice this resolves to
        // either the existing-ciphertext or the existing-plaintext branch.
        let encryption: EstateEncryptionConfig
        do {
            let resolved = try EstateOpenPosture.resolve(for: estate)
            encryption = resolved.encryption
        } catch {
            Logging.stderr.log("mootx01 drain fatal: estate encryption key unavailable: \(error)")
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
            Logging.stderr.log("mootx01 drain fatal: SQLite open failed: \(error)")
            throw ExitCode.failure
        }

        let owner = OwnerCredentials(ownerIdentifier: MootPaths.defaultOwnerIdentifier)
        let kit = GeniusLocusKit()
        let handle: EstateHandle
        do {
            // A transient estate never touches the Keychain: identity in memory,
            // no federation. A registered one resolves its store per backend.
            handle = try await kit.open(
                storage: storage, owner: owner,
                identityKeyStore: estate.kind == .registered ? nil : InMemoryEstateIdentityKeyStore(),
                federate: estate.kind == .registered)
            let preparation = try await GLKMigrationCatalog.prepare(
                kit: kit, handle: handle, now: Date())
            // The manifest must say what is on disk: after a migration, or for an
            // estate that predates manifests, rewrite estate.json.
            if try EstateManifestRefresh.afterPrepare(
                preparation, estate: estate, encryption: encryption, now: Date()) {
                Logging.stderr.log("mootx01 drain: estate manifest refreshed (format \(preparation.format), schema \(GeniusLocusKitSchema.version))")
            }
            // Wire the semantic layer so the corpus + its lease-gated drain worker
            // mount; the worker drains the persisted queue (taking the T3 lease
            // unless a resident holds it). Idempotent on reopen.
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
        } catch {
            Logging.stderr.log("mootx01 drain fatal: estate open/wiring failed: \(error)")
            throw ExitCode.failure
        }

        // The finisher pays every row-debt duty to settlement, so it activates
        // what the resident and the coordinator activate: the batch limits, the
        // estate's selected fact extractor, and the subject rider. A provider
        // that cannot be activated leaves its lane owed and says so.
        let factSettingsDirectory = estate.kind == .registered
            ? EstateCatalog.configurationDirectory : estate.directory
        await kit.configureDutyLimits(
            DutyLimits(settings: MootProductIdentity.Settings.load(configurationDirectory: factSettingsDirectory)),
            for: handle)
        do {
            let factExtractionSetting = try await kit.provisionedPreference(.factExtraction, for: handle)
            let factExtractorSetting = try await kit.provisionedPreference(.factExtractor, for: handle)
            if let workerExecutableURL = ServeCommand.resolvedCurrentExecutableURL(),
               let extractor = FactExtractorBuilder.build(
                   masterSetting: factExtractionSetting, extractorSetting: factExtractorSetting,
                   settingsDirectory: factSettingsDirectory, workerExecutableURL: workerExecutableURL) {
                let spec = extractor.spec
                _ = try await kit.activateFactExtractor(
                    extractor, recipeID: "\(spec.providerID):\(spec.modelID):\(spec.modelVersion)", for: handle)
            }
        } catch {
            Logging.stderr.log("mootx01 drain: fact extraction not activated — \(error); its lane stays owed")
        }
        if ToolProjection.subjectRiderEnabled {
            do {
                try await kit.enableAppleSubjectRider(for: handle)
            } catch {
                Logging.stderr.log("mootx01 drain: subject rider unavailable — continuing without it (\(error))")
            }
        }

        // Poll the drain status (the same surface as `moot_drain_status`) until
        // the ENCODE drain is idle — the queue is empty whether this process
        // drained it (held the lease) or a resident did. Capped so a wedged
        // drain cannot hang forever.
        //
        // Keyed on the encode drain only via `DrainStatus.encodeSettled`
        // (PERF_W1_DRAIN_RIDER Finding 3): the "distillation" entry can only
        // settle via a `moot_distill` sweep or the hourly standing signal —
        // neither of which this command runs — so polling ALL drains would
        // spin to `maxWait` holding the encode DrainLease and wedge the next
        // serve session's encode queue. This finisher's contract is the
        // encode queue and its lease; it exits as soon as that is settled.
        let deadline = Date().addingTimeInterval(Self.maxWait)
        while Date() < deadline {
            let drains = (try? await kit.drainStatuses(handle)) ?? []
            if DrainStatus.encodeSettled(drains) { break }
            try? await Task.sleep(for: .seconds(1))
        }
        Logging.stderr.log("mootx01 drain: encode queue settled for estate '\(estateName)'")

        // The settle loop per row-debt duty (§ DUTY_LIFECYCLE): enqueue and
        // drain until the lane owes nothing or a batch pays nothing. One
        // progress line per batch so a script can watch it move.
        for kind in [DutyKind.spanEncode, .subjectBackfill, .factExtraction] {
            do {
                _ = try await kit.payDutyUntilSettled(kind, in: handle, now: Date()) { report in
                    Logging.stderr.log(
                        "mootx01 drain: \(kind.rawValue) — \(report.unitsPaid) paid, \(report.remainingDebt) remaining")
                }
            } catch {
                Logging.stderr.log("mootx01 drain warning: \(kind.rawValue) settle error: \(error) — continuing")
            }
        }
        Logging.stderr.log("mootx01 drain: duties settled for estate '\(estateName)' — exiting")
    }
}
#endif
