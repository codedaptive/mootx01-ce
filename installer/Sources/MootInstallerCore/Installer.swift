// Installer.swift
//
// Swift reimplementation of the config-merge logic that was previously in
// bash + embedded Python (installer/install.sh). Writes the mootx01 MCP
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
    /// - Returns: the absolute path of the placed binary
    ///   (`installedBinaryURL`) — feed this into `install(...)` as the
    ///   client config `command`.
    /// - Throws: filesystem errors (copy, chmod, or symlink failure).
    @discardableResult
    public static func placeBinary(
        sourcePath: String,
        homeDirectory: URL
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

        // If the source already IS the installed binary (re-install run from the
        // placed copy), there is nothing to copy — removing dest would delete
        // the source itself. Skip straight to (re)perms + symlink below.
        if realSource.standardizedFileURL.path != destURL.standardizedFileURL.path {
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

        return destURL.path
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

        if client.id == "continue" {
            try installContinue(configURL: configURL, binaryPath: binaryPath)
        } else {
            try installJSON(
                configURL: configURL,
                serverName: client.serverName,
                binaryPath: binaryPath
            )
        }
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

        if client.id == "continue" {
            try? FileManager.default.removeItem(at: configURL)
        } else {
            try uninstallJSON(configURL: configURL, serverName: client.serverName)
        }
    }

    // MARK: - JSON client helpers

    private static func installJSON(
        configURL: URL,
        serverName: String,
        binaryPath: String
    ) throws {
        var root: [String: Any]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } else {
            root = [:]
        }

        // Merge: root["mcpServers"]["mootx01"] = {command, args, env}
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        mcpServers[serverName] = ["command": binaryPath, "args": [], "env": [:] as [String: String]]
        root["mcpServers"] = mcpServers

        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: configURL, options: .atomic)
    }

    private static func uninstallJSON(configURL: URL, serverName: String) throws {
        let data = try Data(contentsOf: configURL)
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        mcpServers.removeValue(forKey: serverName)
        if mcpServers.isEmpty {
            root.removeValue(forKey: "mcpServers")
        } else {
            root["mcpServers"] = mcpServers
        }
        let updated = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try updated.write(to: configURL, options: .atomic)
    }

    // MARK: - Continue YAML helper

    private static func installContinue(configURL: URL, binaryPath: String) throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Continue expects a minimal YAML structure for each MCP server config.
        // We write only the fields it requires; the format is stable per Continue docs.
        let yaml = """
        command: \(binaryPath)
        args: []
        """
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
        return homeDirectory.appendingPathComponent(client.configPath, isDirectory: false)
    }
}
