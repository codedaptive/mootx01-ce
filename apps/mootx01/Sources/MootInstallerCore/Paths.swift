// Paths.swift
//
// Resolves the user data directory that mootx01 opens. Pure
// path math — no filesystem touching — so the logic is unit-testable
// without spawning a process or writing under the user's home.
//
// macOS-only per LAUNCH_PLAN.md §"The Monday cut". The single
// supported location is the standard Application Support directory:
//   ~/Library/Application Support/com.mootx01.ce/
// The estate database lives at:
//   ~/Library/Application Support/com.mootx01.ce/estate.sqlite
//
// MOOTX01_DATA_DIR overrides the resolved directory when set and
// non-empty. The override exists for the installer's bash smoke
// test (Installer/tests/test_install_sh.sh) and for any developer
// who wants to point a separate MOOT at a sandboxed path; it is not
// documented for end users.

import Foundation

public enum MootPaths {

    /// Environment variable name read in `resolveDataDirectory`.
    /// Kept public so the bash smoke test and any future tooling
    /// can refer to one canonical symbol rather than a literal.
    public static let dataDirEnvVar: String = "MOOTX01_DATA_DIR"

    /// File name of the persistent estate database inside the data
    /// directory. SQLite + sqlite-vec WAL files (`-wal`, `-shm`) are
    /// created alongside by the SQLite backend.
    public static let estateFileName: String = "estate.sqlite"

    /// Default user-visible owner identifier stamped into the
    /// manifest at first-run. Surfaces in audit rows; the substrate
    /// only requires it be non-empty (LocusKit.Estate.create).
    public static let defaultOwnerIdentifier: String = "mootx01-user"

    /// Resolve the data directory for this user. Reads
    /// `MOOTX01_DATA_DIR` from `environment` when set and non-empty;
    /// otherwise returns the macOS Application Support path under
    /// the supplied `homeDirectory`.
    ///
    /// - Parameters:
    ///   - environment: process environment dictionary. Inject in
    ///     tests; pass `ProcessInfo.processInfo.environment` in the
    ///     executable.
    ///   - homeDirectory: the user's home directory. Inject in tests;
    ///     pass `FileManager.default.homeDirectoryForCurrentUser` in
    ///     the executable.
    /// - Returns: the resolved data directory URL. Does not touch
    ///   the filesystem.
    public static func resolveDataDirectory(
        environment: [String: String],
        homeDirectory: URL
    ) -> URL {
        if let override = environment[dataDirEnvVar], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("com.mootx01.ce", isDirectory: true)
    }

