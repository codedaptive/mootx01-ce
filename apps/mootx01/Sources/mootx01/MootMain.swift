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
// argv0 dispatch (Wave 6 addendum): invoked as `mootx01-proxy` (argv[0]'s
// last path component — typically via a symlink to the same binary) with
// no explicit subcommand, `mootx01` behaves as `mootx01 proxy`. This lets
// an MCP client whose config schema can only express a bare `command`
// string (no `args` array) reach ProxyCommand without an args array —
// see ArgvDispatch.swift (MootInstallerCore) for the full rationale.
// Proxy symlink placement (wave 7.6): `Installer.placeBinary()` writes a
// relative symlink `mootx01-proxy → mootx01` in the same directory as the
// installed binary. MCP client configs that specify `"command": "mootx01-proxy"`
// invoke the proxy subcommand via argv0 dispatch above. Uninstall removes
// the symlink. No separate PATH entry is needed — same-dir placement means
// both names are equally reachable via the single PATH-visible directory.
//
// On macOS: full subcommand surface including `serve`/`proxy`.
// On Linux: install, uninstall, db, status, query (serve/proxy require macOS).

import ArgumentParser
import Foundation
import MootInstallerCore

@main
enum MootEntry {
    static func main() async {
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        var args = rawArgs
        #if os(macOS)
        // Both defaults (argv0 → proxy, bare-pipe → serve) are resolved by
        // one tested decision point — see ArgvDispatch.resolvedArguments's
        // doc comment for the exact precedence. Neither fires when an
        // explicit subcommand (or --help/--version) was already given.
        args = ArgvDispatch.resolvedArguments(
            argv0: CommandLine.arguments.first ?? "mootx01",
            rawArgs: rawArgs,
            stdinIsPipe: isatty(FileHandle.standardInput.fileDescriptor) == 0
        )
        #endif
        await Mootx01.main(args)
    }
}

struct Mootx01: AsyncParsableCommand {

    /// SemVer for the installed binary. Development builds carry the beta
    /// pre-release component; stable builds use a bare numeric version.
    /// The human-facing --version string adds the date via `versionDisplay`.
    static let currentVersion = "1.1.0-beta-10"

    /// Release date stamp shown alongside the version by --version.
    static let releaseDate = "2026-07-30"

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
                // — out-of-band sensitivity unlock / lock.
                UnlockCommand.self,
                LockCommand.self,
                // Feature toggles (M-MEMTOOL-1).
                EnableCommand.self,
                DisableCommand.self,
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
                EnableCommand.self,
                DisableCommand.self,
            ]
        )
        #endif
    }
}
