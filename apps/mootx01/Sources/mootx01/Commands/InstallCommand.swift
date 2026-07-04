// InstallCommand.swift
//
// Wire mootx01 into one or more MCP clients. ARIA tool permissions are opt-in.
// Mirrors the install surface of popular MCP server CLIs (e.g. @modelcontextprotocol).

import ArgumentParser
import AriaMCP
import Foundation
import MootInstallerCore

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Wire mootx01 into MCP clients."
    )

    @Option(name: .long, help: "Comma-separated client ids to install (e.g. claude,cursor). Default: interactive picker.")
    var target: String?

    @Option(name: .long, help: "Config scope: 'global' (default) or 'local' (project .mcp.json for Claude Code).")
    var location: String = "global"

    @Option(name: .long, help: "Integration depth applied to every selected client: 'server' (MCP only), 'skills' (server + mootx01-memory skill), or 'plugin' (server + native plugin). Default: prompt when interactive, else 'plugin'. Plugin falls back to skills on hosts without a plugin format.")
    var mode: String?

    @Flag(name: .shortAndLong, help: "Skip prompts; auto-detect and install all present clients.")
    var yes: Bool = false

    @Flag(name: .long, help: "Write EVERY ARIA MCP tool to settings.json permissions.allow (full auto-approval, including destructive tools). Default is a tiered write: diagnostics allowed, reads/writes ask, destructive purges denied.")
    var grantPermissions: Bool = false

    @Flag(name: .long, help: "Do not write to settings.json at all (skips the default tiered permissions).")
    var noPermissions: Bool = false

    @Flag(name: .long, help: "Skip installing the moot-mgr management console as a background launchd service (macOS).")
    var noManager: Bool = false

    @Flag(name: .long, help: "Skip registering the resident mootx01 daemon (HTTP MCP server + autonomic governor) as a background launchd service (macOS).")
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

        // Resolve the global integration depth (§4.4). Order of precedence:
        //   --mode flag (honored in both silent and guided modes)
        //   → --yes default (plugin, no prompt)
        //   → guided depth prompt (after the client picker, before apply)
        //   → default (plugin) when the prompt is non-interactive.
        let depth: InstallDepth
        if let mode {
            guard let parsed = InstallDepth(modeFlag: mode) else {
                throw ValidationError("--mode must be 'server', 'skills', or 'plugin' (got '\(mode)').")
            }
            depth = parsed
        } else if yes {
            depth = .default
        } else {
            depth = AgentPicker.pickDepth()
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

        // ADR-024 §1/§3: plugins the CLI installer knows how to detect and
        // defer to. Keyed by client id → the plugin registry id
        // (`installed_plugins.json`'s top-level key). Only Claude Code has a
        // live plugin today; the table is intentionally small rather than
        // guessed for hosts with no shipped plugin yet.
        let pluginOwnedClients: [String: String] = ["claude-code": "mootx01@mootx01"]

        for client in clients {
            // Adams #5: gate on installed AND enabled — Claude Code tracks
            // enablement separately (~/.claude/settings.json's
            // enabledPlugins map), and an installed-but-disabled plugin
            // does not own the connection. Skipping/removing the direct
            // entry in that state would leave the client with nothing.
            if let pluginID = pluginOwnedClients[client.id],
               PluginDetector.ownsConnection(pluginID: pluginID, homeDirectory: home) {
                // The plugin is the preferred connection owner (§1): still
                // place the binary/daemon (done above, unconditionally) but
                // skip writing a competing direct entry, and clean up any
                // direct entry a PRIOR install wrote — only when it is
                // confirmed ours-default (§4).
                do {
                    let outcome = try Installer.dedupeDirectEntry(
                        client: client, homeDirectory: home, workingDirectory: cwd, local: local
                    )
                    switch outcome {
                    case .none:
                        break
                    case .removedOursDefault:
                        print("  ⓘ \(client.displayName): removed a stale direct mootx01 entry — the plugin now owns the connection")
                    case let .retainedForeign(reason, path):
                        print("  ⚠ \(client.displayName): a non-default mootx01 entry at \(path) (\(reason)) was left untouched — inspect it by hand")
                    }
                } catch {
                    print("  ✗ \(client.displayName): could not check for a competing direct entry: \(error)")
                }
                print("  ⓘ MOOTx01 plugin already installed — \(client.displayName) connects through it; skipping direct wiring.")
                continue
            }
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
        //
        //   default              → TIERED by verb semantics (Bob's re-tier
        //                          ruling, 2026-07-04, PermissionsWriter.classify):
        //                          reads and additive-unconfirmed writes allow,
        //                          mutations of existing state ask, destructive
        //                          purges deny. The PRIOR default put every
        //                          non-diagnostic tool in ask — 55 ask rules on
        //                          a real machine, including every pure read —
        //                          which is what made moot unusable from
        //                          permission prompts. migrateTiers converges
        //                          an existing install onto the new default
        //                          before mergeTiered adds anything still
        //                          missing; both write BOTH the direct
        //                          (mcp__mootx01__) and plugin
        //                          (mcp__plugin_mootx01_mootx01__) namespaces
        //                          — a rule under only one matches zero calls
        //                          made through the other Claude Code
        //                          connection.
        //   --grant-permissions  → every tool into allow (explicit opt-in to
        //                          full auto-approval of the high-impact surface).
        //   --no-permissions     → write nothing.
        //
        // Tool names come from the linked server surface (ToolProjection), not
        // a hardcoded table — the old static list went stale when the tool
        // surface was renamed and granted 53 tools that no longer existed.
        if !noPermissions, clients.contains(where: { $0.id == "claude-code" }) {
            let settingsURL = local
                ? MootPaths.localClaudeSettingsURL(workingDirectory: cwd)
                : MootPaths.globalClaudeSettingsURL(homeDirectory: home)
            let toolNames = ToolProjection.tools().map(\.name)
            do {
                if grantPermissions {
                    try PermissionsWriter.merge(into: settingsURL, toolNames: toolNames)
                    print("  ✓ Granted \(toolNames.count) ARIA tool permissions (allow) in \(settingsURL.path)")
                } else {
                    // Re-tier any entry from a PRIOR install that predates
                    // the current classification (Bob's re-tier ruling,
                    // 2026-07-04) before adding whatever is still missing —
                    // otherwise a repeat `mootx01 install` run would leave
                    // an existing install's stale tiering (e.g. every read
                    // fossilized in `ask` under the old default) in place
                    // forever, since mergeTiered only adds absent entries.
                    let moved = try PermissionsWriter.migrateTiers(at: settingsURL, toolNames: toolNames)
                    if moved > 0 {
                        print("  ✓ Re-tiered \(moved) existing ARIA tool permission(s) to the current default")
                    }
                    let added = try PermissionsWriter.mergeTiered(into: settingsURL, toolNames: toolNames)
                    if added.allow + added.ask + added.deny > 0 {
                        print("  ✓ Claude Code tool permissions: \(added.allow) allowed (reads + new-content writes), \(added.ask) ask (mutations of existing content), \(added.deny) denied (destructive) — edit in \(settingsURL.path)")
                    }
                }
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

        // Integration depth (§4.4): server = MCP only (done above); skills/plugin
        // add the canonical SKILL.md / pre-generated package per client. The
        // depth is a target — each client gets the most it supports, and any
        // plugin→skills fallback is reported (the §4.4 ceiling table). Applied
        // only to clients whose MCP wiring succeeded.
        if depth != .server {
            print("")
            print("Integration depth: \(depth.rawValue)")
            for client in clients where installed.contains(client.displayName) {
                do {
                    // Thread the vault posture so any command/stdio-shaped
                    // entry in the plugin package (the proxy-bridge fallback
                    // for a host whose schema cannot express HTTP) inherits
                    // MOOTX01_VAULT=0 when --vault-off was passed (sec-fix
                    // 6b08d56b). HTTP-shaped entries are untouched — the
                    // resident daemon carries the vault posture in its own
                    // launchd environment (`daemonEnv` above), independent
                    // of this call (ADR-024 Wave 3, Defect 2).
                    let outcome = try DepthInstaller.apply(
                        clientID: client.id,
                        depth: depth,
                        homeDirectory: home,
                        binaryPath: binaryPath,
                        vaultOff: vaultOff
                    )
                    switch outcome {
                    case .server:
                        // Claude Desktop's "plugin" is a Desktop extension, not
                        // a file-drop payload. At plugin depth, install it
                        // programmatically (same registry writes a .mcpb
                        // double-click makes) so the .pkg wires Desktop with no
                        // manual step. Other MCP-only hosts (continue, kiro)
                        // genuinely have no plugin surface.
                        if client.id == "claude-desktop" {
                            #if os(macOS)
                            if depth == .plugin {
                                do {
                                    let written = try ClaudeDesktopExtension.install(
                                        binaryPath: binaryPath,
                                        version: Mootx01.currentVersion,
                                        homeDirectory: home)
                                    if written.isEmpty {
                                        print("  ⓘ \(client.displayName): MCP server wired (Claude Desktop not detected — skipped extension)")
                                    } else if written.count == 1 {
                                        print("  ✓ \(client.displayName): extension installed → restart Claude Desktop to load it")
                                    } else {
                                        print("  ✓ \(client.displayName): extension installed (main + \(written.count - 1) Parall instance\(written.count == 2 ? "" : "s")) → restart Claude Desktop to load it")
                                    }
                                } catch {
                                    print("  ⚠ \(client.displayName): MCP server wired; extension install failed: \(error)")
                                }
                            } else {
                                print("  ⓘ \(client.displayName): MCP server wired.")
                            }
                            #else
                            print("  ⓘ \(client.displayName): MCP server wired.")
                            #endif
                        } else {
                            print("  ⓘ \(client.displayName): server only (no skill/plugin payload for this client)")
                        }
                    case let .skills(path):
                        print("  ✓ \(client.displayName): skill installed → \(path)")
                    case let .plugin(path):
                        print("  ✓ \(client.displayName): plugin installed → \(path)")
                    case let .pluginFellBackToSkills(path, reason):
                        print("  ✓ \(client.displayName): skill installed (plugin → skills: \(reason)) → \(path)")
                    }
                } catch {
                    print("  ✗ \(client.displayName): depth install failed: \(error)")
                }
            }
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

        // Register the resident mootx01 daemon (HTTP MCP server + autonomic governor +
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

        // If ~/.local/bin is not on PATH, the wrapper won't resolve as a
        // bare `mootx01` command — print a PATH advisory. (MCP clients use
        // the absolute config path regardless, so this only affects running
        // `mootx01` by name in a shell.)
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