    /// Estate database URL inside `dataDirectory`. Pure path
    /// concatenation; the SQLite backend creates the file on first
    /// open (PersistenceKitSQLite.SQLiteConnection makes parent dirs).
    public static func estateURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(estateFileName, isDirectory: false)
    }

    /// URL of the Claude Code project-local MCP config file.
    ///
    /// Claude Code reads `.mcp.json` from the project root when a
    /// server is wired with `claude mcp add --local`. The installer
    /// writes to this path when `--local` is passed, scoping the MOOT
    /// server entry to the current project rather than the global
    /// `~/.claude.json`.
    ///
    /// - Parameter workingDirectory: the current working directory at install
    ///   time (i.e. `$PWD` when `mootx01 install` is run). Inject in tests;
    ///   pass `URL(fileURLWithPath: FileManager.default.currentDirectoryPath)`
    ///   in the executable.
    /// - Returns: `workingDirectory/.mcp.json`. Does not touch the filesystem.
    public static func localMCPConfigURL(workingDirectory: URL) -> URL {
        workingDirectory.appendingPathComponent(".mcp.json", isDirectory: false)
    }

    /// URL of the global Claude Code settings file.
    ///
    /// Claude Code persists per-tool approval state in
    /// `~/.claude/settings.json` under the `permissions.allow` key.
    /// The installer merges ARIA tool names into this file so users
    /// do not see per-tool approval prompts after a fresh install.
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in
    ///   tests; pass `FileManager.default.homeDirectoryForCurrentUser`
    ///   in the executable.
    /// - Returns: `homeDirectory/.claude/settings.json`. Does not touch
    ///   the filesystem.
    public static func globalClaudeSettingsURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// Directory under the user's home where the `mootx01` binary is
    /// placed on `mootx01 install`. Mirrors codegraph's `~/.codegraph`
    /// versioned install root; for mootx01 the binary lives directly at
    /// `<home>/.mootx01/bin/mootx01` (single self-contained executable —
    /// no vendored runtime to version, so the simpler flat layout is used
    /// instead of codegraph's `versions/<tag>` + `current` symlink).
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in
    ///   tests; pass `FileManager.default.homeDirectoryForCurrentUser`.
    /// - Returns: `<home>/.mootx01/bin`. Does not touch the filesystem.
    public static func installedBinaryDirURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".mootx01", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    /// Absolute path of the placed `mootx01` binary inside the install
    /// directory. This is the path the installer writes into every MCP
    /// client's `mcpServers.<name>.command` so the entry never points at
    /// a CWD or dev-tree location.
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in
    ///   tests; pass `FileManager.default.homeDirectoryForCurrentUser`.
    /// - Returns: `<home>/.mootx01/bin/mootx01`. Does not touch the filesystem.
    public static func installedBinaryURL(homeDirectory: URL) -> URL {
        installedBinaryDirURL(homeDirectory: homeDirectory)
            .appendingPathComponent("mootx01", isDirectory: false)
    }

    /// Directory where the PATH launcher symlink is created. Mirrors
    /// codegraph's `~/.local/bin` default — the XDG-conventional location
    /// for user-installed executables.
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in
    ///   tests; pass `FileManager.default.homeDirectoryForCurrentUser`.
    /// - Returns: `<home>/.local/bin`. Does not touch the filesystem.
    public static func localBinDirURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }

    /// Absolute path of the PATH launcher symlink. Points at
    /// `installedBinaryURL`. Putting this on `$PATH` makes `mootx01`
    /// resolvable from any shell.
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in
    ///   tests; pass `FileManager.default.homeDirectoryForCurrentUser`.
    /// - Returns: `<home>/.local/bin/mootx01`. Does not touch the filesystem.
    public static func binarySymlinkURL(homeDirectory: URL) -> URL {
        localBinDirURL(homeDirectory: homeDirectory)
            .appendingPathComponent("mootx01", isDirectory: false)
    }

    /// Absolute path of the same-directory proxy symlink. The symlink sits
    /// beside the placed binary in `~/.mootx01/bin/` so that `Bundle.main`
    /// resource resolution works identically whether the process was launched
    /// as `mootx01` or `mootx01-proxy` (both resolve to the same install
    /// directory). Clients whose config schema cannot express a bare
    /// `command` + separate `args` array use this entry as the bare command
    /// — the argv0 name `mootx01-proxy` triggers `ArgvDispatch` to invoke
    /// the `proxy` subcommand automatically.
    ///
    /// Same-directory placement is load-bearing: `Bundle.main.bundleURL`
    /// resolves relative to the executable path, so the symlink MUST live
    /// next to the binary (not in `~/.local/bin/`).
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in
    ///   tests; pass `FileManager.default.homeDirectoryForCurrentUser`.
    /// - Returns: `<home>/.mootx01/bin/mootx01-proxy`. Does not touch
    ///   the filesystem.
    public static func proxySymlinkURL(homeDirectory: URL) -> URL {
        installedBinaryDirURL(homeDirectory: homeDirectory)
            .appendingPathComponent("mootx01-proxy", isDirectory: false)
    }

    /// Absolute path of the same-directory botLink symlink (BL-1). Sits
    /// beside the placed binary in `~/.mootx01/bin/` for the same
    /// `Bundle.main` reasons as the proxy symlink above. Cloud agents exec
    /// `mootx01-botLink <subcommand>` by this name; the argv0 name triggers
    /// `ArgvDispatch` to prepend the `botlink` subcommand automatically.
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in
    ///   tests; pass `FileManager.default.homeDirectoryForCurrentUser`.
    /// - Returns: `<home>/.mootx01/bin/mootx01-botLink` (capital L — must
    ///   match `ArgvDispatch.botLinkInvocationName`). Does not touch the
    ///   filesystem.
    public static func botLinkSymlinkURL(homeDirectory: URL) -> URL {
        installedBinaryDirURL(homeDirectory: homeDirectory)
            .appendingPathComponent("mootx01-botLink", isDirectory: false)
    }

    /// URL of the project-local Claude Code settings file.
    ///
    /// When `--local` is used during install, Claude Code is wired to
    /// `.mcp.json` in the project root. The corresponding per-project
    /// settings file that receives ARIA tool approvals lives at
    /// `.claude/settings.json` in the same working directory.
    ///
    /// - Parameter workingDirectory: the directory in which install.sh
    ///   was invoked (i.e. `$PWD` at install time). Inject in tests;
    ///   pass `URL(fileURLWithPath: FileManager.default.currentDirectoryPath)`.
    /// - Returns: `workingDirectory/.claude/settings.json`. Does not
    ///   touch the filesystem.
    public static func localClaudeSettingsURL(workingDirectory: URL) -> URL {
        workingDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    // MARK: - moot-mgr management console (launchd LaunchAgent)

    /// Absolute path of the placed `moot-mgr` binary (the management &
    /// monitoring console). Sits beside `mootx01` in the install directory;
    /// the launchd LaunchAgent's `ProgramArguments` point at this stable path
    /// so the service survives moving or rebuilding the source tree.
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in tests.
    /// - Returns: `<home>/.mootx01/bin/moot-mgr`. Does not touch the filesystem.
    public static func installedMgrBinaryURL(homeDirectory: URL) -> URL {
        installedBinaryDirURL(homeDirectory: homeDirectory)
            .appendingPathComponent("moot-mgr", isDirectory: false)
    }

    /// PATH launcher symlink for `moot-mgr`, so `moot-mgr` resolves from any
    /// shell the same way `mootx01` does.
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in tests.
    /// - Returns: `<home>/.local/bin/moot-mgr`. Does not touch the filesystem.
    public static func mgrSymlinkURL(homeDirectory: URL) -> URL {
        localBinDirURL(homeDirectory: homeDirectory)
            .appendingPathComponent("moot-mgr", isDirectory: false)
    }

    /// Directory for the moot-mgr LaunchAgent's stdout/stderr log files.
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in tests.
    /// - Returns: `<home>/.mootx01/logs`. Does not touch the filesystem.
    public static func logsDirURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".mootx01", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    /// launchd job label for the moot-mgr resident-host LaunchAgent. Used as
    /// the plist `Label`, the plist filename stem, and the `launchctl`
    /// bootstrap/bootout target (`gui/<uid>/<label>`).
    public static let launchAgentLabel: String = "com.mootx01.mgr"

    /// Path of the moot-mgr LaunchAgent property list. Per-user LaunchAgents
    /// live under `~/Library/LaunchAgents`; launchd loads them into the user's
    /// GUI domain at login.
    ///
    /// - Parameter homeDirectory: the user's home directory. Inject in tests.
    /// - Returns: `<home>/Library/LaunchAgents/com.mootx01.mgr.plist`. Does
    ///   not touch the filesystem.
    public static func launchAgentPlistURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
    }

    /// launchd job label for the resident mootx01 daemon (the headless HTTP MCP
    /// server + autonomic governor). Distinct from the moot-mgr agent so the two services
    /// load independently.
    public static let daemonLabel: String = "com.mootx01.daemon"

    /// Path of the resident mootx01 daemon LaunchAgent property list.
    ///
    /// - Returns: `<home>/Library/LaunchAgents/com.mootx01.daemon.plist`. Does
    ///   not touch the filesystem.
    public static func daemonPlistURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(daemonLabel).plist", isDirectory: false)
    }

    /// The moot-mgr stats-store path the resident daemon self-reports to
    /// (`ARIA_MCP_STATS_STORE`). Mirrors moot-mgr's `ManagerConfig` default —
    /// `<data-dir>/moot-mgr/stats.sqlite` — so the daemon writes exactly where
    /// moot-mgr reads.
    ///
    /// - Parameter dataDir: the resolved app-support data dir (`com.mootx01.ce`).
    public static func daemonStatsStorePath(dataDir: URL) -> String {
        dataDir
            .appendingPathComponent("moot-mgr", isDirectory: true)
            .appendingPathComponent("stats.sqlite", isDirectory: false)
            .path
    }

    /// The resident daemon's loopback HTTP port — the single source of truth for
    /// both the daemon plist's `MOOTX01_HTTP_PORT` and the URL MCP clients are
    /// wired to over HTTP. moot-mgr's dashboard owns 4200; the daemon
    /// owns this.
    public static let defaultResidentPort: Int = 4242

    /// The resident daemon's MCP endpoint URL that HTTP-capable clients are wired
    /// to (so they share the one running daemon + its autonomic governor, rather than
    /// spawning their own stdio instance). The server accepts POST at any path.
    public static var residentEndpointURL: String {
        "http://127.0.0.1:\(defaultResidentPort)"
    }

    /// Path of the daemon's port file (`<dataDir>/daemon.port`). When the
    /// resident daemon starts with `--http`, it writes its bound port here so
    /// clients (query, proxy) can resolve the live port without hard-coding the
    /// default. Mirrors `paths::daemon_port_file` in the Rust vertical.
    ///
    /// - Parameter dataDir: the resolved app-support data directory.
    /// - Returns: the port-file URL. Does not touch the filesystem.
    public static func daemonPortFileURL(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent("daemon.port", isDirectory: false)
    }

    /// Resolve the resident daemon's actual port: reads `daemon.port` when
    /// present and valid, otherwise falls back to `defaultResidentPort` (4242).
    /// Mirrors `daemon_client::resolved_port()` in the Rust vertical.
    ///
    /// - Parameter dataDir: the resolved app-support data directory.
    /// - Returns: the TCP port the daemon is expected to be listening on.
    public static func resolvedResidentPort(dataDir: URL) -> Int {
        let portFileURL = daemonPortFileURL(in: dataDir)
        if let portString = try? String(contentsOf: portFileURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
           let port = Int(portString), port > 0, port < 65536 {
            return port
        }
        return defaultResidentPort
    }
}

