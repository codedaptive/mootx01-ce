// StatusCommand.swift
//
// Show current serve state with the OBSERVED vocabulary (MACD-2c2, P-c2-10):
// registration, PID, and port answers are reported as the observations they
// are — never equated with a running/ready server. Also shows the active
// estate name, wired MCP clients, and a brief estate summary (file size as
// proxy for content since a full estate open requires the macOS MCP stack).

import ArgumentParser
import Foundation
import GeniusLocusKit
import MootInstallerCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show server state, active estate, and wired clients."
    )

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment

        // Catalog load to resolve the active record's PID file path.
        // `EstateCatalog.load()` is read-only and fast; a catalog that does
        // not exist yet (first install) returns `.failure`, and `pidURL`
        // remains nil — the PID observation is skipped, which is correct
        // (no serve has ever run on this machine).
        let activeRecord = try? EstateCatalog.load().active
        // The PID file is `estate.pid` inside the estate's own directory,
        // not `mootx01.pid` at the catalog root. The path is owned by the
        // estate record to stay in sync with serve and upgrade.
        let pidURL: URL? = activeRecord?.pidURL

        print("mootx01 status")
        print("─────────────────────────────────")

        // Server state — OBSERVED vocabulary (MACD-2c2, P-c2-10): a PID file, a
        // launchd registration, or an answering TCP port is NEVER equated
        // with a running/ready server. Readiness belongs exclusively to the
        // signed provider's OWN authenticated report; port liveness never
        // elects (Kong). This command reports OBSERVATIONS, classified:
        //   - registration: does a daemon LaunchAgent plist exist (legacy
        //     raw-serve label or the bundle label)?
        //   - port: does something accept a TCP connection (identity
        //     unverified — could be any process)?
        //   - provider report: the descriptor/authenticated readiness surface
        //     remains authoritative; a registration or open port alone is not.
        let rawPort = Int(env["MOOTX01_HTTP_PORT"] ?? "") ?? MootPaths.defaultResidentPort
        let residentPort = (1...65535).contains(rawPort) ? rawPort : MootPaths.defaultResidentPort
        #if os(macOS)
        // MACD-3B3 C5: run the authenticated ownership probe so the provider's
        // verbatim state flows into `observedServerStatus`.  This surface owns no
        // second copy of the arbiter vocabulary — the format rule lives in
        // `LaunchAgent.authenticatedBundledOwner` (P-c2-10, rule at line 183).
        // The probe is fail-closed: subprocess failure, JSON parse error, and
        // any unrecognised outcome map to `.absent` or `.unauthenticated`, never
        // to a false `.healthy`.
        let ownerOutcome = ProviderOwnershipProbe().detect(homeDirectory: home)
        let providerReportedState = LaunchAgent.authenticatedBundledOwner(outcome: ownerOutcome)
        let legacyRegistered = FileManager.default.fileExists(
            atPath: MootPaths.daemonPlistURL(homeDirectory: home).path
        )
        let bundleRegistered = FileManager.default.fileExists(
            atPath: DaemonBundle.launchAgentPlistURL(homeDirectory: home).path
        )
        let registration: LaunchAgent.DaemonRegistrationObservation =
            (legacyRegistered || bundleRegistered) ? .registered : .none
        let port: LaunchAgent.DaemonPortObservation =
            portIsListening(port: residentPort) ? .answering : .unbound
        print("Server: \(LaunchAgent.observedServerStatus(registration: registration, port: port, providerReportedState: providerReportedState))")
        if bundleRegistered {
            print("Daemon provider bundle: enabled registration present (launchd: \(DaemonBundle.launchAgentLabel))")
        }
        #else
        print("Server: \(portIsListening(port: residentPort) ? "port answering (unverified — not proof of readiness)" : "not running")")
        #endif
        // A PID file whose process is verifiably a live mootx01 binary is an
        // OBSERVATION worth surfacing (identity-verified, still not
        // readiness); a stale one is removed.
        if let pidURL,
           let pidString = try? String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString) {
            if processIsRunning(pid: pid) {
                print("Foreground serve process: PID \(pid) (identity-verified mootx01; not proof of resident readiness)")
            } else if FileManager.default.fileExists(atPath: pidURL.path) {
                try? FileManager.default.removeItem(at: pidURL)
            }
        }

        // Active estate, from the catalog. Status reports; it does not create
        // the catalog, so a machine that has never run install or serve says so.
        switch Result(catching: { try EstateCatalog.load().active }) {
        case .success(let active):
            print("Active estate: \(active.name)")
            let estateURL = active.databaseURL
            if FileManager.default.fileExists(atPath: estateURL.path) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: estateURL.path)
                let size = attrs?[.size] as? Int ?? 0
                print("Estate file: \(estateURL.path) (\(formatBytes(size)))")
            } else {
                print("Estate file: not yet created (run `mootx01 serve` to initialise)")
            }
        case .failure(let error):
            print("Active estate: none (\(error))")
        }

        // Wired clients.
        print("")
        print("Wired clients:")
        var found = false
        for client in MCPClients.supported {
            // Format-aware wired detection (JSON per-client key, TOML table,
            // YAML entry line) — the old inline JSON-only check was blind to
            // Codex (TOML) and Hermes (YAML) wiring.
            if client.wired(homeDirectory: home) {
                print("  ✓ \(client.displayName)")
                found = true
            }
        }
        if !found {
            print("  (none — run `mootx01 install` to wire clients)")
        }

        print("")
    }

    // MARK: - Helpers

    private func processIsRunning(pid: Int32) -> Bool {
        // Identity-verified liveness: PIDs recycle across reboots, so a bare
        // kill(pid, 0) on a stale PID file reports an unrelated process as a
        // "running" server. The PID counts only if it is a mootx01 binary.
        ProcessIdentity.isLiveProcess(pid)
    }

    /// True if something accepts a TCP connection on 127.0.0.1:port. Used as the
    /// authoritative liveness signal for the resident HTTP daemon, which runs
    /// under launchd and does not own the CLI PID file.
    private func portIsListening(port: Int, timeoutMs: Int = 400) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: Int32(timeoutMs * 1000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / (1024 * 1024)) MB"
    }
}
