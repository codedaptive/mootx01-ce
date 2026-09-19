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
// BL-1 adds the `mootx01-botLink` argv0 route: it PREPENDS `botlink`, so
// `mootx01-botLink ping` reaches `botlink ping` — the cloud agent's
// one-shot data path (see BotLinkCommand.swift).
// Symlink placement (wave 7.6, BL-1): `Installer.placeBinary()` writes
// relative symlinks `mootx01-proxy → mootx01` and `mootx01-botLink →
// mootx01` in the same directory as the installed binary. MCP client
// configs that specify `"command": "mootx01-proxy"` invoke the proxy
// subcommand via argv0 dispatch above; cloud agents exec `mootx01-botLink`.
// Uninstall removes both when it removes the install root. No separate
// PATH entry is needed — same-dir placement means all names are equally
// reachable via the single PATH-visible directory.
//
// On macOS: full subcommand surface including `serve`/`proxy`.
// On Linux: install, uninstall, db, preference, status, query (serve/proxy require macOS).

import ArgumentParser
import AriaMCP
import Foundation
import GeniusLocusKit
import MootCoreAIWorker
import MootInstallerCore
import MootProductIdentity
import NeuronKit

@main
enum MootEntry {
    static func main() async {
        // NeuronKit logs under whatever subsystem its host names, and this is
        // the host: one subsystem for the whole product, so one Console
        // filter still shows everything. Set before any NeuronKit work, since
        // its loggers bind on first use.
        NeuronKitLogging.subsystem = MootProductIdentity.Logging.subsystem
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
    static let currentVersion = "1.1.3"

    /// Release date stamp shown alongside the version by --version.
    static let releaseDate = "2026-09-19"

    /// The unchanged first line printed by --version. The Rust port must print
    /// this identical line before its converter identity lines.
    static let versionDisplay = "\(currentVersion) (\(releaseDate))"

    /// The complete --version text. Converter identities come from the product
    /// paths that use them, rather than duplicating ContextDistillLib literals.
    static var versionOutput: String {
        let hydration = GeniusLocusKit.distillationConverter
        let recall = RecallDistillation.converter
        return """
        \(versionDisplay)
        converter hydration \(hydration.id) \(hydration.converterVersion)
        converter recall \(recall.id) \(recall.converterVersion)
        """
    }

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
            version: versionOutput,
            subcommands: [
                CoreAINuExtractWorkerCommand.self,
                ServeCommand.self,
                ProxyCommand.self,
                DrainCommand.self,
                DreamCommand.self,
                InstallCommand.self,
                UpgradeCommand.self,
                UninstallCommand.self,
                DbCommand.self,
                PreferenceCommand.self,
                StatusCommand.self,
                QueryCommand.self,
                // BL-1: one-shot MCP transport for cloud agents (also the
                // mootx01-botLink argv0 symlink target).
                BotLinkCommand.self,
                // — out-of-band sensitivity unlock / lock.
                UnlockCommand.self,
                LockCommand.self,
                // Feature toggles (M-MEMTOOL-1).
                EnableCommand.self,
                DisableCommand.self,
                CodexMemoryCommand.self,
                CodexHookCommand.self,
                // Harness Memory Mode hook handler (MXE-HM). Not shown in --help;
                // invoked by ~/.mootx01/hooks/capture-harness-memory.sh.
                HookCaptureCommand.self,
            ]
        )
        #else
        return CommandConfiguration(
            commandName: "mootx01",
            abstract: "ARIA MCP estate management tool (Linux: serve requires macOS).",
            version: versionOutput,
            subcommands: [
                InstallCommand.self,
                UninstallCommand.self,
                DbCommand.self,
                PreferenceCommand.self,
                StatusCommand.self,
                QueryCommand.self,
                // BL-1: one-shot MCP transport for cloud agents. Registered
                // like QueryCommand on both platforms — the HTTP path is
                // Foundation-only, and the subprocess path shares query's
                // serve-availability caveat on Linux.
                BotLinkCommand.self,
                EnableCommand.self,
                DisableCommand.self,
                CodexMemoryCommand.self,
                CodexHookCommand.self,
                // Harness Memory Mode hook handler (MXE-HM). Not shown in --help;
                // invoked by ~/.mootx01/hooks/capture-harness-memory.sh.
                HookCaptureCommand.self,
            ]
        )
        #endif
    }
}