// MARK: - MACD-2c2 — the signed app-like daemon bundle (KONG-4)
//
// The SINGLE constant surface for the daemon-bundle artifact. Every spelling
// of the bundle's name, executable, label, plist location, and LaunchAgent
// ProgramArguments comes from here; the Makefile, build-pkg.sh, and
// release.yml text artifacts are verified against these constants by a
// parity test (LaunchAgentTests §Distribution parity), so generated and
// manual sources cannot diverge.

/// Constants and path math for the signed app-like daemon provider bundle
/// (the packaged form of the `mootx01-daemon` thin shell over
/// MootDaemonProvider). Pure path math — no filesystem touching.
public enum DaemonBundle {

    /// The bundle's on-disk name. The pkg payload, the Makefile recipe, and
    /// release.yml all stage exactly this name.
    public static let bundleName = "Mootx01DaemonProvider.app"

    /// The executable inside `Contents/MacOS`.
    public static let executableName = "Mootx01DaemonProvider"

    /// The bundle identifier of the direct-install daemon provider bundle.
    /// Distinct from the SANDBOXED nested helper
    /// (`com.codedaptive.mootx01.macos.daemonproviderhelper` in project.yml)
    /// — same provider module, different packaging and registration channel.
    public static let bundleIdentifier = "com.codedaptive.mootx01.macos.daemonprovider"

