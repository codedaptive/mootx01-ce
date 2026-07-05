// Installer.swift
//
// Swift reimplementation of the config-merge logic that was previously in
// bash + embedded Python (apps/mootx01/install.sh). Writes the mootx01 MCP
// server entry into each selected client's config file.
//
// JSON clients (Claude Desktop, Claude Code, Cursor, Cline, opencode, Gemini
// CLI, Kiro, Antigravity, and others):
//   Reads the existing config and merges the appropriate entry shape. Most
//   clients use `mcpServers.<name>`; opencode uses top-level `mcp`; HTTP
//   clients use `{"type":"http","url":...}`; opencode uses `{"type":"remote",...}`.
//   Writes back atomically; a second run with the same config leaves the file
//   byte-identical.
//
// Continue (YAML):
//   Continue's per-server MCP config lives at .continue/mcpServers/mootx01.yaml.
//   The YAML is a simple two-key object; we write it directly rather than
//   round-tripping a full YAML parser.
//
// Codex (Desktop & CLI) (TOML):
//   ~/.codex/config.toml is shared by Codex CLI and Codex Desktop, so a
//   single "codex" entry covers both. The installer merges the
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

/// Outcome of `Installer.uninstall` for a JSON-format client (ADR-024 §4:
/// ownership-aware removal). Non-JSON formats (TOML, Continue/Hermes YAML)
/// do not yet carry the ownership check and always report `.removed` when a
/// prior entry existed — see the doc comment on `uninstall(...)`.
public enum UninstallOutcome: Equatable, Sendable {
    /// No config file, or no entry under the server name — nothing to do.
    case notPresent
    /// An entry existed and was removed (JSON: only when `.oursDefault`;
    /// other formats: unconditionally, pre-existing behavior).
    case removed
    /// A JSON entry existed but classified `.foreign` (ADR-024 §4) — left
    /// untouched. Carries the reason and the config path for reporting.
    case retainedForeign(reason: String, path: String)
}

/// Outcome of `Installer.dedupeDirectEntry` (ADR-024 §3: install-time
/// dedupe when a client's plugin already owns the connection).
public enum DirectEntryDedupeOutcome: Equatable, Sendable {
    /// No existing direct entry (or the config format isn't a dedupe target
    /// yet) — nothing to do.
    case none
    /// An existing direct entry was `.oursDefault`; removed so the plugin is
    /// the sole connection.
    case removedOursDefault
    /// An existing direct entry is `.foreign` (env override) — reported by
    /// name and path, never auto-removed.
    case retainedForeign(reason: String, path: String)
}

/// Writes and removes MCP server config entries for each supported client.
public enum Installer {

    // MARK: - Binary placement

