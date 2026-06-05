// MootMain.swift
//
// Entry point for the `mootx01` unified CLI binary.
//
// Default subcommand: when stdin is a pipe (non-interactive) and no
// explicit subcommand is given, `mootx01` behaves as `mootx01 serve`.
// This preserves compatibility with existing MCP client configs that
// specify `"command": "mootx01"` without a subcommand.
//
// On macOS: full subcommand surface including `serve`.
// On Linux: install, uninstall, db, status, query (serve requires macOS).

import ArgumentParser

@main
struct Mootx01: AsyncParsableCommand {
    static var configuration: CommandConfiguration {
        #if os(macOS)
        return CommandConfiguration(
            commandName: "mootx01",
            abstract: "ARIA MCP server and estate management tool.",
            discussion: """
            Run `mootx01 serve` (or just `mootx01` when stdin is a pipe) to start
            the ARIA MCP server. Use `mootx01 install` to wire it into your MCP clients.
            """,
            subcommands: [
                ServeCommand.self,
                InstallCommand.self,
                UninstallCommand.self,
                DbCommand.self,
                StatusCommand.self,
                QueryCommand.self,
            ],
            // Default to serve so `"command": "mootx01"` in client configs works.
            defaultSubcommand: ServeCommand.self
        )
        #else
        return CommandConfiguration(
            commandName: "mootx01",
            abstract: "ARIA MCP estate management tool (Linux: serve requires macOS).",
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