    /// The LaunchAgent label for the BUNDLE-form daemon registration.
    /// Deliberately NOT `MootPaths.daemonLabel` (`com.mootx01.daemon`, the
    /// legacy raw-serve plist): the legacy artifact is retained — plist,
    /// label, and running job untouched — until the bundle provider proves
    /// authenticated readiness (MACD-3), so the two registrations coexist
    /// under the arbiter rather than replacing each other blindly.
    public static let launchAgentLabel = "com.codedaptive.mootx01.daemon"

    /// The shell mode the LaunchAgent invokes. Until MACD-3 activates
    /// estate hosting, the mode fail-closes honestly (exit 4) and the plist
    /// installs DISABLED — the arguments are the FINAL contract so upgrade
    /// never has to rewrite the plist when activation lands.
    public static let residentModeArgument = "resident"

    /// The installed bundle location:
    /// `<home>/.mootx01/bin/Mootx01DaemonProvider.app`. It lives inside the
    /// `bin/` payload tree deliberately: the pkg postinstall relocates the
    /// staged `bin/` directory wholesale, so the bundle rides the SAME
    /// validated placement path as the CLI binaries — one relocation
    /// contract, no second placement rule.
    public static func installedBundleURL(homeDirectory: URL) -> URL {
        MootPaths.installedBinaryDirURL(homeDirectory: homeDirectory)
            .appendingPathComponent(bundleName, isDirectory: true)
    }

