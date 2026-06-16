import Foundation
import MootGateway
import AriaMCP

// MARK: - DaemonController  (macOS only — drives the app-managed daemon)
//
// ADR-005's macOS "extra": the app spawns the real, untouched server binary
// and supervises it. This controller wraps `ManagedServerProcess` for the
// Engine tab — start/stop, a liveness check (tools/list), and the handoff
// hook. iOS/iPadOS have no analog (no persistent subprocess), so this whole
// type is macOS-gated.

#if os(macOS)

@MainActor
@Observable
public final class DaemonController {

    /// Path to the clean server binary the app will spawn. Defaults to a
    /// dev build location; the user can point it anywhere (it is the real,
    /// Rust-mirrored binary — the app adds nothing to it).
    public var binaryPath: String = ""

    /// Optional estate to hand the daemon (SQLite). Empty = the daemon runs
    /// its own ephemeral in-memory estate. A real handoff of the *app's* live
    /// estate additionally requires closing it in-app first (one host per
    /// estate, ADR-005) — that clean close() is an engine follow-up; this
    /// panel demonstrates spawning + supervising a daemon on its own estate.
    public var handoffDatabasePath: String = ""

    public private(set) var isRunning = false
    public private(set) var status = "Stopped"
    public private(set) var lastToolCount: Int?

    private var server: ManagedServerProcess?

    public init() {}

    /// Spawn and supervise the daemon, then prove it's alive with tools/list.
    public func start() async {
        guard server == nil else { return }
        let binaryURL = URL(fileURLWithPath: binaryPath)
        let dbURL = handoffDatabasePath.isEmpty ? nil : URL(fileURLWithPath: handoffDatabasePath)
        let proc = ManagedServerProcess(binaryURL: binaryURL, databaseURL: dbURL)
        do {
            try await proc.start()
            server = proc
            isRunning = true
            status = "Running · \(binaryURL.lastPathComponent)"
            await verify()
        } catch {
            status = "Failed to start: \(error)"
            server = nil
            isRunning = false
        }
    }

    /// Round-trip tools/list against the managed daemon — proof the spawned
    /// process is the real server answering on stdio.
    public func verify() async {
        guard let server else { return }
        do {
            let response = try await server.send(method: "tools/list", params: nil)
            if case .result(let value) = response.payload {
                lastToolCount = value.objectValue?["tools"]?.arrayValue?.count
                status = "Running · \(lastToolCount ?? 0) tools answered over stdio"
            }
        } catch {
            status = "Verify failed: \(error)"
        }
    }

    public func stop() async {
        await server?.stop()
        server = nil
        isRunning = false
        lastToolCount = nil
        status = "Stopped"
    }
}

#endif
