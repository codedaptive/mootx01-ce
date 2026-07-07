// LaunchAgent.swift
//
// Installs the moot-mgr resident host (the management & monitoring console)
// as a per-user launchd LaunchAgent so the loopback dashboard runs in the
// background, starts at login, and restarts if it exits. macOS-only: launchd
// is the platform's service manager, and moot-mgr is itself macOS-only
// (.macOS(.v26), GeniusLocusKit-backed).
//
// `makePlist` is pure (string in → string out) so the plist contract is
// unit-testable without touching launchd; the install/uninstall entry points
// shell out to /bin/launchctl and are compiled only on macOS.

import Foundation

/// Manages the `com.mootx01.mgr` LaunchAgent: plist generation, load + start,
/// and teardown.
public enum LaunchAgent {

    /// Default loopback port the moot-mgr dashboard binds (ResidentHost.nPort).
    /// Surfaced here only to compose the user-facing dashboard URL; the
    /// resident host owns the authoritative default and may rebind if the
    /// MOOTX01_MGR_HTTP_PORT env override is set.
    public static let defaultDashboardPort: Int = 4200

    /// User-facing dashboard URL for the default port.
    public static var defaultDashboardURL: String {
        "http://127.0.0.1:\(defaultDashboardPort)"
    }

    /// Outcome of an install/uninstall attempt, for caller messaging.
    public enum Status: Sendable, Equatable {
        /// LaunchAgent written and bootstrapped; carries the plist path and
        /// the dashboard URL to print.
        case installed(plistPath: String, dashboardURL: String)
        /// No moot-mgr binary to point the agent at (dev build of mootx01
        /// alone, or a non-macOS install).
        case binaryNotFound
        /// `launchctl` (or the plist write) failed; carries the diagnostic.
        case launchctlFailed(String)
    }