    /// The bundle's executable: `.../Contents/MacOS/Mootx01DaemonProvider`.
    /// This is the path the LaunchAgent ProgramArguments carry — always
    /// inside the bundle, never a raw binary (mission hard rule).
    public static func bundleExecutableURL(homeDirectory: URL) -> URL {
        installedBundleURL(homeDirectory: homeDirectory)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }

    /// The bundle-form LaunchAgent plist location.
    public static func launchAgentPlistURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(launchAgentLabel).plist", isDirectory: false)
    }

    /// The exact ProgramArguments the bundle plist carries.
    public static func programArguments(homeDirectory: URL) -> [String] {
        [bundleExecutableURL(homeDirectory: homeDirectory).path, residentModeArgument]
    }

    /// Run one READ-ONLY mode of the installed daemon bundle executable and
    /// capture its single-line JSON report. Shared by `install` and `upgrade`
    /// so the two commands cannot drift (and so the drain/wait ordering is
    /// correct in exactly one place).
    ///
    /// stdout AND stderr are drained to EOF BEFORE `waitUntilExit()`: a child
    /// that fills a pipe buffer blocks forever if the parent waits first, and
    /// a census report on a machine with many candidates is not guaranteed to
    /// be small.
    ///
    /// - Parameters:
    ///   - mode: A read-only shell mode (`census`, `self-report`). Never a
    ///     mode with side effects.
    ///   - homeDirectory: The user's home directory.
    /// - Returns: The exit code and the trimmed stdout line (nil when empty).
    public static func runReadOnlyMode(
        _ mode: String, homeDirectory: URL
    ) -> (code: Int32, output: String?) {
        let executable = bundleExecutableURL(homeDirectory: homeDirectory)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return (-1, nil)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [mode]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return (-1, nil)
        }
        // Drain both pipes to EOF first; only then wait for the child.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        _ = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, (text?.isEmpty ?? true) ? nil : text)
    }

    /// Every artifact the daemon-bundle installation OWNS — the only things
    /// uninstall may remove. Estate databases, migration receipts, backups,
    /// key material, and every census candidate are NOT here and are NEVER
    /// touched by uninstall (mission preservation contract; explicit
    /// Delete All Data has its own separate, estate-owned flow and even that
    /// never touches non-owned census candidates).
    public static func ownedArtifactPaths(homeDirectory: URL) -> [String] {
        [
            installedBundleURL(homeDirectory: homeDirectory).path,
            launchAgentPlistURL(homeDirectory: homeDirectory).path,
        ]
    }
}
