// InstallCommand.swift
//
// Wire mootx01 into one or more MCP clients and grant ARIA tool permissions.
// Mirrors the install surface of popular MCP server CLIs (e.g. @modelcontextprotocol).

import ArgumentParser
import Foundation
import MootInstallerCore

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Wire mootx01 into MCP clients and grant tool permissions."
    )

    @Option(name: .long, help: "Comma-separated client ids to install (e.g. claude,cursor). Default: interactive picker.")
    var target: String?

    @Option(name: .long, help: "Config scope: 'global' (default) or 'local' (project .mcp.json for Claude Code).")
    var location: String = "global"

    @Flag(name: .shortAndLong, help: "Skip prompts; auto-detect and install all present clients.")
    var yes: Bool = false

    @Flag(name: .long, help: "Skip writing to settings.json (do not grant tool permissions).")
    var noPermissions: Bool = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let local = location == "local"

        // Resolve the SOURCE binary (the running executable). We never
        // write this path into a client config — instead we copy it to a
        // stable install location and write THAT path. `Bundle.main.executablePath`
        // is the resolved absolute path of the running executable; the
        // fallback resolves argv[0] against the current directory.
        let sourcePath = Bundle.main.executablePath
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "/usr/local/bin/mootx01")
                .standardizedFileURL.path

        let clients = try AgentPicker.pick(yes: yes, target: target, homeDirectory: home)
        guard !clients.isEmpty else {
            print("No clients selected. Run `mootx01 install --target <id>` to install a specific client.")
            return
        }

        // Place the binary FIRST and use its installed absolute path as the
        // config `command`. This is the core fix: configs point at
        // ~/.mootx01/bin/mootx01 (a stable location), never at the CWD or
        // dev-tree path the binary happened to run from.
        let binaryPath: String
        do {
            binaryPath = try Installer.placeBinary(sourcePath: sourcePath, homeDirectory: home)
            print("Placed binary at \(binaryPath)")
            print("Linked   \(MootPaths.binarySymlinkURL(homeDirectory: home).path)")
        } catch {
            print("Could not place binary: \(error)")
            throw error
        }

        print("\nInstalling mootx01 into \(clients.count) client(s)...")

        var installed: [String] = []
        var skipped: [String] = []

        for client in clients {
            do {
                try Installer.install(
                    client: client,
                    binaryPath: binaryPath,
                    homeDirectory: home,
                    workingDirectory: cwd,
                    local: local
                )
                installed.append(client.displayName)
            } catch {
                print("  ✗ \(client.displayName): \(error)")
                skipped.append(client.displayName)
            }
        }

        // Write tool permissions into Claude Code settings.json.
        if !noPermissions {
            let settingsURL = local
                ? MootPaths.localClaudeSettingsURL(workingDirectory: cwd)
                : MootPaths.globalClaudeSettingsURL(homeDirectory: home)
            do {
                try PermissionsWriter.merge(into: settingsURL)
                print("  ✓ Granted \(PermissionsWriter.permissionEntries.count) ARIA tool permissions in \(settingsURL.path)")
            } catch {
                print("  ✗ Could not write permissions: \(error)")
            }
        }

        // Write MOOT.md instructions file for Claude Code.
        do {
            try Installer.writeMOOTmd(homeDirectory: home, local: local, workingDirectory: cwd)
        } catch {
            // Non-fatal: MOOT.md is advisory.
        }

        print("")
        if !installed.isEmpty {
            print("Installed: \(installed.joined(separator: ", "))")
        }
        if !skipped.isEmpty {
            print("Skipped (errors): \(skipped.joined(separator: ", "))")
        }
        // If ~/.local/bin is not on PATH, the symlink won't resolve as a
        // bare `mootx01` command — print the same kind of note codegraph
        // does. (MCP clients use the absolute config path regardless, so
        // this only affects running `mootx01` by name in a shell.)
        let localBinDir = MootPaths.localBinDirURL(homeDirectory: home).path
        let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let onPath = pathEnv.split(separator: ":").contains { String($0) == localBinDir }
        if !onPath {
            print("")
            print("\(localBinDir) is not on your PATH. Add it:")
            print("  export PATH=\"\(localBinDir):$PATH\"")
        }

        print("")
        print("Run `mootx01 status` to confirm your setup.")
    }
}
