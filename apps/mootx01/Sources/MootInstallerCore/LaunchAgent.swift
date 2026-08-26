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
        /// MACD-2c2: the DISABLED bundle-form LaunchAgent plist was written
        /// and verified by readback — deliberately NOT bootstrapped (the
        /// daemon bundle activates with MACD-3). Carries the plist path.
        case installedDisabled(plistPath: String)
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
    ///   - runAtLoad: launchd `RunAtLoad`. Defaults true (the legacy agents'
    ///     contract). The MACD-2c2 daemon-bundle plist passes false — the
    ///     DISABLED-install variant (KONG-4): registered, never auto-started.
    ///   - keepAlive: launchd `KeepAlive`. Defaults true; the bundle plist
    ///     passes false so a manual start of the not-yet-activated resident
    ///     mode cannot make launchd thrash on its honest refusal exit.
    /// - Returns: the complete plist XML document.
    public static func makePlist(
        label: String,
        programArguments: [String],
        stdoutPath: String,
        stderrPath: String,
        environmentVariables: [String: String] = [:],
        runAtLoad: Bool = true,
        keepAlive: Bool = true
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
            runAtLoad ? "    <true/>" : "    <false/>",
            "    <key>KeepAlive</key>",
            keepAlive ? "    <true/>" : "    <false/>",
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

    // MARK: - MACD-2c2 — the daemon-bundle LaunchAgent (KONG-4)

    /// The DISABLED-install bundle-form daemon plist: ProgramArguments point
    /// INSIDE the bundle's `Contents/MacOS` (never a raw binary with
    /// "serve"), `RunAtLoad` and `KeepAlive` are false, and the label is the
    /// bundle's own (`DaemonBundle.launchAgentLabel`) so the legacy
    /// raw-serve registration is retained untouched until authenticated
    /// readiness (MACD-3). Pure — unit-testable without launchd.
    public static func makeDaemonBundlePlist(homeDirectory: URL) -> String {
        let logsDir = MootPaths.logsDirURL(homeDirectory: homeDirectory)
        return makePlist(
            label: DaemonBundle.launchAgentLabel,
            programArguments: DaemonBundle.programArguments(homeDirectory: homeDirectory),
            stdoutPath: logsDir.appendingPathComponent("mootx01-provider.out.log").path,
            stderrPath: logsDir.appendingPathComponent("mootx01-provider.err.log").path,
            runAtLoad: false,
            keepAlive: false
        )
    }

    // MARK: - CORE-09 — ENABLED bundle plist (resident mode is real, Wave A1b)

    /// The ENABLED bundle-form daemon plist: identical to the disabled variant
    /// except `RunAtLoad` and `KeepAlive` are both true, so launchd starts
    /// the provider at login and restarts it on unexpected exit (documented
    /// restart policy).
    ///
    /// Now that resident mode is real (Wave A1b shipped
    /// `CommunityResidentMain.run`), the installer writes this variant.
    /// The DISABLED path (`makeDaemonBundlePlist` / `installDaemonBundleDisabled`)
    /// is preserved for rollback and audit purposes.
    ///
    /// Pure — unit-testable without launchd.
    public static func makeDaemonBundlePlistEnabled(homeDirectory: URL) -> String {
        let logsDir = MootPaths.logsDirURL(homeDirectory: homeDirectory)
        return makePlist(
            label: DaemonBundle.launchAgentLabel,
            programArguments: DaemonBundle.programArguments(homeDirectory: homeDirectory),
            stdoutPath: logsDir.appendingPathComponent("mootx01-provider.out.log").path,
            stderrPath: logsDir.appendingPathComponent("mootx01-provider.err.log").path,
            runAtLoad: true,   // ENABLED: start at login
            keepAlive: true    // ENABLED: restart on unexpected exit
        )
    }

    // MARK: - CORE-09 — enabled install + preservation reporting

    /// Write the ENABLED bundle-form daemon plist, verify it by readback, and
    /// confirm the service identity (label) and executable path are present.
    ///
    /// This is the CORE-09 successor to `installDaemonBundleDisabled`: now
    /// that resident mode is real, the installer activates the service with
    /// RunAtLoad=true/KeepAlive=true.  The launchctl bootstrap side effect is
    /// physical evidence — it stays behind the existing physical boundary and
    /// is NOT performed here.  This function's contract is:
    ///   1. Write the enabled plist (deterministic bytes from the generator).
    ///   2. Read it back: the on-disk bytes must equal the generator's output.
    ///   3. Parse the readback to confirm the service identity (label) matches
    ///      `DaemonBundle.launchAgentLabel` and the executable path is the one
    ///      the generator produced.
    ///
    /// "Installation reports success only when the expected service identity
    /// and executable are registered" — CORE-09 acceptance criteria.
    ///
    /// Returns `.installed(plistPath:dashboardURL:)` on success or
    /// `.launchctlFailed` when any step refuses.
    public static func installDaemonBundleEnabled(homeDirectory: URL) -> Status {
        let fm = FileManager.default
        let plistURL = DaemonBundle.launchAgentPlistURL(homeDirectory: homeDirectory)
        let expected = makeDaemonBundlePlistEnabled(homeDirectory: homeDirectory)

        // Write the enabled plist, creating parent directories as needed.
        do {
            try fm.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try expected.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            return .launchctlFailed("could not write daemon bundle enabled plist: \(error)")
        }

        // Readback: the on-disk bytes must BE the generator's — a partial
        // write or interference is reported, never silently accepted.
        guard let onDisk = try? String(contentsOf: plistURL, encoding: .utf8),
              onDisk == expected else {
            return .launchctlFailed(
                "daemon bundle enabled plist readback mismatch at \(plistURL.path)"
            )
        }

        // Service-identity readback: parse the plist and confirm the label
        // and executable path are what the generator prescribed (CORE-09:
        // "installation reports success only when service identity and
        // executable are registered").
        guard let plistData = onDisk.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: plistData, format: nil),
              let dict = obj as? [String: Any],
              let label = dict["Label"] as? String,
              label == DaemonBundle.launchAgentLabel,
              let args = dict["ProgramArguments"] as? [String],
              let executablePath = args.first,
              executablePath == DaemonBundle.bundleExecutableURL(homeDirectory: homeDirectory).path
        else {
            return .launchctlFailed(
                "daemon bundle plist identity or executable path did not verify at \(plistURL.path)"
            )
        }

        // The dashboard URL for the provider is the resident daemon's
        // loopback endpoint (not the moot-mgr dashboard port).
        return .installed(
            plistPath: plistURL.path,
            dashboardURL: MootPaths.residentEndpointURL
        )
    }

    // MARK: - CORE-09 — typed blocked state assessment

    /// What the status surface observed about the daemon provider bundle
    /// installation — pure path/plist inspection, no launchd query.
    ///
    /// Used by CORE-09 to produce a typed blocked state when an installation
    /// is present but broken, so the application surface can distinguish a
    /// healthy installation from an incompatible or corrupted one without
    /// crashing or lying.
    public enum InstallationAssessment: Sendable, Equatable {
        /// The installation is consistent: plist exists, executable is present
        /// and executable, and the plist content matches the enabled generator's
        /// expected output for this home directory.
        case ok(plistPath: String, executablePath: String)
        /// The installation is present but broken — a typed blocked state
        /// rather than a crash or a silent success lie.
        case blocked(reason: InstallationBlockedReason)
    }

    /// The reason an installation is blocked. Each case is a distinct,
    /// diagnosable failure mode; no case conflates two problems (CORE-09:
    /// "a broken or incompatible installation produces a typed blocked state").
    public enum InstallationBlockedReason: String, Sendable, Equatable {
        /// No plist file at the expected location.
        case missingPlist
        /// Plist present, but its content does not match the enabled
        /// generator's canonical output for this home directory — written by a
        /// different version, manually edited, or partially written.
        case plistContentMismatch
        /// Plist content matches, but the executable path it names is absent.
        case missingExecutable
        /// Plist and executable present, but the file at the executable
        /// path is not executable (wrong permissions, not a regular file,
        /// or a directory in place of it).
        case executableNotExecutable
    }

    /// Assess the daemon-bundle installation — pure filesystem inspection,
    /// no launchctl, no process interaction.
    ///
    /// Readiness (descriptor published + identity endpoint answering) is NOT
    /// assessed here. This function answers ONLY whether the installation
    /// artifacts are present and self-consistent: a healthy installation may
    /// still be starting, and a blocked one needs operator attention.
    ///
    /// - Parameter homeDirectory: the user's home directory.
    /// - Returns: `.ok` when plist and executable are present and consistent;
    ///   `.blocked` with a typed reason when any check fails.
    public static func assessDaemonBundleInstallation(homeDirectory: URL) -> InstallationAssessment {
        let plistURL = DaemonBundle.launchAgentPlistURL(homeDirectory: homeDirectory)
        let executableURL = DaemonBundle.bundleExecutableURL(homeDirectory: homeDirectory)

        // 1. Plist must exist at the expected location.
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            return .blocked(reason: .missingPlist)
        }
        // 2. Plist content must match the ENABLED generator's canonical bytes.
        //    The disabled plist is no longer valid after a CORE-09 install.
        guard let onDisk = try? String(contentsOf: plistURL, encoding: .utf8),
              onDisk == makeDaemonBundlePlistEnabled(homeDirectory: homeDirectory) else {
            return .blocked(reason: .plistContentMismatch)
        }
        // 3. Executable path named in the plist must exist.
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            return .blocked(reason: .missingExecutable)
        }
        // 4. The file at that path must be executable — a non-executable file
        //    would make launchd fail on every launch attempt, thrashing.
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .blocked(reason: .executableNotExecutable)
        }
        return .ok(plistPath: plistURL.path, executablePath: executableURL.path)
    }

    // MARK: - CORE-09 — uninstall preservation reporting

    /// What the uninstall surface reports about one class of artifacts
    /// (CORE-09: "removal reports whether daemon configuration and estate
    /// data are retained or removed").
    public enum UninstallPreservation: String, Sendable, Equatable {
        /// No artifact of this class was present — nothing to retain or remove.
        case absent
        /// The artifact is present and will be / was retained (user data;
        /// requires an explicit purge command to remove).
        case retained
        /// The artifact was removed as part of this uninstall operation.
        case removed
    }

    /// The two-class uninstall preservation report.
    public struct UninstallReport: Sendable, Equatable {
        /// The LaunchAgent plist and bundle binaries (service registration
        /// artifacts, not user data — removed by a standard uninstall).
        public let daemonConfiguration: UninstallPreservation
        /// The estate database in Application Support (user data — NEVER
        /// touched by a standard uninstall; explicit purge only).
        public let estateData: UninstallPreservation

        public init(
            daemonConfiguration: UninstallPreservation,
            estateData: UninstallPreservation
        ) {
            self.daemonConfiguration = daemonConfiguration
            self.estateData = estateData
        }
    }

    /// Observe the preservation status of daemon configuration and estate data
    /// — pure filesystem inspection, no removal performed.
    ///
    /// Two artifact classes are deliberately distinct (CORE-09):
    /// - **Daemon configuration**: service artifacts (plist, bundle) — removed
    ///   on uninstall; `.retained` when still present after a dry-run or before
    ///   the physical launchctl step runs.
    /// - **Estate data**: Application Support database — user data; retained
    ///   across every uninstall; never removed here.
    ///
    /// - Parameters:
    ///   - homeDirectory: the user's home directory.
    ///   - dataDirectory: the resolved Application Support data directory
    ///     (e.g. `MootPaths.resolveDataDirectory(environment:homeDirectory:)`).
    /// - Returns: an `UninstallReport` naming what was observed.
    public static func reportUninstallPreservation(
        homeDirectory: URL,
        dataDirectory: URL
    ) -> UninstallReport {
        let fm = FileManager.default
        // Daemon configuration: any owned artifact present means the config
        // class is present (retained until the physical removal step runs).
        let ownedPaths = DaemonBundle.ownedArtifactPaths(homeDirectory: homeDirectory)
        let configPresent = ownedPaths.contains { fm.fileExists(atPath: $0) }
        let configStatus: UninstallPreservation = configPresent ? .retained : .absent

        // Estate data: estate.sqlite plus its SQLite WAL sidecar files.
        let estateFile = MootPaths.estateURL(in: dataDirectory)
        let estatePresent = fm.fileExists(atPath: estateFile.path)
            || fm.fileExists(atPath: estateFile.path + "-wal")
            || fm.fileExists(atPath: estateFile.path + "-shm")
        let estateStatus: UninstallPreservation = estatePresent ? .retained : .absent

        return UninstallReport(daemonConfiguration: configStatus, estateData: estateStatus)
    }

    // MARK: - MACD-2c2 — honest status vocabulary (P-c2-10)

    /// What the status surface observed about the bundle registration.
    public enum DaemonRegistrationObservation: String, Sendable, Equatable {
        /// No registration found.
        case none
        /// A LaunchAgent registration exists.
        case registered
    }

    /// What the status surface observed about the resident port.
    public enum DaemonPortObservation: String, Sendable, Equatable {
        /// Nothing answers.
        case unbound
        /// Something accepts a TCP connection — which proves NOTHING about
        /// identity or readiness (port liveness never elects; Kong).
        case answering
    }

    /// The one honest status line for the daemon provider (P-c2-10).
    ///
    /// Registration, PID, or an answering port is NEVER reported as a
    /// running/ready server. Readiness comes exclusively from the provider's
    /// OWN authenticated report (`providerReportedState`, the arbiter wire
    /// encoding the signed provider printed) — passed through VERBATIM so
    /// this surface owns no second copy of the arbiter vocabulary
    /// ("parallel copies fail").
    public static func honestServerStatus(
        registration: DaemonRegistrationObservation,
        port: DaemonPortObservation,
        providerReportedState: String?
    ) -> String {
        if let state = providerReportedState {
            return "provider: \(state)"
        }
        switch (registration, port) {
        case (.registered, .answering):
            return "registered; port answering (unverified — not proof of readiness)"
        case (.registered, .unbound):
            return "registered (not started)"
        case (.none, .answering):
            return "unverified port holder (not proof of readiness)"
        case (.none, .unbound):
            return "not installed"
        }
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

    /// Write the DISABLED bundle-form daemon plist and verify it by readback
    /// (P-c2-10: post-install plist readback against the generator's source
    /// of truth). NEVER bootstraps: the daemon bundle registers disabled and
    /// activates only with MACD-3. No launchctl call happens here at all.
    public static func installDaemonBundleDisabled(homeDirectory: URL) -> Status {
        let fm = FileManager.default
        let plistURL = DaemonBundle.launchAgentPlistURL(homeDirectory: homeDirectory)
        let expected = makeDaemonBundlePlist(homeDirectory: homeDirectory)
        do {
            try fm.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try expected.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            return .launchctlFailed("could not write daemon bundle plist: \(error)")
        }
        // Readback validation: the on-disk bytes must BE the generator's.
        // A mismatch (partial write, interference, wrong file) is reported,
        // never ignored — a plist that says something else is a different
        // registration than the one we claim to have made.
        guard let onDisk = try? String(contentsOf: plistURL, encoding: .utf8),
              onDisk == expected else {
            return .launchctlFailed("daemon bundle plist readback mismatch at \(plistURL.path)")
        }
        return .installedDisabled(plistPath: plistURL.path)
    }

    /// Write, read back, bootstrap, and start the production daemon-provider
    /// bundle. The write-only helper remains separately testable; this method
    /// is the physical installation boundary used by the shipping CLI.
    public static func activateDaemonBundleEnabled(homeDirectory: URL) -> Status {
        activateDaemonBundleEnabled(
            homeDirectory: homeDirectory,
            bootstrap: { plistURL, label in
                bootstrapJob(plistURL: plistURL, label: label)
            }
        )
    }

    /// Injectable form used to prove the shipping activation path without
    /// mutating the caller's live launchd domain in unit tests.
    static func activateDaemonBundleEnabled(
        homeDirectory: URL,
        bootstrap: (URL, String) -> (ok: Bool, detail: String)
    ) -> Status {
        let executableURL = DaemonBundle.bundleExecutableURL(homeDirectory: homeDirectory)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .binaryNotFound
        }
        switch installDaemonBundleEnabled(homeDirectory: homeDirectory) {
        case let .installed(plistPath, dashboardURL):
            let plistURL = URL(fileURLWithPath: plistPath)
            let result = bootstrap(plistURL, DaemonBundle.launchAgentLabel)
            guard result.ok else { return .launchctlFailed(result.detail) }
            return .installed(plistPath: plistPath, dashboardURL: dashboardURL)
        case let .launchctlFailed(message):
            return .launchctlFailed(message)
        case .binaryNotFound:
            return .binaryNotFound
        case .installedDisabled:
            return .launchctlFailed("enabled daemon bundle installation returned disabled status")
        }
    }

    /// bootout → bootstrap (legacy load fallback) for a written plist. Shared
    /// by `install` and `installDaemon` so both agents load identically.
    ///
    /// Every plist passed here is `RunAtLoad=true`, so a successful bootstrap
    /// starts the job. Do not follow bootstrap with `kickstart -k`: that kills
    /// the just-started process and creates a second activation. For the
    /// Community provider, each activation durably advances its generations;
    /// the redundant kickstart therefore made one package upgrade advance the
    /// provider and descriptor counters twice.
    private static func bootstrapJob(plistURL: URL, label: String) -> (ok: Bool, detail: String) {
        bootstrapJob(plistURL: plistURL, label: label, runner: runLaunchctl)
    }

    /// Injectable command runner used by the focused launchd sequencing test.
    /// Production always enters through the private wrapper above.
    static func bootstrapJob(
        plistURL: URL,
        label: String,
        runner: ([String]) -> (code: Int32, output: String)
    ) -> (ok: Bool, detail: String) {
        let domain = "gui/\(getuid())"
        let target = "\(domain)/\(label)"
        // Tear down any prior instance so bootstrap doesn't fail "already loaded".
        _ = runner(["bootout", target])
        // bootout is ASYNCHRONOUS — and worse than a failed bootstrap: a
        // bootout completing late can tear down the freshly bootstrapped
        // replacement job (observed live: install verified the job loaded,
        // and moments later launchd had nothing). Wait until launchd actually
        // reports the job gone before bootstrapping the new one.
        var teardownDone = false
        for _ in 1...20 {
            if runner(["print", target]).code != 0 {
                teardownDone = true
                break
            }
            usleep(250_000)  // 250 ms; up to 5 s for the teardown to finish
        }
        // (#88) If the old job persists after 5 s, try one more forced bootout.
        // Without this, bootstrap fails on "already loaded" and the verify
        // step sees the STALE job, falsely reporting success.
        if !teardownDone {
            _ = runner(["bootout", target])
            usleep(500_000)
            teardownDone = runner(["print", target]).code != 0
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
            let boot = runner(["bootstrap", domain, plistURL.path])
            if boot.code == 0 {
                loaded = true
            } else {
                let legacy = runner(["load", "-w", plistURL.path])
                if legacy.code == 0 {
                    loaded = true
                } else {
                    lastDetail = (boot.output.isEmpty ? legacy.output : boot.output)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            // Verify: bootstrap/load succeeded AND launchd sees the job.
            if loaded, runner(["print", target]).code == 0 {
                // RunAtLoad already started the job. A second explicit start is
                // destructive for activation-counted services.
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

    /// True when launchd currently has the resident daemon job registered.
    /// `launchctl print` on the service target exits 0 only for a loaded job.
    public static func isDaemonRunning() -> Bool {
        runLaunchctl(["print", "gui/\(getuid())/\(MootPaths.daemonLabel)"]).code == 0
    }

    /// Stop the resident daemon WITHOUT removing its plist, so a later
    /// `startDaemon`/`restart` can bring it back from the same registration.
    ///
    /// Exists for the estate encryption migration (CE-1.0.35-08): the swap
    /// must run stop → rename → start, which `restart()` (bootout+bootstrap
    /// in one call) cannot express, and `uninstallDaemon` would delete the
    /// plist the restart needs. Waits up to 60 s for the launchd teardown to
    /// complete — a rename under a still-live daemon is the exact data race
    /// this method exists to prevent.
    ///
    /// - Returns: `true` once the job is no longer registered.
    public static func stopDaemon() -> Bool {
        let target = "gui/\(getuid())/\(MootPaths.daemonLabel)"
        _ = runLaunchctl(["bootout", target])
        // Allow up to 60 s for the daemon to drain active MCP clients and exit.
        // 5 s was insufficient when clients were attached at upgrade time.
        for _ in 0..<120 {
            if runLaunchctl(["print", target]).code != 0 { return true }
            usleep(500_000)
        }
        return false
    }

    /// Start the resident daemon from its existing plist. Counterpart of
    /// `stopDaemon()`; a no-op success when no daemon plist is installed
    /// (nothing was running before, nothing needs to come back).
    public static func startDaemon(homeDirectory: URL) -> Bool {
        let plistURL = MootPaths.daemonPlistURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return true }
        return bootstrapJob(plistURL: plistURL, label: MootPaths.daemonLabel).ok
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

    /// Stop and remove the bundle-form Community daemon registration. The
    /// bundle itself is removed later with the placed binary tree; estate and
    /// Keychain data are deliberately untouched.
    public static func uninstallDaemonBundle(homeDirectory: URL) {
        let fm = FileManager.default
        let plistURL = DaemonBundle.launchAgentPlistURL(homeDirectory: homeDirectory)
        let target = "gui/\(getuid())/\(DaemonBundle.launchAgentLabel)"

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
