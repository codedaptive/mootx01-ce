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

    @Flag(name: .long, help: "Skip binary placement (the copy to ~/.mootx01/bin + PATH wrapper). Use when a package manager (Homebrew, apt) already placed the binary on PATH.")
    var noPlace: Bool = false

    @Flag(name: .long, help: "Skip installing the moot-mgr management console as a background launchd service (macOS).")
    var noManager: Bool = false

    @Flag(name: .long, help: "Use direct stdio client wiring (`mootx01 serve`) and skip registering the resident HTTP daemon as a background service. Stop an already-running resident for socket-free MCP operation.")
    var noDaemon: Bool = false

    @Flag(name: .long, help: "Enable Vault MCP tools (moot_vault_*): expose export/import/status/reconcile/job on the MCP surface. Default behavior when neither --vault-on nor --vault-off is specified.")
    var vaultOn: Bool = false

    @Flag(name: .long, help: "Hide Vault MCP tools (moot_vault_*) from the MCP surface. For a more secure install position that disables import/export. Use --vault-on to re-enable.")
    var vaultOff: Bool = false

    @Flag(name: .long, help: "Create the default estate WITHOUT at-rest encryption. The estate database is stored unencrypted. Default is encrypted (SQLCipher whole-database, key held in the Keychain). Run `mootx01 upgrade` at any time to encrypt an unencrypted estate.")
    var noEncrypt: Bool = false

    @Flag(name: .long, help: "Disable the on-device subject rider (Apple Intelligence miniLLM writing one-line subjects for imported/legacy memories during dreaming). Default is ON where the on-device model is available; this flag turns it off for the resident daemon.")
    var subjectRiderOff: Bool = false

    @Flag(name: .long, help: "When an estate database already exists: adopt it as the default estate and reset the moot-mgr history store (no prompt).")
    var reuseDb: Bool = false

    @Flag(name: .long, help: "When an estate database already exists: move it and the moot-mgr history to the Trash so a fresh database is created on first serve. Destructive — asks for a typed confirmation unless --yes.")
    var replaceDb: Bool = false

    func run() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let local = location == "local"

        guard !(reuseDb && replaceDb) else {
            throw ValidationError("--reuse-db and --replace-db are mutually exclusive.")
        }
        // Existing-database disposition (reinstall contract): resolved BEFORE
        // any wiring so a 'replace' that cannot proceed (daemon running,
        // trash failure) aborts the install with nothing half-done.
        try handleExistingDatabase(homeDirectory: home)

        // At-rest encryption posture for the DEFAULT estate.
        //
        // install does not create the estate file — it says so itself ("a fresh
        // estate will be created on first serve"), and the substrate writes the
        // SQLite file lazily on first open. So --no-encrypt cannot act now; it
        // records the choice next to the estate, and the shared open posture
        // (EstateKeyProvider.resolveOpenPosture) honors it when the file is
        // finally created. Encrypted is the default: absent the marker, first
        // serve provisions a key and creates a SQLCipher estate.
        //
        // Recorded as a marker file rather than only in the daemon environment
        // because `mootx01 serve` run by hand carries no launchd environment, and
        // the two must not disagree about the same estate.
        if noEncrypt {
            let dataDir = MootPaths.resolveDataDirectory(
                environment: ProcessInfo.processInfo.environment,
                homeDirectory: home
            )
            let estateURL = MootPaths.estateURL(in: dataDir)
            switch EstateKeyProvider.detectEstateFileState(at: estateURL) {
            case .absent:
                do {
                    try EstateKeyProvider.writeEncryptionOptOut(forEstateAt: estateURL)
                    print("Estate encryption: DISABLED (--no-encrypt). The estate will be stored unencrypted.")
                    print("  Run `mootx01 upgrade` at any time to encrypt it.")
                } catch {
                    // Failing to record the choice must not silently produce the
                    // opposite posture — the user would get an encrypted estate
                    // after asking for a plaintext one.
                    throw ValidationError(
                        "could not record the --no-encrypt choice at \(estateURL.deletingLastPathComponent().path): \(error)")
                }
            case .plaintext:
                print("Estate encryption: already unencrypted; --no-encrypt has nothing to change.")
            case .ciphertext:
                // Refuse to imply that --no-encrypt decrypts an existing estate.
                // It does not, and there is deliberately no path that does.
                print("Estate encryption: the existing estate is already ENCRYPTED; --no-encrypt does not decrypt it and was ignored.")
            }
        } else {
            // Encrypted is the default for THIS install. A stale --no-encrypt
            // marker left by an earlier estate at the same path (a prior
            // opt-out install whose database was later removed outside
            // --replace-db) must not survive to downgrade the estate this
            // install just promised would be encrypted: resolveOpenPosture
            // honors the marker for an ABSENT estate, so first serve would
            // silently create plaintext (stale-marker downgrade, Codex
            // fe2cf887). --replace-db trashes the marker with the estate in
            // DataRetention.applyReplace; this branch covers every other way
            // a marker outlives its database. Only the absent case is touched
            // — an existing estate's posture is a fact about the file, never
            // the marker.
            let dataDir = MootPaths.resolveDataDirectory(
                environment: ProcessInfo.processInfo.environment,
                homeDirectory: home
            )
            let estateURL = MootPaths.estateURL(in: dataDir)
            if case .absent = EstateKeyProvider.detectEstateFileState(at: estateURL) {
                do {
                    if try EstateKeyProvider.removeEncryptionOptOut(forEstateAt: estateURL) {
                        print("Estate encryption: removed a stale --no-encrypt marker; the new estate will be created ENCRYPTED (the default).")
                    }
                } catch {
                    // Failing to enact the default must not silently produce
                    // the opposite posture — the same rule the opt-out branch
                    // applies to recording the choice.
                    throw ValidationError(
                        "could not remove a stale --no-encrypt marker at \(EstateKeyProvider.encryptionOptOutMarkerURL(forEstateAt: estateURL).path): \(error). Remove it manually, or pass --no-encrypt if plaintext was intended.")
                }
            }
        }

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
        let requestedDepth: InstallDepth
        if let mode {
            guard let parsed = InstallDepth(modeFlag: mode) else {
                throw ValidationError("--mode must be 'server', 'skills', or 'plugin' (got '\(mode)').")
            }
            requestedDepth = parsed
        } else if yes {
            requestedDepth = .default
        } else {
            requestedDepth = AgentPicker.pickDepth()
        }
        // A plugin can own its own MCP connection and route through the resident
        // daemon. Direct stdio installs therefore stop at the skills ceiling;
        // the client config written below remains the connection owner.
        let depth: InstallDepth = noDaemon && requestedDepth == .plugin ? .skills : requestedDepth
        if noDaemon && requestedDepth == .plugin {
            print("Direct stdio requested: using skills depth instead of a connection-owning plugin.")
        }

        // Place the binary and use its installed absolute path as the config
        // `command`. --no-place skips this step for package-manager installs
        // (Homebrew, apt) where the binary is already on PATH and the package
        // manager owns placement. In that case, client configs point at the
        // running binary's resolved path directly.
        let binaryPath: String
        if noPlace {
            binaryPath = sourcePath
            print("Using binary at \(binaryPath) (--no-place: skipping ~/.mootx01 placement)")
            // Proxy symlink (#3): placeBinary creates mootx01-proxy beside the
            // placed binary. --no-place skips placeBinary, but proxy-bridge
            // clients (Claude Desktop) still need the symlink beside the binary
            // they point at. Create it next to the running binary.
            let proxyURL = URL(fileURLWithPath: sourcePath)
                .deletingLastPathComponent()
                .appendingPathComponent("mootx01-proxy")
            let fm = FileManager.default
            if fm.fileExists(atPath: proxyURL.path) {
                try? fm.removeItem(at: proxyURL)
            }
            try? fm.createSymbolicLink(
                atPath: proxyURL.path,
                withDestinationPath: URL(fileURLWithPath: sourcePath).lastPathComponent)
        } else {
            do {
                binaryPath = try Installer.placeBinary(sourcePath: sourcePath, homeDirectory: home)
                print("Placed binary at \(binaryPath)")
                print("Linked   \(MootPaths.binarySymlinkURL(homeDirectory: home).path)")
            } catch {
                print("Could not place binary: \(error)")
                if let hint = Installer.permissionRepairHint(for: error, homeDirectory: home) {
                    print(hint)
                }
                throw error
            }
        }

        print("\nInstalling mootx01 into \(clients.count) client(s)...")

        var installed: [String] = []
        var skipped: [String] = []

        // plugins the CLI installer knows how to detect and
        // defer to. Keyed by client id → the plugin registry id
        // (`installed_plugins.json`'s top-level key for Claude, config.toml +
        // package cache for Codex). Both shipped plugins own the same daemon
        // connection and must not coexist with an installer-written direct MCP
        // entry.
        let pluginOwnedClients: [String: String] = [
            "claude-code": "mootx01@mootx01",
            "codex": "mootx01@mootx01",
        ]

        for client in clients {
            // Adams #5: gate on installed AND enabled — Claude Code tracks
            // enablement separately (~/.claude/settings.json's
            // enabledPlugins map), and an installed-but-disabled plugin
            // does not own the connection. Skipping/removing the direct
            // entry in that state would leave the client with nothing.
            if !noDaemon,
               let pluginID = pluginOwnedClients[client.id],
               (client.id == "codex"
                    ? PluginDetector.ownsCodexConnection(pluginID: pluginID, homeDirectory: home)
                    : PluginDetector.ownsConnection(pluginID: pluginID, homeDirectory: home)) {
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
                // Wave 6, Defect A (live 1.0.16 machine finding): the
                // plugin-owned MCP connections ownership skip above applies ONLY to the direct
                // mcpServers entry. Before this fix, `continue` here left
                // `client.displayName` out of `installed` entirely, and the
                // depth loop below filters on `installed.contains(...)` —
                // so a plugin-owned client got NO depth pass at all: no
                // package rematerialization, no stranded-cache refresh.
                // The stale stdio-era package in ~/.claude/mootx01-plugin
                // (and Claude Code's stale cached snapshot) then survived
                // every subsequent `mootx01 install` run forever, because
                // the client silently never reached DepthInstaller.apply.
                // A plugin-owned connection is exactly the case where the
                // package must stay freshest, so this client counts as
                // "installed" (its MCP wiring succeeded — via the plugin,
                // not a direct entry) and proceeds to the depth pass below.
                installed.append(client.displayName)
                continue
            }
            do {
                try Installer.install(
                    client: client,
                    binaryPath: binaryPath,
                    daemonURL: MootPaths.residentEndpointURL,
                    homeDirectory: home,
                    workingDirectory: cwd,
                    local: local,
                    directStdio: noDaemon,
                    vaultOff: vaultOff
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
        // to every client whose MCP wiring succeeded — direct OR plugin-owned
        // (Wave 6, Defect A: a plugin-owned client's connection ownership is
        // NOT a reason to skip this pass; it is the reason the package must
        // stay freshest — Claude Code is the plugin's own host).
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
                    // of this call.
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
            let mgrPath: String?
            if noPlace {
                // Package manager owns placement — use the sibling binary
                // directly without copying to ~/.mootx01/bin.
                let fm = FileManager.default
                mgrPath = fm.isExecutableFile(atPath: mgrSource) ? mgrSource : nil
            } else {
                do {
                    mgrPath = try Installer.placeMgrBinary(sourceMgrPath: mgrSource, homeDirectory: home)
                } catch {
                    print("  ✗ Could not place moot-mgr: \(error)")
                    mgrPath = nil
                }
            }
            if let mgrPath {
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
                case .installedDisabled:
                    // install() never returns this case (it belongs to the
                    // daemon-bundle flow below); the vocabulary is one enum.
                    break
                case .binaryNotFound:
                    print("")
                    print("  ⓘ Management console binary missing — run `moot-mgr serve` manually.")
                }
            } else {
                print("")
                print("  ⓘ moot-mgr console not found beside mootx01 — skipping the background")
                print("    service. Install via the release (install.sh) or build apps/moot-mgr,")
                print("    then re-run `mootx01 install`.")
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
            let bundleExecutable = DaemonBundle.bundleExecutableURL(homeDirectory: home)
            if FileManager.default.isExecutableFile(atPath: bundleExecutable.path) {
                // The signed provider bundle is the Community 1.1 production
                // daemon. Remove the legacy raw-serve registration before
                // starting it so two launchd jobs can never race for custody.
                LaunchAgent.uninstallDaemon(homeDirectory: home)
                installDaemonBundleIfPresent(home: home)
            } else {
            let dataDir = MootPaths.resolveDataDirectory(
                environment: ProcessInfo.processInfo.environment,
                homeDirectory: home
            )
            // MOOTX01_VAULT: "0" = vault-off (--vault-off); "1" = vault-on (default).
            // The flag pair is mutually exclusive by convention: if both are set
            // (CLI parse does not block this) --vault-off wins (safer default).
            // When neither is set, vault is on (the open 1.0 Vault posture: default = vault-on).
            let vaultValue = vaultOff ? "0" : "1"
            // MOOTX01_ENCRYPT: "0" = --no-encrypt, "1" = encrypted (default).
            // Recorded for observability and parity with MOOTX01_VAULT. The
            // AUTHORITATIVE signal is the marker file written above, because a
            // hand-run `mootx01 serve` carries no launchd environment at all and
            // the two must never disagree about the same estate.
            let encryptValue = noEncrypt ? "0" : "1"
            // MOOTX01_SUBJECT_RIDER: "0" = --subject-rider-off; "1" = on
            // (the rider-default ruling, 2026-08-02). Availability is still
            // checked at serve; this only records the operator's choice.
            let subjectRiderValue = subjectRiderOff ? "0" : "1"
            let daemonEnv = [
                "MOOTX01_HTTP_PORT": String(MootPaths.defaultResidentPort),
                "MOOTX01_DATA_DIR": dataDir.path,
                "ARIA_MCP_STATS_STORE": MootPaths.daemonStatsStorePath(dataDir: dataDir),
                "MOOTX01_VAULT": vaultValue,
                "MOOTX01_ENCRYPT": encryptValue,
                "MOOTX01_SUBJECT_RIDER": subjectRiderValue,
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
            case .installedDisabled:
                // installDaemon() never returns this case (it belongs to the
                // daemon-bundle flow below); the vocabulary is one enum.
                break
            case .binaryNotFound:
                print("")
                print("  ⓘ mootx01 binary missing — run `mootx01 serve --http 4242` manually.")
            }

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
                    // directStdio/vaultOff must be forwarded here exactly as the
                    // native path forwards them to Installer.install() above.
                    // Both parameters default to false, so omitting them meant a
                    // `--no-daemon --vault-off` install still wrote an
                    // http://127.0.0.1:4242 entry into every Parall clone: the
                    // clone bypassed both postures, and with no daemon running
                    // any same-user process could bind that fixed port and
                    // impersonate the MCP server.
                    try Installer.mergeIntoJSONConfig(
                        at: configURL,
                        client: client,
                        binaryPath: binaryPath,
                        daemonURL: MootPaths.residentEndpointURL,
                        directStdio: noDaemon,
                        vaultOff: vaultOff
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

        // the open 1.0 Vault posture mandatory disclosure: tell the user about the Vault
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

    // MARK: - Existing-database disposition (reinstall contract)

    /// Reuse-or-replace flow for a pre-existing estate database. The
    /// decision matrix lives in `DataRetention.decideExistingDb`
    /// (unit-tested); this wrapper owns the prompts, the service stop, and
    /// the exit codes. Mirrors `handle_existing_database` in the Rust
    /// vertical — with one platform divergence: Rust refuses while its
    /// daemon is alive (systemd/task platforms, where the user stops the
    /// service), whereas here the launchd services are booted out before
    /// the stores move and the normal install flow re-registers them.
    private func handleExistingDatabase(homeDirectory home: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: environment, homeDirectory: home)
        guard DataRetention.defaultEstateExists(in: dataDir) else { return }

        let flag: DataRetention.ExistingDbChoice? =
            reuseDb ? .reuse : (replaceDb ? .replace : nil)
        let decision = DataRetention.decideExistingDb(
            flag: flag,
            yes: yes,
            interactive: isatty(STDIN_FILENO) != 0,
            choose: {
                print("\nAn existing MOOTx01 database was found at \(dataDir.path).")
                print("Reuse it, or replace it with a fresh one? [reuse/replace] (reuse): ", terminator: "")
                return readLine()?.trimmingCharacters(in: .whitespaces).lowercased() == "replace"
            },
            confirm: {
                print("WARNING: replacing DESTROYS the current default estate and moot-mgr history.")
                print("They will be moved to \(DataRetention.trashName) (recoverable until you empty it).")
                print("Type 'yes' to confirm: ", terminator: "")
                return readLine()?.trimmingCharacters(in: .whitespaces) == "yes"
            }
        )

        switch decision {
        case let .untouched(reason):
            print("  ⓘ \(reason)")
        case .aborted:
            print("Aborted — nothing was installed or removed.")
            throw ExitCode.failure
        case .reuse:
            stopResidentServices(homeDirectory: home)
            do {
                try DataRetention.applyReuse(in: dataDir)
                print("  ✓ Existing database adopted as the default estate; moot-mgr history reset.")
            } catch {
                print("  ✗ Could not adopt the existing database: \(error)")
                throw ExitCode.failure
            }
        case .replace:
            stopResidentServices(homeDirectory: home)
            do {
                try DataRetention.applyReplace(in: dataDir)
                print("  ✓ Previous database moved to \(DataRetention.trashName); a fresh estate will be created on first serve.")
            } catch {
                print("  ✗ Could not replace the database: \(error)")
                throw ExitCode.failure
            }
        }
    }

    /// Boot the resident daemon and management console out of launchd so no
    /// process holds the estate/stats stores open while they move to the
    /// Trash. The install flow re-registers both later (unless --no-daemon /
    /// --no-manager), so this is a restart, not a teardown.
    private func stopResidentServices(homeDirectory home: URL) {
        #if os(macOS)
        LaunchAgent.uninstallDaemon(homeDirectory: home)
        LaunchAgent.uninstall(homeDirectory: home)
        #endif
    }

    // MARK: - MACD-2c2 daemon bundle (macOS)

    #if os(macOS)
    /// Register and start the enabled daemon provider bundle, then run its
    /// read-only census. Honest skips otherwise:
    /// the census requires the SIGNED provider (only it can observe the
    /// canonical App Group tier), so no bundle means no census — never a
    /// CLI-side imitation of it.
    private func installDaemonBundleIfPresent(home: URL) {
        let bundleExecutable = DaemonBundle.bundleExecutableURL(homeDirectory: home)
        guard FileManager.default.isExecutableFile(atPath: bundleExecutable.path) else {
            print("")
            print("  ⓘ Daemon provider bundle not present — using the legacy resident service.")
            return
        }
        switch LaunchAgent.activateDaemonBundleEnabled(homeDirectory: home) {
        case let .installed(plistPath, endpointURL):
            print("")
            print("  ✓ Community daemon provider running (launchd: \(DaemonBundle.launchAgentLabel))")
            print("    MCP endpoint: \(endpointURL)")
            print("    LaunchAgent: \(plistPath)")
        case let .launchctlFailed(message):
            print("")
            print("  ✗ Could not start the daemon provider bundle: \(message)")
            return
        case .binaryNotFound:
            print("")
            print("  ✗ Daemon provider bundle executable is missing.")
            return
        case .installedDisabled:
            return
        }
        // Read-only census through the signed provider. Classifications and
        // digests only — the provider prints no raw paths.
        let census = DaemonBundle.runReadOnlyMode("census", homeDirectory: home)
        if let output = census.output, census.code == 0 {
            print("  Census (read-only, provider-reported):")
            print("    \(output)")
        } else {
            print("  ⓘ Census unavailable (provider exit \(census.code)).")
        }
    }
    #endif
}
