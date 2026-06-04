// Paths.swift
//
// Resolves the user data directory that mootx01-mcp opens. Pure
// path math — no filesystem touching — so the logic is unit-testable
// without spawning a process or writing under the user's home.
//
// macOS-only per LAUNCH_PLAN.md §"The Monday cut". The single
// supported location is the standard Application Support directory:
//   ~/Library/Application Support/MOOTx01/
// The estate database lives at:
//   ~/Library/Application Support/MOOTx01/estate.sqlite
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
            .appendingPathComponent("MOOTx01", isDirectory: true)
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
    /// - Parameter workingDirectory: the directory in which install.sh
    ///   was invoked (i.e. `$PWD` at install time). Inject in tests;
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
}
