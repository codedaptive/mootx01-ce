// MootMain.swift
//
// Entry point for the `mootx01` unified CLI binary.
//
// Default subcommand: when stdin is a pipe (non-interactive) and no
// explicit subcommand is given, `mootx01` behaves as `mootx01 serve`.
// This preserves compatibility with existing MCP client configs that
// specify `"command": "mootx01"` without a subcommand. In a terminal
// (stdin is a TTY), no subcommand is injected, so `mootx01 --help` and a
// bare `mootx01` print standard CLI usage instead of starting the server.
//
// On macOS: full subcommand surface including `serve`.
// On Linux: install, uninstall, db, status, query (serve requires macOS).

import ArgumentParser
import Foundation

@main
enum MootEntry {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        #if os(macOS)
        // Back-compat for MCP clients that launch us as `"command": "mootx01"`
        // with no subcommand: when there are no args AND stdin is a pipe,
        // default to `serve`. A bare invocation in a terminal (TTY) falls
        // through so ArgumentParser prints usage — and `--help`/explicit
        // subcommands always pass through untouched.
        if args.isEmpty, isatty(FileHandle.standardInput.fileDescriptor) == 0 {
            args = ["serve"]
        }
        #endif
        await Mootx01.main(args)
    }
}

struct Mootx01: AsyncParsableCommand {

    /// Bare semver for the installed binary. Compared numerically by --check /
    /// upgrade against the latest release tag, so it must stay a pure semver.
    /// The human-facing --version string adds the date via `versionDisplay`.
    static let currentVersion = "1.0.12"

    /// Release date stamp shown alongside the version by --version.
    static let releaseDate = "2026-07-03"

    /// The exact string --version prints. The Rust port must print an identical
    /// string (see apps/mootx01/rust: CURRENT_VERSION + RELEASE_DATE).
    static let versionDisplay = "\(currentVersion) (\(releaseDate))"

    static var configuration: CommandConfiguration {
        #if os(macOS)
        return CommandConfiguration(
            commandName: "mootx01",
            abstract: "ARIA MCP server and estate management tool.",
            discussion: """
            Run `mootx01 serve` (or just `mootx01` when stdin is a pipe) to start
            the ARIA MCP server. Use `mootx01 install` to wire it into your MCP clients.
            Use `mootx01 upgrade` to replace the binary from a local build and
            restart background services.
            """,
            version: versionDisplay,
            subcommands: [
                ServeCommand.self,
                ProxyCommand.self,
                DrainCommand.self,
                DreamCommand.self,
                InstallCommand.self,
                UpgradeCommand.self,
                UninstallCommand.self,
                DbCommand.self,
                StatusCommand.self,
                QueryCommand.self,
            ]
        )
        #else
        return CommandConfiguration(
            commandName: "mootx01",
            abstract: "ARIA MCP estate management tool (Linux: serve requires macOS).",
            version: versionDisplay,
            subcommands: [
                InstallCommand.self,
                UninstallCommand.self,
                DbCommand.self,
                StatusCommand.self,
                QueryCommand.self,
            ]
        )
        #endif
    }
}
