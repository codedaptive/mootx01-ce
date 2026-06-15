// Installer.swift
//
// Swift reimplementation of the config-merge logic that was previously in
// bash + embedded Python (apps/mootx01/install.sh). Writes the mootx01 MCP
// server entry into each selected client's config file.
//
// JSON clients (Claude Desktop, Claude Code, Cursor, Cline):
//   Reads the existing config, merges `mcpServers.mootx01` in place,
//   writes back atomically. Idempotent: a second run with the same
//   binary path leaves the file byte-identical.
//
// Continue (YAML):
//   Continue's per-server MCP config lives at .continue/mcpServers/mootx01.yaml.
//   The YAML is a simple two-key object; we write it directly rather than
//   round-tripping a full YAML parser.
//
// Codex CLI / Codex Desktop (TOML):
//   These share ~/.codex/config.toml. The installer merges the
//   `[mcp_servers.mootx01]` table with a line-based pass that preserves all
//   unrelated content (other tables, top-level keys), rather than writing JSON
//   into a TOML file — which silently corrupted the file in earlier builds.
//   Install dispatches on the config file extension so a .toml never reaches
//   the JSON writer.
//
// Local mode (--location local):
//   For Claude Code only, the target path switches from `~/.claude.json` to
//   `.mcp.json` in the working directory. All other clients are global-only.
//
// MOOT.md instructions file:
//   After wiring clients, the installer writes a brief MOOT.md into the
//   Claude Code instructions path so agents know MOOT is available.

import Foundation

/// Writes and removes MCP server config entries for each supported client.
public enum Installer {

    // MARK: - Binary placement

    /// Copy the running `mootx01` binary into the standard install
    /// directory and symlink it onto PATH. Mirrors codegraph's
    /// install.sh: a self-contained executable lands at
    /// `<home>/.mootx01/bin/mootx01`, and `<home>/.local/bin/mootx01`
    /// symlinks to it so the command resolves from any shell.
    ///
    /// This is the fix for the core installer bug: previously the
    /// installer wrote `command: <wherever the binary was run from>`
    /// into every client config, so the entry pointed at a CWD or
    /// dev-tree path. By copying to a stable location first and writing
    /// THAT absolute path into the configs, the wiring survives moving
    /// or deleting the source binary.
    ///
    /// Re-install is overwrite-safe: an existing placed binary is
    /// replaced and an existing symlink is repointed.
    ///
    /// - Parameters:
    ///   - sourcePath: absolute path of the binary to copy (the running
    ///     executable, i.e. `Bundle.main.executablePath`).
    ///   - homeDirectory: user's home directory. Inject in tests.
    ///   - force: when `true`, the copy proceeds even when `sourcePath`
    ///     resolves to the same file as the install destination. The
    ///     default `false` preserves the install-from-placed-binary
    ///     guard (skipping the copy prevents a self-destructive
    ///     remove-then-copy cycle). Pass `true` from `mootx01 upgrade`
    ///     where the source is always a freshly built binary at a
    ///     different path. Do NOT pass `true` when `sourcePath` already
    ///     resolves to the install destination — the code removes dest
    ///     before copying, so source-equals-dest with force:true will
    ///     throw a file-not-found error.
    /// - Returns: the absolute path of the placed binary
    ///   (`installedBinaryURL`) — feed this into `install(...)` as the
    ///   client config `command`.
    /// - Throws: filesystem errors (copy, chmod, or symlink failure).
    @discardableResult
    public static func placeBinary(
        sourcePath: String,
        homeDirectory: URL,
        force: Bool = false
    ) throws -> String {
        let fm = FileManager.default
        let destURL = MootPaths.installedBinaryURL(homeDirectory: homeDirectory)
        let binDir = MootPaths.installedBinaryDirURL(homeDirectory: homeDirectory)
        let symlinkURL = MootPaths.binarySymlinkURL(homeDirectory: homeDirectory)
        let localBinDir = MootPaths.localBinDirURL(homeDirectory: homeDirectory)

        // 1. Resolve the source to its REAL path first. When `mootx01 install`
        //    is run from the already-installed binary, it was launched via the
        //    ~/.local/bin/mootx01 symlink, and `copyItem` on a symlink copies
        //    the LINK (not its target) — which, after removing the real dest,
        //    lands a self-referential symlink at dest (ELOOP) that breaks every
        //    subsequent install. Resolving guarantees we copy a regular file.
        let realSource = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        // When force is false (default install path), skip the copy if the source
        // already IS the installed binary — removing dest would delete the source
        // itself. When force is true (upgrade path), always copy regardless of
        // path equality so a newly built binary replaces the installed one.
        // Skip straight to (re)perms + symlink when the copy is skipped.
        if force || realSource.standardizedFileURL.path != destURL.standardizedFileURL.path {
            // Remove any prior placed binary OR stale/looped symlink at dest so
            // the fresh copy lands cleanly (removeItem on a symlink unlinks it,
            // even a self-referential one).
            if fm.fileExists(atPath: destURL.path)
                || (try? fm.destinationOfSymbolicLink(atPath: destURL.path)) != nil {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: realSource, to: destURL)
        }

        // 2. Mark the placed binary executable (0755). copyItem preserves
        //    the source mode, but a build product copied from a sandbox or
        //    archive may lose the bit — set it explicitly to be safe.
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destURL.path
        )

