// StatusCommand.swift
//
// Show current serve state: running PID (if any), active estate name,
// wired MCP clients, and a brief estate summary (file size as proxy for
// content since a full estate open requires the macOS MCP stack).

import ArgumentParser
import Foundation
import MootInstallerCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show server state, active estate, and wired clients."
    )

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)

        print("mootx01 status")
        print("─────────────────────────────────")

        // Server liveness. Prefer the PID file, but the launchd resident daemon
        // serves the HTTP port WITHOUT owning that PID file — so fall back to a
        // direct TCP connection to the resident endpoint, the transport-level
        // truth. Without this, `status` reported "not running" while the daemon
        // was live on 4242, which read as a broken install.
        let pidURL = dataDir.appendingPathComponent("mootx01.pid", isDirectory: false)
        let residentPort = Int(env["MOOTX01_HTTP_PORT"] ?? "") ?? MootPaths.defaultResidentPort
        if let pidString = try? String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidString),
           processIsRunning(pid: pid) {
            print("Server: running (PID \(pid))")
        } else if portIsListening(port: residentPort) {
            print("Server: running (HTTP on 127.0.0.1:\(residentPort))")
        } else {
            print("Server: not running")
            // Remove stale PID file if the process is gone.
            if FileManager.default.fileExists(atPath: pidURL.path) {
                try? FileManager.default.removeItem(at: pidURL)
            }
        }

        // Active estate.
        let activeName = (try? DatabaseManager.activeEstateName(in: dataDir)) ?? "default"
        print("Active estate: \(activeName)")

        // Estate file info.
        let estateURL = DatabaseManager.estateURL(for: activeName, in: dataDir)
        if FileManager.default.fileExists(atPath: estateURL.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: estateURL.path)
            let size = attrs?[.size] as? Int ?? 0
            print("Estate file: \(estateURL.path) (\(formatBytes(size)))")
        } else {
            print("Estate file: not yet created (run `mootx01 serve` to initialise)")
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
        // kill(pid, 0) returns 0 if the process exists and the caller may signal
        // it, or -1 (ESRCH: no such process; EPERM: exists but not signallable).
        return kill(pid, 0) == 0
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