    /// Generate the LaunchAgent property list XML for the moot-mgr resident
    /// host.
    ///
    /// - `RunAtLoad` + `KeepAlive` start it immediately and keep it up across
    ///   crashes and logout/login.
    /// - `ProcessType = Interactive`: the daemon serves LIVE user requests
    ///   (MCP tool calls from Claude Desktop/Code) and its encode pipeline is
    ///   designed to "drain hard on the performance cores". The previous
    ///   `Background` value made launchd clamp the WHOLE process to the
    ///   efficiency cores with throttled I/O — no task-level priority can
    ///   escape a process-level clamp — and a palace import that completed in
    ///   83 s on a shell-launched daemon ran 20x slower under launchd, starving
    ///   tool responses past Claude Desktop's ~4-minute client timeout.
    /// - stdout/stderr are captured to the logs dir so a failed launch is
    ///   diagnosable after the fact.
    ///
    /// Path values are XML-escaped so a home directory containing `&`/`<`/`>`
    /// cannot corrupt the plist.
    ///
    /// - Parameters:
    ///   - label: launchd job label (also the plist `Label`).
    ///   - programArguments: the binary path + args (e.g. `[binary, "serve"]`).
    ///   - stdoutPath: file the job's stdout is appended to.
    ///   - stderrPath: file the job's stderr is appended to.
    ///   - environmentVariables: optional `EnvironmentVariables` dict — the
    ///     resident mootx01 daemon needs this (MOOTX01_HTTP_PORT etc.); the
    ///     moot-mgr agent passes none. Emitted in sorted order so the plist is
    ///     deterministic (testable).
    /// - Returns: the complete plist XML document.
    public static func makePlist(
        label: String,
        programArguments: [String],
        stdoutPath: String,
        stderrPath: String,
        environmentVariables: [String: String] = [:]
    ) -> String {
        // Assembled line-by-line (not a single multi-line literal) so the
        // optional EnvironmentVariables block can't trip Swift's multi-line-string
        // indentation rules.
        var lines: [String] = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            "<plist version=\"1.0\">",
            "<dict>",
            "    <key>Label</key>",
            "    <string>\(xmlEscape(label))</string>",
            "    <key>ProgramArguments</key>",
            "    <array>",
        ]
        for arg in programArguments {
            lines.append("        <string>\(xmlEscape(arg))</string>")
        }
        lines.append("    </array>")
        if !environmentVariables.isEmpty {
            lines.append("    <key>EnvironmentVariables</key>")
            lines.append("    <dict>")
            for (key, value) in environmentVariables.sorted(by: { $0.key < $1.key }) {
                lines.append("        <key>\(xmlEscape(key))</key>")
                lines.append("        <string>\(xmlEscape(value))</string>")
            }
            lines.append("    </dict>")
        }
        lines.append(contentsOf: [
            "    <key>RunAtLoad</key>",
            "    <true/>",
            "    <key>KeepAlive</key>",
            "    <true/>",
            "    <key>ProcessType</key>",
            "    <string>Interactive</string>",
            "    <key>StandardOutPath</key>",
            "    <string>\(xmlEscape(stdoutPath))</string>",
            "    <key>StandardErrorPath</key>",
            "    <string>\(xmlEscape(stderrPath))</string>",
            "</dict>",
            "</plist>",
        ])
        return lines.joined(separator: "\n")
    }

    /// Minimal XML text-content escaping for plist string values.
    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    #if os(macOS)
    /// Write the LaunchAgent plist and load + start the job. Idempotent:
    /// any prior instance is booted out first, so re-running `mootx01 install`
    /// cleanly replaces the service.
    ///
    /// - Parameters:
    ///   - mgrBinaryPath: absolute path of the placed `moot-mgr` binary.
    ///   - homeDirectory: the user's home directory.
    /// - Returns: a `Status` describing the outcome for the caller to print.
    public static func install(
        mgrBinaryPath: String,
        homeDirectory: URL
    ) -> Status {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: mgrBinaryPath) else {
            return .binaryNotFound
        }

        let plistURL = MootPaths.launchAgentPlistURL(homeDirectory: homeDirectory)
        let logsDir = MootPaths.logsDirURL(homeDirectory: homeDirectory)
        let stdoutPath = logsDir.appendingPathComponent("moot-mgr.out.log").path
        let stderrPath = logsDir.appendingPathComponent("moot-mgr.err.log").path
        let label = MootPaths.launchAgentLabel

        do {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let plist = makePlist(
                label: label,
                programArguments: [mgrBinaryPath, "serve"],
                stdoutPath: stdoutPath,
                stderrPath: stderrPath
            )
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            return .launchctlFailed("could not write LaunchAgent plist: \(error)")
        }

        let result = bootstrapJob(plistURL: plistURL, label: label)
        guard result.ok else { return .launchctlFailed(result.detail) }
        return .installed(plistPath: plistURL.path, dashboardURL: defaultDashboardURL)
    }

    /// Write the resident mootx01 daemon plist (with EnvironmentVariables) and
    /// load + start it under launchd, mirroring `install` but for the
    /// `com.mootx01.daemon` label. The `environment` dict becomes the plist's
    /// `EnvironmentVariables` — at minimum `MOOTX01_HTTP_PORT` (which switches
    /// `mootx01 serve` into resident HTTP mode), plus the data dir and the
    /// stats-store path so the daemon self-reports to moot-mgr out of the box.
    public static func installDaemon(
        binaryPath: String,
        homeDirectory: URL,
        environment: [String: String]
    ) -> Status {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: binaryPath) else { return .binaryNotFound }

        let plistURL = MootPaths.daemonPlistURL(homeDirectory: homeDirectory)
        let logsDir = MootPaths.logsDirURL(homeDirectory: homeDirectory)
        let stdoutPath = logsDir.appendingPathComponent("mootx01-daemon.out.log").path
        let stderrPath = logsDir.appendingPathComponent("mootx01-daemon.err.log").path
        let label = MootPaths.daemonLabel

        do {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist = makePlist(
                label: label,
                programArguments: [binaryPath, "serve"],
                stdoutPath: stdoutPath,
                stderrPath: stderrPath,
                environmentVariables: environment
            )
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            return .launchctlFailed("could not write daemon LaunchAgent plist: \(error)")
        }

        let result = bootstrapJob(plistURL: plistURL, label: label)
        guard result.ok else { return .launchctlFailed(result.detail) }
        let port = environment["MOOTX01_HTTP_PORT"] ?? "4242"
        return .installed(plistPath: plistURL.path, dashboardURL: "http://127.0.0.1:\(port)")
    }

    /// bootout → bootstrap (legacy load fallback) → kickstart for a written
    /// plist. Shared by `install` and `installDaemon` so both agents load
    /// identically.
    private static func bootstrapJob(plistURL: URL, label: String) -> (ok: Bool, detail: String) {
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(label)"
        // Tear down any prior instance so bootstrap doesn't fail "already loaded".
        _ = runLaunchctl(["bootout", target])
        // bootout is ASYNCHRONOUS — and worse than a failed bootstrap: a
        // bootout completing late can tear down the freshly bootstrapped
        // replacement job (observed live: install verified the job loaded,
        // and moments later launchd had nothing). Wait until launchd actually
        // reports the job gone before bootstrapping the new one.
        var teardownDone = false
        for _ in 1...20 {
            if runLaunchctl(["print", target]).code != 0 {
                teardownDone = true
                break
            }
            usleep(250_000)  // 250 ms; up to 5 s for the teardown to finish
        }
        // (#88) If the old job persists after 5 s, try one more forced bootout.
        // Without this, bootstrap fails on "already loaded" and the verify
        // step sees the STALE job, falsely reporting success.
        if !teardownDone {
            _ = runLaunchctl(["bootout", target])
            usleep(500_000)
            teardownDone = runLaunchctl(["print", target]).code != 0
        }
        if !teardownDone {
            return (false, "prior job still registered after bootout; launchd teardown timed out")
        }
        // Bootstrap with verify-and-retry: after each attempt, confirm launchd
        // actually has the job before declaring success. A bootstrap or load
        // call must have succeeded at least once — print alone is not proof
        // of the new job.
        var lastDetail = ""
        for attempt in 1...5 {
            var loaded = false
            let boot = runLaunchctl(["bootstrap", domain, plistURL.path])
            if boot.code == 0 {
                loaded = true
            } else {
                let legacy = runLaunchctl(["load", "-w", plistURL.path])
                if legacy.code == 0 {
                    loaded = true
                } else {
                    lastDetail = (boot.output.isEmpty ? legacy.output : boot.output)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            // Verify: bootstrap/load succeeded AND launchd sees the job.
            if loaded, runLaunchctl(["print", target]).code == 0 {
                // RunAtLoad already started it; kickstart makes "running now" explicit.
                _ = runLaunchctl(["kickstart", "-k", target])
                return (true, "")
            }
            if attempt < 5 { usleep(300_000) }  // 300 ms before retrying
        }
        return (false, lastDetail.isEmpty ? "job not registered after 5 bootstrap attempts" : lastDetail)
    }

    /// Restart both mootx01 background agents (daemon + moot-mgr console) using
    /// their already-written plists. Called by `mootx01 upgrade` after the binary
    /// has been replaced — the plist paths and env do not change, so no rewrite
    /// is needed.
    ///
    /// Returns `.installed` on success (dashboardURL is the moot-mgr URL) or
    /// `.launchctlFailed` if either kickstart fails. The daemon is restarted first;
    /// moot-mgr second (so the console reconnects to the fresh daemon).
    public static func restart(homeDirectory: URL) -> Status {
        let daemonPlist = MootPaths.daemonPlistURL(homeDirectory: homeDirectory)
        let mgrPlist    = MootPaths.launchAgentPlistURL(homeDirectory: homeDirectory)
        let fm = FileManager.default

        // Restart the resident daemon first so moot-mgr reconnects to the
        // fresh daemon process when it comes up.
        if fm.fileExists(atPath: daemonPlist.path) {
            let r = bootstrapJob(plistURL: daemonPlist, label: MootPaths.daemonLabel)
            if !r.ok { return .launchctlFailed("daemon: \(r.detail)") }
        }

        // Restart the moot-mgr management console.
        if fm.fileExists(atPath: mgrPlist.path) {
            let r = bootstrapJob(plistURL: mgrPlist, label: MootPaths.launchAgentLabel)
            if !r.ok { return .launchctlFailed("moot-mgr: \(r.detail)") }
        }

        return .installed(plistPath: daemonPlist.path, dashboardURL: defaultDashboardURL)
    }

    /// Stop and remove the LaunchAgent. Idempotent — safe when nothing is
    /// installed. Call this BEFORE deleting the moot-mgr binary so the running
    /// job is stopped first.
    ///
    /// - Parameter homeDirectory: the user's home directory.
    public static func uninstall(homeDirectory: URL) {
        let fm = FileManager.default
        let plistURL = MootPaths.launchAgentPlistURL(homeDirectory: homeDirectory)
        let target = "gui/\(getuid())/\(MootPaths.launchAgentLabel)"

        _ = runLaunchctl(["bootout", target])

        if (try? fm.destinationOfSymbolicLink(atPath: plistURL.path)) != nil
            || fm.fileExists(atPath: plistURL.path) {
            try? fm.removeItem(at: plistURL)
        }
    }

    /// Stop and remove the resident mootx01 daemon LaunchAgent
    /// (`com.mootx01.daemon`). Idempotent. Call before deleting the binary.
    public static func uninstallDaemon(homeDirectory: URL) {
        let fm = FileManager.default
        let plistURL = MootPaths.daemonPlistURL(homeDirectory: homeDirectory)
        let target = "gui/\(getuid())/\(MootPaths.daemonLabel)"

        _ = runLaunchctl(["bootout", target])

        if (try? fm.destinationOfSymbolicLink(atPath: plistURL.path)) != nil
            || fm.fileExists(atPath: plistURL.path) {
            try? fm.removeItem(at: plistURL)
        }
    }

    /// Run `/bin/launchctl` with `args`; capture combined stdout+stderr and
    /// the exit code. launchctl is the only supported control surface for
    /// per-user LaunchAgents.
    private static func runLaunchctl(_ args: [String]) -> (code: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "\(error)")
        }
    }
    #endif
}
