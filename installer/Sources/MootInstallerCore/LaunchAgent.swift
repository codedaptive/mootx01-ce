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
    public static let defaultDashboardPort: Int = 7077

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
    /// - `ProcessType = Background` tells the scheduler this is a
    ///   non-interactive service (lower CPU priority, no app-nap surprises).
    /// - stdout/stderr are captured to the logs dir so a failed launch is
    ///   diagnosable after the fact.
    ///
    /// Path values are XML-escaped so a home directory containing `&`/`<`/`>`
    /// cannot corrupt the plist.
    ///
    /// - Parameters:
    ///   - mgrBinaryPath: absolute path of the placed `moot-mgr` binary.
    ///   - label: launchd job label (also the plist `Label`).
    ///   - stdoutPath: file the job's stdout is appended to.
    ///   - stderrPath: file the job's stderr is appended to.
    /// - Returns: the complete plist XML document.
    public static func makePlist(
        mgrBinaryPath: String,
        label: String,
        stdoutPath: String,
        stderrPath: String
    ) -> String {
        let bin = xmlEscape(mgrBinaryPath)
        let out = xmlEscape(stdoutPath)
        let err = xmlEscape(stderrPath)
        let lbl = xmlEscape(label)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(lbl)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(bin)</string>
                <string>serve</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(out)</string>
            <key>StandardErrorPath</key>
            <string>\(err)</string>
        </dict>
        </plist>
        """
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
                mgrBinaryPath: mgrBinaryPath,
                label: label,
                stdoutPath: stdoutPath,
                stderrPath: stderrPath
            )
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            return .launchctlFailed("could not write LaunchAgent plist: \(error)")
        }

        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(label)"

        // Tear down any prior instance so bootstrap doesn't fail with "service
        // already loaded". Ignore the result — it errors when nothing is loaded.
        _ = runLaunchctl(["bootout", target])

        // Modern load path (macOS 11+): bootstrap into the per-user GUI domain.
        let boot = runLaunchctl(["bootstrap", domain, plistURL.path])
        if boot.code != 0 {
            // Fall back to the legacy load for older launchd, then surface the
            // error only if that also fails.
            let legacy = runLaunchctl(["load", "-w", plistURL.path])
            if legacy.code != 0 {
                let detail = boot.output.isEmpty ? legacy.output : boot.output
                return .launchctlFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        // RunAtLoad should already have started it; kickstart makes "running
        // now" explicit and restarts it if a stale instance lingered.
        _ = runLaunchctl(["kickstart", "-k", target])

        return .installed(plistPath: plistURL.path, dashboardURL: defaultDashboardURL)
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