    /// Copy the running `mootx01` binary into the standard install
    /// directory and put a wrapper for it onto PATH. Mirrors codegraph's
    /// install.sh: a self-contained executable lands at
    /// `<home>/.mootx01/bin/mootx01`, and `<home>/.local/bin/mootx01`
    /// exec-wrappers to it so the command resolves from any shell.
    ///
    /// This is the fix for the core installer bug: previously the
    /// installer wrote `command: <wherever the binary was run from>`
    /// into every client config, so the entry pointed at a CWD or
    /// dev-tree path. By copying to a stable location first and writing
    /// THAT absolute path into the configs, the wiring survives moving
    /// or deleting the source binary.
    ///
    /// Re-install is overwrite-safe: an existing placed binary is
    /// replaced and an existing PATH entry is rewritten.
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
    /// - Throws: filesystem errors (copy, chmod, or PATH-wrapper write failure).
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
        //    ~/.local/bin/mootx01 PATH entry, and copying that entry verbatim
        //    would land the PATH shim (historically a self-referential symlink
        //    → ELOOP; today the wrapper script) at dest, breaking every
        //    subsequent install. Resolve symlinks AND the wrapper script so we
        //    always copy the real Mach-O binary.
        let realSource = resolvePathWrapper(
            URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath())
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)

        // When force is false (default install path), skip the copy if the source
        // already IS the installed binary — removing dest would delete the source
        // itself. When force is true (upgrade path), always copy regardless of
        // path equality so a newly built binary replaces the installed one.
        // Skip straight to (re)perms + PATH wrapper when the copy is skipped.
        if force || realSource.standardizedFileURL.path != destURL.standardizedFileURL.path {
            // Remove any prior placed binary OR stale/looped symlink at dest so
            // the fresh copy lands cleanly (removeItem on a symlink unlinks it,
            // even a self-referential one).
            if fm.fileExists(atPath: destURL.path)
                || (try? fm.destinationOfSymbolicLink(atPath: destURL.path)) != nil {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: realSource, to: destURL)

            // 4. Copy every SPM resource bundle sitting beside the source binary
            //    into the install dir. A Swift executable that links a target using
            //    `Bundle.module` fatalErrors at the static-init that first touches
            //    the bundle if the `<Target>_<Target>.bundle` is not co-located with
            //    the executable. The release build emits these next to the binary;
            //    placement must carry them or the placed binary crashes on first use
            //    of any resource (e.g. moot-mgr's LatticeLib FDC data on /api/graph).
            //
            //    This is intentionally inside the copy guard: when the source resolves
            //    to the same path as the install destination (reinstall-from-placed-
            //    binary path), the bundles are already present in binDir and there is
            //    nothing to copy. Running copyResourceBundles in that case would scan
            //    binDir for *.bundle siblings, then try to copy each into binDir itself
            //    — which first removes the bundle (step 1 of the copy helper) and then
            //    fails to copy the now-deleted source, leaving the install broken.
            try copyResourceBundles(besideSource: realSource, toDir: binDir)
        }

        // 2. Mark the placed binary executable (0755). copyItem preserves
        //    the source mode, but a build product copied from a sandbox or
        //    archive may lose the bit — set it explicitly to be safe.
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destURL.path
        )

        // 3. (Re)write the PATH wrapper. Remove any existing entry first
        //    (regular file, prior wrapper, OR dangling legacy symlink).
        try fm.createDirectory(at: localBinDir, withIntermediateDirectories: true)
        try writePathWrapper(at: symlinkURL, execTarget: destURL)

        // 4. Create the same-directory proxy symlink `mootx01-proxy → mootx01`.
        //    This is a RELATIVE symlink (target is just "mootx01", not an absolute
        //    path) so the link survives home-directory moves or username changes.
        //    Placement: same directory as the binary (binDir) — load-bearing for
        //    Bundle.main resource resolution (both `mootx01` and `mootx01-proxy`
        //    must resolve to the same directory so SPM bundles are found).
        //    Clients whose MCP config schema supports only a bare command string
        //    (no separate args array) use `mootx01-proxy` as their command;
        //    ArgvDispatch then invokes the `proxy` subcommand automatically.
        let proxySymlinkURL = MootPaths.proxySymlinkURL(homeDirectory: homeDirectory)
        if fm.fileExists(atPath: proxySymlinkURL.path)
            || (try? fm.destinationOfSymbolicLink(atPath: proxySymlinkURL.path)) != nil {
            try fm.removeItem(at: proxySymlinkURL)
        }
        try fm.createSymbolicLink(atPath: proxySymlinkURL.path, withDestinationPath: "mootx01")

        return destURL.path
    }

    /// Copy the `moot-mgr` console binary into the install directory beside
    /// `mootx01` and put a wrapper for it onto PATH. Same overwrite-safe contract as
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
    /// - Throws: filesystem errors (copy, chmod, or PATH-wrapper write failure).
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
        try writePathWrapper(at: symlinkURL, execTarget: destURL)

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
        // Already co-located — e.g. the macOS .pkg placed the binary AND its
        // bundles into the install dir, and we're "placing" onto that same dir.
        // A per-bundle remove-then-copy would delete the bundle and then fail to
        // copy it from itself ("no such file"), which aborted moot-mgr install.
        if sourceDir.standardizedFileURL.path == destDir.standardizedFileURL.path {
            return
        }
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

    /// Marker comment embedded in every PATH wrapper this installer writes.
    /// `resolvePathWrapper` keys on it to distinguish our wrapper from an
    /// arbitrary user script that happens to sit at the PATH entry.
    static let pathWrapperMarker = "mootx01 PATH wrapper"

    /// Write the PATH entry as a tiny `exec` wrapper script rather than a
    /// symlink.
    ///
    /// A symlink here is broken by construction: `Bundle.main` derives the
    /// executable's directory from the path it was INVOKED as, without
    /// resolving a symlink at that path — so a
    /// `~/.local/bin/mootx01 → ~/.mootx01/bin/mootx01` symlink makes every
    /// `Bundle.module` target (LatticeLib, EideticLib, swift-crypto) look for
    /// its `<Target>_<Target>.bundle` in `~/.local/bin`, where nothing is
    /// installed, and fatalError on the first resource touch (the v1.0.9
    /// installed-CLI crash: `serve` booted, any classify/search path died).
    /// `exec "<real>" "$@"` re-launches with argv[0] = the install dir, so
    /// the bundles co-located by `copyResourceBundles` resolve correctly.
    ///
    /// Replaces whatever sits at `path` (prior wrapper, legacy symlink —
    /// including a dangling one — or stray file), preserving the ln -sf
    /// overwrite semantics the symlink had.
    static func writePathWrapper(at path: URL, execTarget: URL) throws {
        let fm = FileManager.default
        // lstat semantics: a dangling legacy symlink reports false from
        // fileExists but still blocks the write.
        if (try? fm.destinationOfSymbolicLink(atPath: path.path)) != nil
            || fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
        let script = """
        #!/bin/sh
        # \(pathWrapperMarker) — exec the real binary from its install dir so
        # SPM resource bundles (<Target>_<Target>.bundle) resolve beside the
        # executable. A symlink here breaks that lookup. Written by
        # Installer.writePathWrapper; install.sh writes the same shape.
        exec "\(execTarget.path)" "$@"
        """
        try script.write(to: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    /// If `url` is a PATH wrapper written by `writePathWrapper` (or
    /// install.sh's identical shape), return the exec target it points at;
    /// otherwise return `url` unchanged. Symlink resolution handles the
    /// legacy layout; this handles the wrapper layout — without it, an
    /// install run with `sourcePath` = the PATH entry would copy the shell
    /// script over the real binary.
    static func resolvePathWrapper(_ url: URL) -> URL {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 512),
              let text = String(data: head, encoding: .utf8),
              text.hasPrefix("#!"),
              text.contains(pathWrapperMarker),
              let execLine = text.split(separator: "\n").last(where: { $0.hasPrefix("exec \"") }),
              let target = execLine.split(separator: "\"").dropFirst().first
        else { return url }
        return URL(fileURLWithPath: String(target))
    }

    /// Remove the placed binary and its PATH wrapper. Inverse of
    /// `placeBinary`. Safe to call when nothing was installed.
    ///
    /// Removes `<home>/.local/bin/mootx01` (the PATH wrapper) and the whole
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

        // Remove both PATH wrappers (mootx01 + moot-mgr; removeItem also
        // clears a legacy symlink). The install root
        // rmrf below takes the binaries and logs; the PATH entries live under
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
                        binaryPath: binaryPath,
                        url: client.supportsLocalHTTP ? daemonURL : nil
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

    /// ADR-024 §3/§4: when `client`'s plugin already owns the MCP connection
    /// (detected by the caller via `PluginDetector`), the CLI installer must
    /// skip writing a competing direct entry AND clean up any direct entry a
    /// PRIOR install wrote — but only when that entry is confirmed
    /// `.oursDefault` (§4). A `.foreign` entry (env override, e.g. a
    /// development rig) is reported and left untouched. Callers still place
    /// the binary/PATH/daemon as normal — the plugin requires the binary —
    /// this only governs the direct client config entry.
    ///
    /// Scoped to JSON-format configs today (the only format any currently
    /// plugin-owned client — Claude Code — uses); other formats return
    /// `.none` unconditionally.
    ///
    /// - Parameters:
    ///   - client: the client whose direct entry to check (typically
    ///     Claude Code, the only client with a live plugin today).
    ///   - homeDirectory: user's home directory. Inject in tests.
    ///   - workingDirectory: CWD at install time (for --local Claude Code).
    ///   - local: when true and client is Claude Code, target `.mcp.json`.
    /// - Returns: `.none` (nothing to do), `.removedOursDefault` (cleaned
    ///   up), or `.retainedForeign` (reported, left untouched).
    /// - Throws: filesystem or JSON errors.
    @discardableResult
    public static func dedupeDirectEntry(
        client: MCPClient,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) throws -> DirectEntryDedupeOutcome {
        let configURL = resolveConfigURL(
            client: client,
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            local: local
        )
        guard FileManager.default.fileExists(atPath: configURL.path) else { return .none }
        let ext = configURL.pathExtension.lowercased()
        guard ext == "json" || ext == "jsonc" else { return .none }

        switch try uninstallJSON(
            configURL: configURL,
            serversKey: client.jsonServersKey,
            serverName: client.serverName
        ) {
        case .notPresent:
            return .none
        case .removed:
            return .removedOursDefault
        case let .retainedForeign(reason, path):
            return .retainedForeign(reason: reason, path: path)
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
    /// - Returns: the outcome (ADR-024 §4). JSON-format clients are
    ///   ownership-aware: a `.foreign` entry (env override — e.g. a
    ///   development rig) is reported and left untouched rather than
    ///   removed. Other formats (TOML, Continue/Hermes YAML) remove
    ///   unconditionally, matching prior behavior — they are not yet
    ///   ownership-checked (see MCPEntryOwnership.swift's doc comment).
    /// - Throws: filesystem or JSON errors.
    @discardableResult
    public static func uninstall(
        client: MCPClient,
        homeDirectory: URL,
        workingDirectory: URL,
        local: Bool
    ) throws -> UninstallOutcome {
        let configURL = resolveConfigURL(
            client: client,
            homeDirectory: homeDirectory,
            workingDirectory: workingDirectory,
            local: local
        )

        guard FileManager.default.fileExists(atPath: configURL.path) else { return .notPresent }

        if client.id == "continue" {
            // §4.2: timestamped backup before modification — the per-server
            // file is deleted outright; the backup preserves it.
            try backupExisting(at: configURL)
            try? FileManager.default.removeItem(at: configURL)
            return .removed
        }

        switch configURL.pathExtension.lowercased() {
        case "toml":
            // Codex config.toml — the old path routed TOML through the JSON
            // remover, whose parse failed and silently no-opped, leaving the
            // [mcp_servers.mootx01] table behind forever. Not yet
            // ownership-checked (§4) — removes unconditionally.
            try backupExisting(at: configURL)
            try removeFromTOMLConfig(at: configURL, serverName: client.serverName)
            return .removed
        case "json", "jsonc":
            return try uninstallJSON(
                configURL: configURL,
                serversKey: client.jsonServersKey,
                serverName: client.serverName
            )
        default:
            if client.id == "hermes" {
                try backupExisting(at: configURL)
                try removeFromHermesYAML(at: configURL, serverName: client.serverName)
                return .removed
            }
            // Unknown formats: nothing was ever written by us; leave alone.
            return .notPresent
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
    ///   - useProxyBridge    → `{"command":proxySymlinkPath,"env":{}}` (bare command, no args —
    ///                         ArgvDispatch maps argv0 "mootx01-proxy" to the proxy subcommand)
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
        if client.id == "opencode" && client.supportsLocalHTTP {
            // Schema-verified (https://opencode.ai/config.json, McpRemoteConfig):
            // remote servers are { "type": "remote", "url": … } under the
            // top-level "mcp" key — not the mcpServers/"http" convention.
            // The fixed loopback endpoint is the accepted CE posture (see
            // docs(secfix/ce-loopback-impersonation)); endpoint auth lands
            // with EE v1.1 off-localhost hosting.
            entry = ["type": "remote", "url": daemonURL]
        } else if client.supportsLocalHTTP {
            entry = client.httpEntryIncludesType
                ? ["type": "http", "url": daemonURL]
                : ["url": daemonURL]
        } else if client.useProxyBridge {
            // Use the proxy symlink (`mootx01-proxy`) as the bare command — no
            // `args` needed because ArgvDispatch routes argv0 "mootx01-proxy" to
            // the `proxy` subcommand automatically. This form works for clients
            // whose config schema cannot express a separate args array and is
            // cleaner than the two-token {"command":…,"args":["proxy"]} form.
            // The symlink is placed in the same directory as the binary by
            // `placeBinary()` so Bundle.main resource resolution is identical.
            let proxyPath = Self.proxyBinaryPath(from: binaryPath)
            entry = ["command": proxyPath,
                     "env": [:] as [String: String]]
        } else {
            // Headless stdio: client spawns an ephemeral serve process per call.
            // No telemetry, no moot-mgr monitoring, no single-writer guarantee.
            entry = ["command": binaryPath, "args": [], "env": [:] as [String: String]]
        }

        var root: [String: Any]
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL).strippingLeadingUTF8BOM
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
    ///   - useProxyBridge    → `command = "<proxySymlinkPath>"` (bare, no args)
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
            // Same proxy-symlink rationale as mergeIntoJSONConfig: bare command
            // pointing at mootx01-proxy, no args needed (ArgvDispatch handles routing).
            let proxyPath = Self.proxyBinaryPath(from: binaryPath)
            block.append("command = \"\(proxyPath)\"")
        } else {
            block.append("command = \"\(binaryPath)\"")
            block.append("args = []")
        }
        let newTable = block.joined(separator: "\n")

        var existingText = ""
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL).strippingLeadingUTF8BOM
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
    ///
    /// When `url` is non-nil the entry is written as a URL entry
    /// (`url: <url>`). When `url` is nil a command entry is written
    /// (`command: <binaryPath>\nargs: []`) to avoid trusting a fixed
    /// unauthenticated loopback address (ADR-LOOPBACKHTTP-001).
    public static func mergeIntoHermesYAML(
        at configURL: URL,
        serverName: String,
        binaryPath: String,
        url: String?
    ) throws {
        let existing: String
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL).strippingLeadingUTF8BOM
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
        let block: String
        if let url {
            block = "  \(serverName):\n    url: \(url)"
        } else {
            block = "  \(serverName):\n    command: \(binaryPath)\n    args: []"
        }
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

    /// Backward-compatible overload for call sites that always supply a URL.
    /// Forwards to the primary implementation with `binaryPath: ""` and a
    /// non-optional url (the empty binaryPath is unused when url is non-nil).
    public static func mergeIntoHermesYAML(
        at configURL: URL,
        serverName: String,
        url: String
    ) throws {
        try mergeIntoHermesYAML(
            at: configURL,
            serverName: serverName,
            binaryPath: "",
            url: url
        )
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

    /// Ownership-aware JSON removal (ADR-024 §4). A `.foreign` entry (env
    /// override — e.g. a development rig pointed at a non-default data dir
    /// or estate) is reported and left untouched; only a `.oursDefault`
    /// entry is actually removed from the file. Absent file content, absent
    /// entry, or an unparseable file all resolve to `.notPresent` — there
    /// was nothing this installer could safely act on.
    /// Derives the proxy symlink path from the installed binary path.
    ///
    /// The proxy symlink lives in the same directory as the binary and is
    /// always named `mootx01-proxy`. Given `/path/to/.mootx01/bin/mootx01`,
    /// returns `/path/to/.mootx01/bin/mootx01-proxy`.
    ///
    /// This computation is purely path arithmetic — it does NOT check whether
    /// the symlink currently exists on disk (callers that write the entry
    /// first and create the symlink later follow the same contract as the
    /// `placeBinary` step).
    private static func proxyBinaryPath(from binaryPath: String) -> String {
        URL(fileURLWithPath: binaryPath)
            .deletingLastPathComponent()
            .appendingPathComponent("mootx01-proxy", isDirectory: false)
            .path
    }

    private static func uninstallJSON(
        configURL: URL, serversKey: String, serverName: String
    ) throws -> UninstallOutcome {
        let data = try Data(contentsOf: configURL).strippingLeadingUTF8BOM
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .notPresent
        }
        var mcpServers = root[serversKey] as? [String: Any] ?? [:]
        guard let entry = mcpServers[serverName] as? [String: Any] else {
            return .notPresent
        }
        if case let .foreign(reason) = MCPEntryClassifier.classify(entry: entry) {
            return .retainedForeign(reason: reason, path: configURL.path)
        }

        // §4.2: timestamped backup immediately before the write that actually
        // modifies the file — not taken for entries left untouched above.
        try backupExisting(at: configURL)

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
        return .removed
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
