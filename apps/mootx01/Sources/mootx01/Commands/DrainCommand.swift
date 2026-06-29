// DrainCommand.swift
//
// Detached encode-drain finisher (T5). When an stdio `serve` that opened an
// estate DIRECTLY (no resident to forward to) exits — the client closed stdin,
// or a one-shot `query` terminated it — any encode work still queued would die
// with the process. `serve` spawns this command, detached, to finish the job: it
// opens the estate, mounts the corpus (whose lease-gated worker drains the
// persisted queue), waits until the queue is empty, then exits. The T3 lease
// keeps it from double-draining against a resident or another finisher.
//
// macOS-only for the same reason as ServeCommand (AriaMCP / GeniusLocusKit /
// SQLite are `.macOS(.v15)`); the Rust port carries the Windows/Linux drainer.

#if os(macOS)
import Foundation
import ArgumentParser
import AriaMCP
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitSQLite
import MootInstallerCore
import Darwin

struct DrainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drain",
        abstract: "Finish draining an estate's encode queue, then exit (detached background finisher)."
    )

    @Option(name: .long, help: "Named estate to drain. Default: active estate.")
    var db: String?

    /// Hard cap on total wait so a wedged drain can never hang forever.
    private static let maxWait: TimeInterval = 3600

    func run() async throws {
        // Detach into our own session so a process-group kill aimed at the parent
        // `serve` (e.g. the MCP client tearing down its child group) does not also
        // kill this finisher. A spawned child already survives the parent's pid
        // death on Unix; `setsid` hardens against group signals.
        setsid()

        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = MootPaths.resolveDataDirectory(environment: environment, homeDirectory: home)

        let estateName: String
        if let dbFlag = db {
            estateName = dbFlag
        } else {
            estateName = (try? DatabaseManager.activeEstateName(in: dataDir)) ?? "default"
        }
        let estateURL: URL
        if let envPath = environment["ARIA_MCP_SQLITE_PATH"], !envPath.isEmpty {
            estateURL = URL(fileURLWithPath: envPath)
        } else {
            estateURL = DatabaseManager.estateURL(for: estateName, in: dataDir)
        }
        // Nothing to drain if the estate file does not exist.
        guard FileManager.default.fileExists(atPath: estateURL.path) else { return }

        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: estateURL, busyTimeout: 5.0)
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
            handle = try await kit.open(storage: storage, owner: owner)
            // Wire the semantic layer so the corpus + its lease-gated drain worker
            // mount; the worker drains the persisted queue (taking the T3 lease
            // unless a resident holds it). Idempotent on reopen.
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage)
        } catch {
            Logging.stderr.log("mootx01 drain fatal: estate open/wiring failed: \(error)")
            throw ExitCode.failure
        }

        // Poll the drain status (the same surface as `moot_drain_status`) until
        // every drain is idle — the queue is empty whether this process drained it
        // (held the lease) or a resident did. Capped so a wedged drain cannot hang
        // forever.
        let deadline = Date().addingTimeInterval(Self.maxWait)
        while Date() < deadline {
            let drains = (try? await kit.drainStatuses(handle)) ?? []
            if !drains.contains(where: { $0.isDraining }) { break }
            try? await Task.sleep(for: .seconds(1))
        }
        Logging.stderr.log("mootx01 drain: encode queue settled for estate '\(estateName)' — exiting")
    }
}
#endif