        // 3. Repoint the PATH symlink. Remove any existing entry first
        //    (file OR dangling symlink) so ln -sf semantics hold.
        try fm.createDirectory(at: localBinDir, withIntermediateDirectories: true)
        // symlinkExists must use lstat semantics: a dangling symlink would
        // report false from fileExists but still block createSymbolicLink.
        if (try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil
            || fm.fileExists(atPath: symlinkURL.path) {
            try fm.removeItem(at: symlinkURL)
        }
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: destURL)

        // 4. Copy every SPM resource bundle sitting beside the source binary
        //    into the install dir. A Swift executable that links a target using
        //    `Bundle.module` fatalErrors at the static-init that first touches
        //    the bundle if the `<Target>_<Target>.bundle` is not co-located with
        //    the executable. The release build emits these next to the binary;
        //    placement must carry them or the placed binary crashes on first use
        //    of any resource (e.g. moot-mgr's LatticeLib FDC data on /api/graph).
        try copyResourceBundles(besideSource: realSource, toDir: binDir)

        return destURL.path
    }

    /// Copy the `moot-mgr` console binary into the install directory beside
    /// `mootx01` and symlink it onto PATH. Same overwrite-safe contract as
    /// `placeBinary`. moot-mgr ships next to mootx01 in the macOS release
    /// archive, so its source is the sibling of the running executable.
    ///
    /// Returns `nil` (rather than throwing) when there is no moot-mgr to
    /// install — `sourceMgrPath` is absent/missing AND nothing is already
    /// placed. That happens for a dev build of `mootx01` alone, or a Linux
    /// install; the caller skips the LaunchAgent in that case.
    ///
    /// - Parameters:
    ///   - sourceMgrPath: absolute path of the moot-mgr binary to copy
    ///     (the sibling of the running `mootx01`), or `nil` if unknown.
    ///   - homeDirectory: user's home directory. Inject in tests.
    /// - Returns: the placed binary path, or `nil` when nothing was installed.
    /// - Throws: filesystem errors (copy, chmod, or symlink failure).
    @discardableResult
    public static func placeMgrBinary(
        sourceMgrPath: String?,
        homeDirectory: URL
    ) throws -> String? {
        let fm = FileManager.default
        let destURL = MootPaths.installedMgrBinaryURL(homeDirectory: homeDirectory)
        let binDir = MootPaths.installedBinaryDirURL(homeDirectory: homeDirectory)
        let symlinkURL = MootPaths.mgrSymlinkURL(homeDirectory: homeDirectory)
        let localBinDir = MootPaths.localBinDirURL(homeDirectory: homeDirectory)

        // Resolve the source only if one was supplied and actually exists.
        var realSource: URL?
        if let sourceMgrPath, fm.fileExists(atPath: sourceMgrPath) {
            realSource = URL(fileURLWithPath: sourceMgrPath).resolvingSymlinksInPath()
        }
        // Nothing to copy and nothing already placed → no console to install.
        if realSource == nil && !fm.fileExists(atPath: destURL.path) {
            return nil
        }

        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        // Copy only when the source differs from the destination (a re-install
        // run against the already-placed copy has nothing to do).
        if let realSource,
           realSource.standardizedFileURL.path != destURL.standardizedFileURL.path {
            if fm.fileExists(atPath: destURL.path)
                || (try? fm.destinationOfSymbolicLink(atPath: destURL.path)) != nil {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: realSource, to: destURL)
        }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destURL.path)

        try fm.createDirectory(at: localBinDir, withIntermediateDirectories: true)
        if (try? fm.destinationOfSymbolicLink(atPath: symlinkURL.path)) != nil
            || fm.fileExists(atPath: symlinkURL.path) {
            try fm.removeItem(at: symlinkURL)
        }
        try fm.createSymbolicLink(at: symlinkURL, withDestinationURL: destURL)

        // Carry moot-mgr's SPM resource bundles into the install dir alongside
        // the binary. moot-mgr links LatticeLib/EideticLib (and swift-crypto),
        // each of which ships a `<Target>_<Target>.bundle` that `Bundle.module`
        // resolves relative to the executable; without them the placed console
        // hard-crashes the first time it touches a bundled resource. realSource
        // is non-nil here whenever a fresh moot-mgr was actually copied; on a
        // copy-skipped re-install there is nothing new to carry.
        if let realSource {
            try copyResourceBundles(besideSource: realSource, toDir: binDir)
        }

        return destURL.path
    }

    /// Copy every SPM resource bundle (`*.bundle`) that sits beside `source`
    /// into `destDir`, replacing any prior copy. SwiftPM emits a
    /// `<Target>_<Target>.bundle` next to the executable for each linked target
    /// that declares resources; a binary built with `Bundle.module` resolves
    /// these relative to its own location at static-init time and fatalErrors if
    /// they are missing. Placement copies the executable alone by default, so
    /// this must run after every binary copy to keep the bundles co-located.
    ///
    /// Kept general on purpose: it copies ALL `.bundle` siblings, not a hardcoded
    /// list, so a future target adding resources is carried automatically without
    /// another installer change.
    ///
    /// - Parameters:
    ///   - source: the resolved source binary; its parent directory is scanned.
    ///   - destDir: the install bin directory the bundles are copied into.
    /// - Throws: filesystem errors (copy or remove failure).
    static func copyResourceBundles(besideSource source: URL, toDir destDir: URL) throws {
        let fm = FileManager.default
        let sourceDir = source.deletingLastPathComponent()
        guard let siblings = try? fm.contentsOfDirectory(
            at: sourceDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for sibling in siblings where sibling.pathExtension == "bundle" {
            let destBundle = destDir.appendingPathComponent(sibling.lastPathComponent)
            // Replace any stale copy so a re-install/upgrade refreshes bundle
            // contents (the JSON data files inside can change between builds).
            if fm.fileExists(atPath: destBundle.path) {
                try fm.removeItem(at: destBundle)
            }
            try fm.copyItem(at: sibling, to: destBundle)
        }
    }

    /// Remove the placed binary and its PATH symlink. Inverse of
    /// `placeBinary`. Safe to call when nothing was installed.
    ///
    /// Removes `<home>/.local/bin/mootx01` (the symlink) and the whole
    /// `<home>/.mootx01` directory (matching codegraph's
    /// `rm -rf "$INSTALL_DIR"`). Leaves `~/.local/bin` itself intact —
    /// other tools may live there.
    ///
    /// - Parameter homeDirectory: user's home directory. Inject in tests.
    /// - Throws: filesystem errors other than "not found".
    public static func removePlacedBinary(homeDirectory: URL) throws {
        let fm = FileManager.default
        let symlinkURL = MootPaths.binarySymlinkURL(homeDirectory: homeDirectory)
        let mgrSymlinkURL = MootPaths.mgrSymlinkURL(homeDirectory: homeDirectory)
        let installRoot = homeDirectory.appendingPathComponent(".mootx01", isDirectory: true)

        // Remove both PATH symlinks (mootx01 + moot-mgr). The install root
        // rmrf below takes the binaries and logs; the symlinks live under
        // ~/.local/bin and must be unlinked separately.
        for link in [symlinkURL, mgrSymlinkURL] {
            if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
                || fm.fileExists(atPath: link.path) {
                try fm.removeItem(at: link)
            }
        }
        if fm.fileExists(atPath: installRoot.path) {
            try fm.removeItem(at: installRoot)
        }
    }

    // MARK: - Install

    /// Wire the mootx01 MCP server into a client's config file.
    ///
    /// - Parameters:
    ///   - client: the client to configure.
    ///   - binaryPath: absolute path to the `mootx01` binary.
    ///   - homeDirectory: user's home directory.
    ///   - workingDirectory: CWD at install time (for --local Claude Code).
    ///   - local: when true and client is Claude Code, write to `.mcp.json`
    ///     in `workingDirectory` instead of the global config.
    /// - Throws: filesystem or JSON errors.
    public static func install(
        client: MCPClient,
        binaryPath: String,
        daemonURL: String,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) throws {
        let configURL = resolveConfigURL(
            client: client,
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            local: local
        )

        // §4.2: timestamped backup of any existing config before modification.
        try backupExisting(at: configURL)

        if client.id == "continue" {
            // HTTP-capable → streamable-http YAML pointing at the daemon; else
            // the stdio command entry.
            try installContinue(
                configURL: configURL,
                binaryPath: binaryPath,
                httpURL: client.supportsLocalHTTP ? daemonURL : nil
            )
        } else {
            // HTTP, proxy-bridge, and headless-stdio entry shapes are determined
            // by the client's transport flags; mergeIntoJSONConfig selects the
            // correct shape and writes the config atomically.
            if client.isHeadlessStdio {
                // Headless stdio mode: the client spawns an ephemeral serve process
                // rather than routing through the resident daemon. No telemetry,
                // no moot-mgr monitoring, no single-writer guarantee.
                print("  ⚠︎  \(client.displayName): lightweight headless mode — statistics and monitoring are not available in this configuration.")
            }
            // Dispatch on the config file format. Writing a JSON body into a
            // non-JSON config silently corrupts it (this is what broke Codex,
            // whose config.toml was overwritten with JSON), so each format has
            // its own merge path and an unknown format is refused rather than
            // clobbered.
            switch configURL.pathExtension.lowercased() {
            case "toml":
                try mergeIntoTOMLConfig(
                    at: configURL,
                    client: client,
                    binaryPath: binaryPath,
                    daemonURL: daemonURL
                )
            case "json", "jsonc":
                try mergeIntoJSONConfig(
                    at: configURL,
                    client: client,
                    binaryPath: binaryPath,
                    daemonURL: daemonURL
                )
            default:
                if client.id == "hermes" {
                    // Hermes' shared config.yaml: line-based block merge under
                    // `mcp_servers:` (schema source-grounded against the real
                    // hermes-agent example; parser-verified on macOS + Windows).
                    try mergeIntoHermesYAML(
                        at: configURL,
                        serverName: client.serverName,
                        url: daemonURL
                    )
                } else {
                    // Unknown non-JSON, non-TOML config. Refuse loudly instead
                    // of writing JSON over a format we do not understand.
                    throw InstallerError.unsupportedConfigFormat(
                        format: configURL.pathExtension,
                        client: client.displayName,
                        path: configURL.path
                    )
                }
            }
        }
    }

    /// Scan ~/Library/Application Support/Parall/ for sandboxed app instances
    /// that contain a config file matching this client's config filename.
    ///
    /// Parall creates per-instance directories under that path; each instance
    /// that has the client installed has the client's config file at the root
    /// of its instance directory (e.g. Parall/claude-a/claude_desktop_config.json).
    ///
    /// The match is by filename only (last path component of `client.configPath`),
    /// so any client whose config filename is unique to that client is auto-discovered
    /// without knowing the Parall instance name in advance.
    ///
    /// Returns absolute URLs of every matching config file found. Returns [] when
    /// the Parall directory does not exist or contains no matching instances.
    ///
    /// - Parameters:
    ///   - client: The MCPClient whose config filename to search for.
    ///   - homeDirectory: The user's home directory.
    public static func parallConfigPaths(
        client: MCPClient,
        homeDirectory: URL
    ) -> [URL] {
        let parallRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/Parall")
        let targetFilename = URL(fileURLWithPath: client.configPath).lastPathComponent
        // e.g. "claude_desktop_config.json" from
        // "Library/Application Support/Claude/claude_desktop_config.json"

        let fm = FileManager.default
        guard let instances = try? fm.contentsOfDirectory(
            at: parallRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        return instances.compactMap { instanceDir -> URL? in
            guard (try? instanceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            let candidate = instanceDir.appendingPathComponent(targetFilename)
            return fm.fileExists(atPath: candidate.path) ? candidate : nil
        }.sorted { $0.path < $1.path }  // stable order for install output
    }

    /// Write MOOT.md into the Claude Code agent instructions path so agents
    /// automatically know the MOOT server is available.
    ///
    /// - Parameters:
    ///   - homeDirectory: user's home directory.
    ///   - local: when true, write into the working directory's `.claude/` instead.
    ///   - workingDirectory: CWD at install time.
    /// - Throws: filesystem errors.
    public static func writeMOOTmd(
        homeDirectory: URL,
        local: Bool,
        workingDirectory: URL
    ) throws {
        let dir: URL
        if local {
            dir = workingDirectory.appendingPathComponent(".claude", isDirectory: true)
        } else {
            dir = homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mootMD = dir.appendingPathComponent("MOOT.md", isDirectory: false)
        // Only write if absent — preserve any user edits on re-install.
        guard !FileManager.default.fileExists(atPath: mootMD.path) else { return }
        let content = """
        # MOOT is available

        This environment has the MOOT MCP server wired. You can use MOOT tools to
        file and recall information across sessions. Start with `moot_drawer_recall`
        to see what is already stored, or `moot_capture_drawer` to file a new item.
        Run `mootx01 status` in the terminal to see the active estate and server state.
        """
        try content.write(to: mootMD, atomically: true, encoding: .utf8)
    }

    // MARK: - Uninstall

    /// Remove the mootx01 MCP server entry from a client's config file.
    ///
    /// - Parameters:
    ///   - client: the client to unconfigure.
    ///   - homeDirectory: user's home directory.
    ///   - workingDirectory: CWD at uninstall time.
    ///   - local: when true and client is Claude Code, target `.mcp.json`.
    /// - Throws: filesystem or JSON errors.
    public static func uninstall(
        client: MCPClient,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) throws {
        let configURL = resolveConfigURL(
            client: client,
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            local: local
        )

        guard FileManager.default.fileExists(atPath: configURL.path) else { return }

        // §4.2: timestamped backup before modification (continue's per-server
        // file is deleted outright; the backup preserves it).
        try backupExisting(at: configURL)

        if client.id == "continue" {
            try? FileManager.default.removeItem(at: configURL)
        } else {
            switch configURL.pathExtension.lowercased() {
            case "toml":
                // Codex config.toml — the old path routed TOML through the JSON
                // remover, whose parse failed and silently no-opped, leaving the
                // [mcp_servers.mootx01] table behind forever.
                try removeFromTOMLConfig(at: configURL, serverName: client.serverName)
            case "json", "jsonc":
                try uninstallJSON(
                    configURL: configURL,
                    serversKey: client.jsonServersKey,
                    serverName: client.serverName
                )
            default:
                if client.id == "hermes" {
                    try removeFromHermesYAML(at: configURL, serverName: client.serverName)
                }
                // Unknown formats: nothing was ever written by us; leave alone.
            }
        }
    }

    // MARK: - JSON client helpers

    /// Merge the mootx01 MCP entry into a JSON config file at an absolute path.
    /// Used for both native client configs and Parall-instance configs.
    ///
    /// Reads the existing JSON (or starts from `{}` if the file does not exist or
    /// is empty), sets `mcpServers[client.serverName]` to the entry appropriate
    /// for this client's transport, and writes the result back atomically.
    ///
    /// The entry shape follows the same logic as `install()`:
    ///   - supportsLocalHTTP → `{"type":"http","url":daemonURL}` or `{"url":daemonURL}`
    ///   - useProxyBridge    → `{"command":binaryPath,"args":["proxy","--http",daemonURL],"env":{}}`
    ///   - isHeadlessStdio  → `{"command":binaryPath,"args":[],"env":{}}` (not used for any
    ///                         current client but included for completeness)
    ///
    /// - Parameters:
    ///   - configURL: Absolute URL of the JSON config file to update.
    ///   - client:    The MCPClient whose transport config determines the entry shape.
    ///   - binaryPath: Absolute path of the placed mootx01 binary.
    ///   - daemonURL:  The resident daemon HTTP endpoint (e.g. "http://127.0.0.1:4242").
    /// - Throws: JSON decode/encode errors or filesystem write errors.
    public static func mergeIntoJSONConfig(
        at configURL: URL,
        client: MCPClient,
        binaryPath: String,
        daemonURL: String
    ) throws {
        let entry: [String: Any]
        if client.id == "opencode" {
            // Schema-verified (https://opencode.ai/config.json, McpRemoteConfig):
            // remote servers are { "type": "remote", "url": … } under the
            // top-level "mcp" key — not the mcpServers/"http" convention.
            entry = ["type": "remote", "url": daemonURL]
        } else if client.supportsLocalHTTP {
            entry = client.httpEntryIncludesType
                ? ["type": "http", "url": daemonURL]
                : ["url": daemonURL]
        } else if client.useProxyBridge {
            entry = ["command": binaryPath,
                     "args": ["proxy", "--http", daemonURL],
                     "env": [:] as [String: String]]
        } else {
            // Headless stdio: client spawns an ephemeral serve process per call.
            // No telemetry, no moot-mgr monitoring, no single-writer guarantee.
            entry = ["command": binaryPath, "args": [], "env": [:] as [String: String]]
        }

        var root: [String: Any]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            let isBlank = data.isEmpty ||
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isBlank {
                // Empty or whitespace-only file: safe to treat as a new config.
                root = [:]
            } else if let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                root = parsed
            } else {
                // The file exists and has content but is not a JSON object.
                // The old behavior silently fell back to `{}` and overwrote it,
                // destroying the user's config (including any non-JSON config
                // mis-routed here). Refuse and surface what happened instead.
                throw InstallerError.malformedConfig(
                    path: configURL.path,
                    detail: "existing file is not valid JSON; refusing to overwrite it. Inspect or remove the file, then re-run."
                )
            }
        } else {
            root = [:]
        }

        // Merge in place: root[<serversKey>]["mootx01"] = entry (stdio command
        // entry, or an HTTP {type?,url} entry — built above per client
        // transport). The servers key is per-client: opencode uses "mcp",
        // every other JSON client uses "mcpServers".
        let serversKey = client.jsonServersKey
        var mcpServers = root[serversKey] as? [String: Any] ?? [:]
        mcpServers[client.serverName] = entry
        root[serversKey] = mcpServers

        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: configURL, options: .atomic)
    }

    // MARK: - TOML client helpers

    /// Merge the mootx01 MCP entry into a TOML config file (Codex CLI / Desktop).
    ///
    /// Codex stores MCP servers as `[mcp_servers.<name>]` tables in
    /// `~/.codex/config.toml`. There is no Foundation TOML codec and the kit
    /// ships zero external dependencies, so this is a deliberate line-based
    /// merge rather than a parse/re-emit round-trip: it replaces only the
    /// `[mcp_servers.<serverName>]` table (and any of its child subtables) and
    /// preserves every other line — other tables, top-level keys, comments,
    /// formatting — verbatim.
    ///
    /// The entry shape follows the same transport logic as the JSON writer:
    ///   - supportsLocalHTTP → `url = "<daemonURL>"`
    ///   - useProxyBridge    → `command`/`args = ["proxy", "--http", "<daemonURL>"]`
    ///   - headless stdio    → `command`/`args = []`
    ///
    /// - Throws: `InstallerError.malformedConfig` if the existing file contains
    ///   a JSON object (the signature of a prior broken install that wrote JSON
    ///   into the TOML file); filesystem errors on read/write.
    public static func mergeIntoTOMLConfig(
        at configURL: URL,
        client: MCPClient,
        binaryPath: String,
        daemonURL: String
    ) throws {
        let header = "[mcp_servers.\(client.serverName)]"
        var block = [header]
        if client.supportsLocalHTTP {
            block.append("url = \"\(daemonURL)\"")
        } else if client.useProxyBridge {
            block.append("command = \"\(binaryPath)\"")
            block.append("args = [\"proxy\", \"--http\", \"\(daemonURL)\"]")
        } else {
            block.append("command = \"\(binaryPath)\"")
            block.append("args = []")
        }
        let newTable = block.joined(separator: "\n")

        var existingText = ""
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            existingText = String(decoding: data, as: UTF8.self)
            // A config.toml whose content is a JSON object is the fingerprint of
            // a prior broken install (JSON written into the TOML file). Appending
            // a TOML table would leave the file invalid either way, so refuse and
            // tell the user how to recover rather than compounding the corruption.
            let trimmed = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.first == "{",
               (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
                throw InstallerError.malformedConfig(
                    path: configURL.path,
                    detail: "file contains JSON, not TOML (likely a prior broken install). Back it up and remove it, then re-run."
                )
            }
        }

        let merged = Self.replacingTOMLTable(in: existingText, header: header, with: newTable)
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(merged.utf8).write(to: configURL, options: .atomic)
    }

    /// Return `text` with the TOML table named by `header` (and any of its child
    /// subtables) removed and `newTable` appended at the end.
    ///
    /// Line-based and order-insensitive: TOML table order is not significant, so
    /// re-appending the server table at the end is valid as long as all
    /// preserved top-level keys precede it (they always do — top-level keys are
    /// only legal before the first table header). A child subtable is any header
    /// beginning `"[mcp_servers.<serverName>."`; those are consumed with the
    /// parent so a re-install never leaves an orphaned subtable behind.
    static func replacingTOMLTable(in text: String, header: String, with newTable: String) -> String {
        // header is "[mcp_servers.mootx01]"; childPrefix is "[mcp_servers.mootx01."
        let childPrefix = String(header.dropLast()) + "."
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var output: [String] = []
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == header || trimmed.hasPrefix(childPrefix) {
                // Skip this table's header and body up to (not including) the next
                // unrelated table header or EOF. Other mootx01 child subtables
                // encountered mid-skip are consumed too.
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("[") && t != header && !t.hasPrefix(childPrefix) { break }
                    i += 1
                }
                continue
            }
            output.append(lines[i])
            i += 1
        }
        // Drop trailing blank lines from the preserved content so the appended
        // table is separated by exactly one blank line.
        while let last = output.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            output.removeLast()
        }
        var result = output.joined(separator: "\n")
        if !result.isEmpty { result += "\n\n" }
        result += newTable + "\n"
        return result
    }

    /// Remove the `[mcp_servers.<serverName>]` table (and child subtables)
    /// from a TOML config. Mirrors the install-side skip logic, then trims
    /// trailing blank runs to a single trailing newline — so an
    /// install → uninstall pair restores the original file byte-identically
    /// (the install appended exactly one blank separator + our table).
    public static func removeFromTOMLConfig(at configURL: URL, serverName: String) throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let text = try String(contentsOf: configURL, encoding: .utf8)
        let header = "[mcp_servers.\(serverName)]"
        let childPrefix = String(header.dropLast()) + "."
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var output: [String] = []
        var i = 0
        var removed = false
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == header || trimmed.hasPrefix(childPrefix) {
                removed = true
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("[") && t != header && !t.hasPrefix(childPrefix) { break }
                    i += 1
                }
                continue
            }
            output.append(lines[i])
            i += 1
        }
        guard removed else { return }
        while let last = output.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            output.removeLast()
        }
        var result = output.joined(separator: "\n")
        if !result.isEmpty { result += "\n" }
        try result.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Backups (§4.2)

    /// Copy an existing config to `<name>.bak-<yyyyMMdd-HHmmss>` beside it
    /// before modification. Fresh (absent) files are exempt — there is
    /// nothing to preserve. Matches the Rust vertical's backup_existing.
    public static func backupExisting(at configURL: URL) throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let stamp = formatter.string(from: Date())
        let backupURL = configURL.deletingLastPathComponent()
            .appendingPathComponent(configURL.lastPathComponent + ".bak-" + stamp)
        // A second backup within the same second is a no-op (the first copy
        // already preserves the pre-modification state).
        guard !FileManager.default.fileExists(atPath: backupURL.path) else { return }
        try FileManager.default.copyItem(at: configURL, to: backupURL)
    }

    // MARK: - Hermes shared YAML (line-based block merge under `mcp_servers:`)

    /// Merge the mootx01 entry into Hermes' shared `config.yaml`. Schema
    /// verified against the real hermes-agent `cli-config.yaml.example`:
    /// a top-level `mcp_servers:` mapping whose HTTP entries carry a `url:`
    /// key. Line-based, same discipline as the TOML merge: only our own
    /// block is touched, every other line preserved verbatim. Flow style
    /// (`mcp_servers: {…}`) is refused rather than risked.
    public static func mergeIntoHermesYAML(
        at configURL: URL,
        serverName: String,
        url: String
    ) throws {
        let existing: String
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            existing = String(decoding: data, as: UTF8.self)
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{"),
               (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
                throw InstallerError.malformedConfig(
                    path: configURL.path,
                    detail: "file contains JSON, not YAML (likely a prior broken install). Restore from the .bak- backup beside it or remove it, then re-run."
                )
            }
        } else {
            existing = ""
        }
        let block = "  \(serverName):\n    url: \(url)"
        let merged = try replacingHermesBlock(
            in: existing,
            serverName: serverName,
            replacement: block,
            path: configURL.path
        )
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try merged.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Remove the mootx01 block from Hermes' `config.yaml`. Absent file or
    /// absent entry is a no-op. When the removal leaves `mcp_servers:` with
    /// no children at all (the section we created on install), the bare
    /// section line and its preceding blank separator are dropped too, so
    /// install → uninstall restores the original file byte-identically.
    public static func removeFromHermesYAML(at configURL: URL, serverName: String) throws {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let existing = try String(contentsOf: configURL, encoding: .utf8)
        let entryHeader = "  \(serverName):"
        let present = existing.components(separatedBy: "\n").contains {
            $0.hasSuffix(" ") ? String($0.reversed().drop(while: { $0 == " " }).reversed()) == entryHeader
                              : $0 == entryHeader
        }
        guard present else { return }
        let stripped = try replacingHermesBlock(
            in: existing,
            serverName: serverName,
            replacement: nil,
            path: configURL.path
        )
        let final = droppingEmptyHermesSection(stripped)
        try final.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// Rewrite the `mcp_servers:` block: drop any existing `  <server>:`
    /// entry (with its more-indented children), then insert `replacement`
    /// immediately after the `mcp_servers:` line (creating the section at
    /// EOF when absent). `replacement: nil` = removal. Everything else
    /// preserved verbatim.
    static func replacingHermesBlock(
        in text: String,
        serverName: String,
        replacement: String?,
        path: String
    ) throws -> String {
        let lines = text.isEmpty ? [] : text.components(separatedBy: "\n")

        // Locate the top-level `mcp_servers:` line; refuse flow style.
        var sectionIdx: Int? = nil
        for (i, line) in lines.enumerated() {
            if line.hasPrefix("mcp_servers:") {
                let after = String(line.dropFirst("mcp_servers:".count))
                    .trimmingCharacters(in: .whitespaces)
                if !(after.isEmpty || after.hasPrefix("#")) {
                    throw InstallerError.malformedConfig(
                        path: path,
                        detail: "the 'mcp_servers' key uses YAML flow style; add the mootx01 entry manually."
                    )
                }
                sectionIdx = i
                break
            }
        }

        // Drop our existing entry (2-space key + >=4-space children),
        // tracking whether we are inside the mcp_servers section.
        let entryHeader = "  \(serverName):"
        var output: [String] = []
        var inSection = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let s = sectionIdx, i == s {
                inSection = true
            } else if inSection,
                      !line.trimmingCharacters(in: .whitespaces).isEmpty,
                      !line.hasPrefix(" "),
                      !line.hasPrefix("#") {
                inSection = false  // next top-level key ends the section
            }
            let trimmedEnd = line.hasSuffix(" ")
                ? String(line.reversed().drop(while: { $0 == " " }).reversed())
                : line
            if inSection, trimmedEnd == entryHeader {
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.hasPrefix("    "), !l.trimmingCharacters(in: .whitespaces).isEmpty {
                        i += 1  // child of our entry
                    } else {
                        break
                    }
                }
                continue
            }
            output.append(line)
            i += 1
        }

        if let block = replacement {
            if let pos = output.firstIndex(where: { $0.hasPrefix("mcp_servers:") }) {
                output.insert(block, at: pos + 1)
            } else {
                while let last = output.last,
                      last.trimmingCharacters(in: .whitespaces).isEmpty {
                    output.removeLast()
                }
                if !output.isEmpty { output.append("") }
                output.append("mcp_servers:")
                output.append(block)
            }
        }

        var result = output.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// Drop a `mcp_servers:` line whose section body is empty (blank lines
    /// only up to the next top-level key or EOF), plus one preceding blank
    /// separator. A section retaining any content — entries or comments —
    /// is left untouched.
    static func droppingEmptyHermesSection(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { line in
            guard line.hasPrefix("mcp_servers:") else { return false }
            let after = String(line.dropFirst("mcp_servers:".count))
                .trimmingCharacters(in: .whitespaces)
            return after.isEmpty || after.hasPrefix("#")
        }) else { return text }

        var end = idx + 1
        while end < lines.count {
            let l = lines[end]
            let blank = l.trimmingCharacters(in: .whitespaces).isEmpty
            if !blank, !l.hasPrefix(" ") { break }      // next top-level key
            if !blank { return text }                    // section still has content
            end += 1
        }
        var output = Array(lines[..<idx])
        if let last = output.last, last.trimmingCharacters(in: .whitespaces).isEmpty,
           output.count >= 2,
           !output[output.count - 2].trimmingCharacters(in: .whitespaces).isEmpty {
            output.removeLast()  // collapse the single blank separator we added
        }
        output.append(contentsOf: lines[end...])
        var result = output.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    private static func uninstallJSON(configURL: URL, serversKey: String, serverName: String) throws {
        let data = try Data(contentsOf: configURL)
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var mcpServers = root[serversKey] as? [String: Any] ?? [:]
        mcpServers.removeValue(forKey: serverName)
        if mcpServers.isEmpty {
            root.removeValue(forKey: serversKey)
        } else {
            root[serversKey] = mcpServers
        }
        let updated = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try updated.write(to: configURL, options: .atomic)
    }

    // MARK: - Continue YAML helper

    private static func installContinue(configURL: URL, binaryPath: String, httpURL: String?) throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Continue expects a minimal YAML structure for each MCP server config.
        // HTTP-capable → streamable-http with a url (shares the resident daemon);
        // otherwise the stdio command entry. Only the required fields are written;
        // the format is stable per Continue docs.
        // Trailing newline: POSIX text hygiene, and byte-conformance with the
        // Rust vertical's write_continue_yaml.
        let yaml: String
        if let httpURL {
            yaml = "type: streamable-http\nurl: \(httpURL)\n"
        } else {
            yaml = "command: \(binaryPath)\nargs: []\n"
        }
        try yaml.write(to: configURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Config URL resolution

    private static func resolveConfigURL(
        client: MCPClient,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) -> URL {
        // Local mode: Claude Code only (localConfigPath is non-nil).
        if local, let localPath = client.localConfigPath {
            return workingDirectory.appendingPathComponent(localPath, isDirectory: false)
        }
        return client.resolvedConfigURL(homeDirectory: homeDirectory)
    }
}

/// Errors raised while wiring a client's MCP config.
public enum InstallerError: Error, CustomStringConvertible {
    /// An existing config file could not be safely modified — it has content
    /// but is not in the format the chosen merge path expects, so overwriting
    /// it would destroy the user's configuration.
    case malformedConfig(path: String, detail: String)
    /// The client's config is in a format the installer cannot yet merge
    /// without corrupting it. Refused rather than clobbered.
    case unsupportedConfigFormat(format: String, client: String, path: String)

    public var description: String {
        switch self {
        case let .malformedConfig(path, detail):
            return "Refusing to modify \(path): \(detail)"
        case let .unsupportedConfigFormat(format, client, path):
            return "Cannot wire \(client): config format .\(format) at \(path) is not supported by the installer yet (writing it would corrupt the file)."
        }
    }
}
