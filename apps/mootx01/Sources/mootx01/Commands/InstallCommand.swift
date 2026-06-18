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

    @Flag(name: .long, help: "Skip installing the moot-mgr management console as a background launchd service (macOS).")
    var noManager: Bool = false

    @Flag(name: .long, help: "Skip registering the resident mootx01 daemon (HTTP MCP server + Brain pump) as a background launchd service (macOS).")
    var noDaemon: Bool = false

    @Flag(name: .long, help: "Enable Vault MCP tools (moot_vault_*): expose export/import/status/reconcile/job on the MCP surface. Default behavior when neither --vault-on nor --vault-off is specified.")
    var vaultOn: Bool = false

    @Flag(name: .long, help: "Hide Vault MCP tools (moot_vault_*) from the MCP surface. For a more secure install position that disables import/export. Use --vault-on to re-enable.")
    var vaultOff: Bool = false

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
                    daemonURL: MootPaths.residentEndpointURL,
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

        // Install + launch the moot-mgr management console as a background
        // launchd LaunchAgent. moot-mgr ships beside mootx01 in the macOS
        // release archive, so its source is the sibling of the running binary.
        // macOS-only: launchd is the service manager and moot-mgr is macOS-only.
        #if os(macOS)
        if !noManager {
            let mgrSource = URL(fileURLWithPath: sourcePath)
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent("moot-mgr")
                .path
            do {
                if let mgrPath = try Installer.placeMgrBinary(sourceMgrPath: mgrSource, homeDirectory: home) {
                    switch LaunchAgent.install(mgrBinaryPath: mgrPath, homeDirectory: home) {
                    case let .installed(plistPath, dashboardURL):
                        print("")
                        print("  ✓ Management console running in the background (launchd: \(MootPaths.launchAgentLabel))")
                        print("    Dashboard:   \(dashboardURL)")
                        print("    LaunchAgent: \(plistPath)")
                    case let .launchctlFailed(message):
                        print("")
                        print("  ✗ Could not start the management console via launchd: \(message)")
                        print("    Start it manually any time with:  moot-mgr serve")
                    case .binaryNotFound:
                        // placeMgrBinary returned a path but the file vanished;
                        // treat as "not available" and stay quiet beyond a hint.
                        print("")
                        print("  ⓘ Management console binary missing — run `moot-mgr serve` manually.")
                    }
                } else {
                    print("")
                    print("  ⓘ moot-mgr console not found beside mootx01 — skipping the background")
                    print("    service. Install via the release (install.sh) or build apps/moot-mgr,")
                    print("    then re-run `mootx01 install`.")
                }
            } catch {
                print("  ✗ Could not place moot-mgr: \(error)")
            }
        }
        #endif

        // Register the resident mootx01 daemon (HTTP MCP server + Brain pump +
        // telemetry) as a launchd LaunchAgent so it runs at login and restarts on
        // exit — this is the headless daemon the wired clients connect to over
        // HTTP. The plist env switches `mootx01 serve` into resident mode
        // (MOOTX01_HTTP_PORT=4242) and points telemetry at moot-mgr's stats store
        // so the console observes it out of the box. macOS-only (launchd).
        #if os(macOS)
        if !noDaemon {
            let dataDir = MootPaths.resolveDataDirectory(
                environment: ProcessInfo.processInfo.environment,
                homeDirectory: home
            )
            // MOOTX01_VAULT: "0" = vault-off (--vault-off); "1" = vault-on (default).
            // The flag pair is mutually exclusive by convention: if both are set
            // (CLI parse does not block this) --vault-off wins (safer default).
            // When neither is set, vault is on (ADR-015 §1: default = vault-on).
            let vaultValue = vaultOff ? "0" : "1"
            let daemonEnv = [
                "MOOTX01_HTTP_PORT": String(MootPaths.defaultResidentPort),
                "MOOTX01_DATA_DIR": dataDir.path,
                "ARIA_MCP_STATS_STORE": MootPaths.daemonStatsStorePath(dataDir: dataDir),
                "MOOTX01_VAULT": vaultValue,
            ]
            switch LaunchAgent.installDaemon(binaryPath: binaryPath, homeDirectory: home, environment: daemonEnv) {
            case let .installed(plistPath, endpointURL):
                print("")
                print("  ✓ Resident mootx01 daemon running in the background (launchd: \(MootPaths.daemonLabel))")
                print("    MCP endpoint: \(endpointURL)")
                print("    LaunchAgent:  \(plistPath)")
            case let .launchctlFailed(message):
                print("")
                print("  ✗ Could not start the resident daemon via launchd: \(message)")
                print("    Start it manually any time with:  mootx01 serve --http 4242")
            case .binaryNotFound:
                print("")
                print("  ⓘ mootx01 binary missing — run `mootx01 serve --http 4242` manually.")
            }
        }
        #endif

        // Parall sandboxed app instances — scan for cloned configs and wire each.
        // Parall creates per-instance directories under
        // ~/Library/Application Support/Parall/; each instance that has a
        // supported client installed has the client's config file at the root of
        // its instance directory. We detect and wire all of them using the same
        // entry as the native client install.
        #if os(macOS)
        var parallInstalled: [(client: String, path: String)] = []
        var parallSkipped:   [(client: String, path: String, error: String)] = []

        // Scope: only the clients the user actually selected (--target or the
        // picker). Iterating MCPClients.supported here wired every Parall
        // instance of every client regardless of --target.
        for client in clients {
            // Continue (YAML) has no JSON config to merge — skip it.
            // isHeadlessStdio clients are skipped (none currently, guard for future).
            guard !client.isHeadlessStdio,
                  client.id != "continue"
            else { continue }

            let parallPaths = Installer.parallConfigPaths(client: client, homeDirectory: home)
            for configURL in parallPaths {
                do {
                    // §4.2: same backup discipline as native configs.
                    try Installer.backupExisting(at: configURL)
                    try Installer.mergeIntoJSONConfig(
                        at: configURL,
                        client: client,
                        binaryPath: binaryPath,
                        daemonURL: MootPaths.residentEndpointURL
                    )
                    parallInstalled.append((client.displayName, configURL.path))
                } catch {
                    parallSkipped.append((client.displayName, configURL.path, "\(error)"))
                }
            }
        }

        if !parallInstalled.isEmpty {
            print("")
            print("Parall sandboxed instances:")
            for (name, path) in parallInstalled {
                // Abbreviate the long path for readability: show Parall/<instance>/filename
                let abbreviated = path.components(separatedBy: "/Parall/").last
                    .map { "Parall/" + $0 } ?? path
                print("  ✓ \(name): \(abbreviated)")
            }
        }
        for (name, path, error) in parallSkipped {
            print("  ✗ \(name) (\(path)): \(error)")
        }
        #endif

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

        // ADR-015 §1 mandatory disclosure: tell the user about the Vault
        // surface so they can make an informed security choice. Disclosure
        // is always printed regardless of which Vault flag was passed, so
        // the user knows the current state and how to change it.
        print("")
        if vaultOff {
            print("Vault (import/export to disk) is OFF.")
            print("  To re-enable: mootx01 install --vault-on")
        } else {
            print("Vault (import/export to disk) is ON by default.")
            print("  For a more secure position: mootx01 install --vault-off  # disables import/export")
        }
    }
}
