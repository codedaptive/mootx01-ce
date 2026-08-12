// EnableCommand.swift
//
// `mootx01 enable <feature>` / `mootx01 disable <feature>`
//
// Toggles optional features.
//
//   memory-tool      Anthropic memory_20250818 adapter — governed /memories backend.
//                    Toggles MOOTX01_MEMORY_TOOL in the daemon launchd plist.
//
//   harness-memory   Harness Memory Mode — routes Claude Code project memories into
//                    the MOOTx01 estate instead of writing to ~/.claude/projects/*/memory/.
//                    Edits ~/.claude/settings.json (backup first), installs a PreToolUse
//                    hook, and merges a teaching block into ~/.claude/CLAUDE.md.
//                    Consent required; --yes skips the interactive prompt.
//                    On enable: offers one-time ingest of existing project memories
//                    (--ingest-all ingests all without per-project prompts).
//                    On disable: offers to restore estate memories back to disk
//                    (--restore-all restores all, --no-restore skips).

import ArgumentParser
import Foundation
import MootInstallerCore

struct EnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable",
        abstract: "Enable an optional feature on the mootx01 daemon.",
        discussion: """
        Available features:
          memory-tool      Anthropic memory_20250818 adapter — governed /memories backend
          harness-memory   Harness Memory Mode — routes Claude Code memories into the estate
          codex-memory     Codex lifecycle integration (augment or moot-only)
        """
    )

    @Argument(help: "Feature to enable (memory-tool, harness-memory, or codex-memory).")
    var feature: String

    @Flag(name: .long, help: "Skip interactive consent prompts (for scripted installs).")
    var yes: Bool = false

    @Flag(name: .customLong("ingest-all"),
          help: "Ingest ALL existing project memories without per-project prompts (harness-memory only).")
    var ingestAll: Bool = false

    @Option(name: .long, help: "Codex memory mode: augment or moot-only (codex-memory only).")
    var mode: String = "augment"

    @Flag(name: .customLong("automatic-recall"),
          help: "Opt in to bounded UserPromptSubmit recall (codex-memory only).")
    var automaticRecall: Bool = false

    func run() async throws {
        switch feature {
        case "memory-tool":
            try await toggleFeature(envVar: "MOOTX01_MEMORY_TOOL", value: "1", label: "memory tool")

        case "harness-memory":
            try await enableHarnessMemory()

        case "codex-memory":
            try await enableCodexMemory()

        default:
            print("Unknown feature: \(feature)")
            print("Available features: memory-tool, harness-memory, codex-memory")
            throw ExitCode.failure
        }
    }

    // MARK: - codex-memory enable

    private func enableCodexMemory() async throws {
        guard let selectedMode = CodexMemoryMode(rawValue: mode) else {
            print("Invalid --mode: \(mode). Use augment or moot-only.")
            throw ExitCode.failure
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        let dataDir = MootPaths.resolveDataDirectory(environment: env, homeDirectory: home)
        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        guard await LiveDaemonClient(port: port).ping() else {
            print("  ✗ MOOTx01 daemon not reachable at port \(port); refusing to enable Codex memory.")
            throw ExitCode.failure
        }

        let configURL = CodexMemoryPaths.codexConfig(homeDirectory: home, environment: env)
        var codexText = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
        let previous = CodexMemoryStore.load(homeDirectory: home)

        if !yes {
            print("""

            Codex Memory will enable MOOTx01 lifecycle hooks with private per-session state.
            It never reads Codex transcripts or edits generated files under ~/.codex/memories.
            Mode: \(selectedMode.rawValue)
            Automatic recall: \(automaticRecall ? "enabled (bounded and visible)" : "disabled")
            \(selectedMode == .mootOnly ? "Codex native memory generation/use will be disabled after a config backup." : "Codex native memory settings will be left unchanged.")

            Proceed? [y/N]
            """, terminator: "")
            guard readLine()?.lowercased().hasPrefix("y") == true else {
                print("Aborted.")
                throw ExitCode.failure
            }
        }

        // Restore only the keys changed by an earlier moot-only enable before
        // switching modes. Never restore the whole file over later user edits.
        if previous?.mode == .mootOnly,
           let snapshot = previous?.nativeMemorySnapshot,
           selectedMode == .augment {
            codexText = CodexNativeMemorySettings.restore(snapshot, in: codexText)
            try writeCodexConfig(codexText, to: configURL)
        }

        var snapshot: [String: CodexPriorSetting]?
        var backupPath: String?
        if selectedMode == .mootOnly {
            snapshot = previous?.mode == .mootOnly
                ? previous?.nativeMemorySnapshot
                : CodexNativeMemorySettings.snapshot(in: codexText)
            if FileManager.default.fileExists(atPath: configURL.path) {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                let backup = configURL.deletingLastPathComponent().appendingPathComponent(
                    "config.toml.mootx01-memory-bak-\(formatter.string(from: Date()))")
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try FileManager.default.copyItem(at: configURL, to: backup)
                }
                backupPath = backup.path
            }
            codexText = CodexNativeMemorySettings.disableNativeMemories(in: codexText)
            try writeCodexConfig(codexText, to: configURL)
        }

        let configuration = CodexMemoryConfiguration(
            mode: selectedMode,
            automaticRecall: automaticRecall,
            nativeMemorySnapshot: snapshot,
            codexConfigBackupPath: backupPath ?? previous?.codexConfigBackupPath
        )
        try CodexMemoryStore.save(configuration, homeDirectory: home)
        print("  ✓ Codex Memory enabled in \(selectedMode.rawValue) mode")
        print("  ✓ automatic recall \(automaticRecall ? "enabled" : "disabled")")
        if selectedMode == .augment {
            print("  · Codex native memories left unchanged")
        } else {
            print("  ✓ Codex native memory generation/use disabled with reversible key-level snapshot")
        }
        print("  · Run `mootx01 install --target codex --mode plugin` to refresh plugin hooks and deduplicate MCP ownership.")
    }

    private func writeCodexConfig(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - harness-memory enable

    private func enableHarnessMemory() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = MootPaths.globalClaudeSettingsURL(homeDirectory: home)
        let claudeMDURL = HarnessMemoryPaths.globalCLAUDEMDURL(homeDirectory: home)
        let hookURL = HarnessMemoryPaths.hookScriptURL(homeDirectory: home)
        let binaryPath = MootPaths.installedBinaryURL(homeDirectory: home).path

        // Daemon reachability check — Harness Memory without an estate is
        // worse than useless (writes blocked with nowhere to go).
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: home
        )
        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        let daemon = LiveDaemonClient(port: port)
        guard await daemon.ping() else {
            print("  ✗ MOOTx01 daemon not reachable at port \(port).")
            print("  Run `mootx01 serve` or check that the daemon is installed and running.")
            print("  Harness Memory Mode without a reachable estate would leave the session")
            print("  with no memory at all — refusing to enable.")
            throw ExitCode.failure
        }

        // Consent — explain the changes before touching anything.
        if !yes {
            print("""

            Harness Memory Mode will make these changes:

              1. ~/.claude/settings.json  — set "autoMemoryEnabled": false
                                          — add a PreToolUse hook entry
                 (backup written before edit)
              2. \(hookURL.path)
                 installed, made executable
              3. ~/.claude/CLAUDE.md  — append memory-governance block
                 (created if absent)

            Project memory writes will be intercepted and filed in the MOOTx01 estate.
            Disable with `mootx01 disable harness-memory` to reverse all changes.

            Proceed? [y/N]
            """, terminator: "")
            guard let answer = readLine(), answer.lowercased().hasPrefix("y") else {
                print("Aborted.")
                throw ExitCode.failure
            }
        }

        // Apply changes.
        let changed = try HarnessMemorySettings.enable(settingsURL: settingsURL, homeDirectory: home)
        if changed {
            print("  ✓ ~/.claude/settings.json updated (backup written)")
        } else {
            print("  · ~/.claude/settings.json already configured (no changes)")
        }

        try HarnessMemoryHook.install(at: hookURL, binaryPath: binaryPath)
        print("  ✓ hook installed: \(hookURL.path)")

        try HarnessMemoryCLAUDE.enable(at: claudeMDURL)
        print("  ✓ memory-governance block merged into ~/.claude/CLAUDE.md")

        print("  ✓ Harness Memory Mode enabled")
        print()

        // Ingest offer — scan existing project memories.
        await runIngestOffer(homeDirectory: home, daemon: daemon)
    }

    private func runIngestOffer(homeDirectory: URL, daemon: some DaemonClient) async {
        let projectMemories = HarnessMemoryIngest.scanProjects(homeDirectory: homeDirectory)
        guard !projectMemories.isEmpty else {
            print("No existing project memories found — nothing to ingest.")
            return
        }

        print("Found memories to ingest:")
        for (slug, files) in projectMemories.sorted(by: { $0.key < $1.key }) {
            print("  \(slug): \(files.count) file(s)")
        }
        print()
        print("Note: existing project memories will be MOVED into the estate (source files")
        print("removed after confirmed writes). Estate machinery grades claims over time;")
        print("old secrets should be withdrawn or re-filed restricted after ingest.")
        print()

        // Check whether this is a re-enable (any files already ingested before).
        let isReEnable = false // First enable: not a re-enable sweep.

        var totalFiled = 0
        var totalSkipped = 0
        var totalFailed = 0

        for (slug, files) in projectMemories.sorted(by: { $0.key < $1.key }) {
            let shouldIngest: Bool
            if ingestAll {
                shouldIngest = true
            } else {
                print("Ingest \(files.count) file(s) from '\(slug)'? [y/N] ", terminator: "")
                let answer = readLine() ?? ""
                shouldIngest = answer.lowercased().hasPrefix("y")
            }
            guard shouldIngest else {
                print("  Skipped '\(slug)'")
                totalSkipped += files.count
                continue
            }

            for fileURL in files {
                let result = await HarnessMemoryIngest.ingestFile(
                    fileURL, projectSlug: slug, isReEnable: isReEnable, daemon: daemon
                )
                switch result.outcome {
                case .filed, .revived:
                    totalFiled += 1
                case .skipped(let reason):
                    print("  skip \(result.fileName): \(reason)")
                    totalSkipped += 1
                case .failed(let reason):
                    print("  fail \(result.fileName): \(reason)")
                    totalFailed += 1
                }
            }
            HarnessMemoryIngest.removeEmptyMemoryDir(projectSlug: slug, homeDirectory: homeDirectory)
        }

        print()
        print("Ingest complete: filed \(totalFiled), skipped \(totalSkipped), failed \(totalFailed)")
    }
}

struct DisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Disable an optional feature on the mootx01 daemon.",
        discussion: """
        Available features:
          memory-tool      Anthropic memory_20250818 adapter — governed /memories backend
          harness-memory   Harness Memory Mode — routes Claude Code memories into the estate
          codex-memory     Codex lifecycle integration and native-memory posture
        """
    )

    @Argument(help: "Feature to disable (memory-tool, harness-memory, or codex-memory).")
    var feature: String

    @Flag(name: .long, help: "Skip interactive prompts.")
    var yes: Bool = false

    @Flag(name: .customLong("restore-all"),
          help: "Restore ALL estate memories back to disk without per-project prompts.")
    var restoreAll: Bool = false

    @Flag(name: .customLong("no-restore"),
          help: "Skip the restore offer entirely on disable.")
    var noRestore: Bool = false

    func run() async throws {
        switch feature {
        case "memory-tool":
            try await toggleFeature(envVar: "MOOTX01_MEMORY_TOOL", value: "0", label: "memory tool")

        case "harness-memory":
            try await disableHarnessMemory()

        case "codex-memory":
            try disableCodexMemory()

        default:
            print("Unknown feature: \(feature)")
            print("Available features: memory-tool, harness-memory, codex-memory")
            throw ExitCode.failure
        }
    }

    private func disableCodexMemory() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        guard var feature = CodexMemoryStore.load(homeDirectory: home), feature.enabled else {
            print("  · Codex Memory is already disabled")
            return
        }
        if feature.mode == .mootOnly, let snapshot = feature.nativeMemorySnapshot {
            let configURL = CodexMemoryPaths.codexConfig(homeDirectory: home, environment: env)
            let current = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
            let restored = CodexNativeMemorySettings.restore(snapshot, in: current)
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try restored.write(to: configURL, atomically: true, encoding: .utf8)
            print("  ✓ restored only the Codex native-memory keys changed by moot-only mode")
        }
        feature.enabled = false
        feature.automaticRecall = false
        feature.nativeMemorySnapshot = nil
        try CodexMemoryStore.save(feature, homeDirectory: home)
        print("  ✓ Codex Memory disabled; generated Codex memory files were not modified")
    }

    // MARK: - harness-memory disable

    private func disableHarnessMemory() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = MootPaths.globalClaudeSettingsURL(homeDirectory: home)
        let claudeMDURL = HarnessMemoryPaths.globalCLAUDEMDURL(homeDirectory: home)
        let hookURL = HarnessMemoryPaths.hookScriptURL(homeDirectory: home)

        // Reverse the settings changes.
        let changed = try HarnessMemorySettings.disable(settingsURL: settingsURL, homeDirectory: home)
        if changed {
            print("  ✓ ~/.claude/settings.json restored (auto-memory re-enabled, hook removed)")
        } else {
            print("  · ~/.claude/settings.json: harness-memory was not active (no changes)")
        }

        try HarnessMemoryHook.remove(at: hookURL)
        print("  ✓ hook removed: \(hookURL.path)")

        try HarnessMemoryCLAUDE.disable(at: claudeMDURL)
        print("  ✓ memory-governance block removed from ~/.claude/CLAUDE.md")

        print("  ✓ Harness Memory Mode disabled")

        // Restore offer.
        guard !noRestore else { return }

        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: home
        )
        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        let daemon = LiveDaemonClient(port: port)

        guard await daemon.ping() else {
            print()
            print("Note: daemon not reachable — cannot offer estate restore.")
            print("Estate memories remain in the estate and can be recalled with moot_memory_search.")
            return
        }

        print()
        await runRestoreOffer(homeDirectory: home, daemon: daemon)
    }

    private func runRestoreOffer(homeDirectory: URL, daemon: some DaemonClient) async {
        // Discover which project slugs have estate memories to restore.
        // Query both harness-import/* and harness/* location prefixes.
        print("Checking estate for memories to restore...")
        guard !restoreAll && !yes else {
            // Non-interactive: restore everything found.
            let results = await HarnessMemoryRestore.restore(
                projectSlugs: ["*"],  // wildcard: restore will query all slugs
                homeDirectory: homeDirectory,
                daemon: daemon,
                now: Date()
            )
            summarizeRestore(results)
            return
        }

        // Interactive: ask per project.
        // For simplicity in the interactive path, restore all slugs the user
        // confirms. A full slug-discovery pass (querying the estate for known
        // slugs) is out of scope; offer a catch-all prompt instead.
        print("Restore estate memories back to disk? [y/N] ", terminator: "")
        let answer = readLine() ?? ""
        guard answer.lowercased().hasPrefix("y") else {
            print("No restore performed. Estate memories remain available via moot_memory_search.")
            return
        }

        let results = await HarnessMemoryRestore.restore(
            projectSlugs: ["*"],
            homeDirectory: homeDirectory,
            daemon: daemon,
            now: Date()
        )
        summarizeRestore(results)
    }

    private func summarizeRestore(_ results: [RestoreResult]) {
        var restored = 0
        var skipped = 0
        var failed = 0
        for r in results {
            switch r.outcome {
            case .restored: restored += 1
            case .skipped: skipped += 1
            case .failed: failed += 1
            }
        }
        print("Restore complete: restored \(restored), skipped \(skipped), failed \(failed)")
    }
}

/// Set an environment variable in the daemon's launchd plist and restart.
private func toggleFeature(envVar: String, value: String, label: String) async throws {
    let enabled = value != "0"
    let verb = enabled ? "Enabling" : "Disabling"
    print("\(verb) \(label)...")

    #if os(macOS)
    let home = FileManager.default.homeDirectoryForCurrentUser
    let plistURL = MootPaths.daemonPlistURL(homeDirectory: home)
    let plistPath = plistURL.path
    guard FileManager.default.fileExists(atPath: plistPath) else {
        print("  ✗ daemon plist not found at \(plistPath)")
        print("  Run `mootx01 install` first.")
        throw ExitCode.failure
    }

    // Read the plist, update the EnvironmentVariables dict, write back.
    guard var plist = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else {
        print("  ✗ could not read plist")
        throw ExitCode.failure
    }

    var env = plist["EnvironmentVariables"] as? [String: String] ?? [:]
    if enabled {
        env[envVar] = value
    } else {
        env.removeValue(forKey: envVar)
    }
    plist["EnvironmentVariables"] = env

    let data = try PropertyListSerialization.data(
        fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: URL(fileURLWithPath: plistPath))

    // Restart the daemon so it picks up the new env.
    let uid = getuid()
    let domain = "gui/\(uid)"
    let serviceLabel = MootPaths.daemonLabel

    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "\(domain)/\(serviceLabel)"]
    try? bootout.run()
    bootout.waitUntilExit()

    // Brief pause for clean shutdown.
    try await Task.sleep(for: .seconds(1))

    let bootstrap = Process()
    bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootstrap.arguments = ["bootstrap", domain, plistPath]
    try bootstrap.run()
    bootstrap.waitUntilExit()

    if bootstrap.terminationStatus == 0 {
        let status = enabled ? "enabled" : "disabled"
        print("  ✓ \(label) \(status) — daemon restarted")
    } else {
        print("  ✗ daemon restart failed (exit \(bootstrap.terminationStatus))")
        throw ExitCode.failure
    }

    #else
    // Linux/Windows: write to a config file instead of launchd plist.
    let home = FileManager.default.homeDirectoryForCurrentUser
    let configDir = home.appendingPathComponent(".mootx01").path
    let configPath = configDir + "/features.env"
    var lines: [String] = []
    if FileManager.default.fileExists(atPath: configPath),
       let content = try? String(contentsOfFile: configPath, encoding: .utf8) {
        lines = content.components(separatedBy: "\n").filter {
            !$0.hasPrefix("\(envVar)=")
        }
    }
    if enabled {
        lines.append("\(envVar)=\(value)")
    }
    let content = lines.joined(separator: "\n") + "\n"
    try? FileManager.default.createDirectory(
        atPath: configDir, withIntermediateDirectories: true)
    try content.write(toFile: configPath, atomically: true, encoding: .utf8)
    let status = enabled ? "enabled" : "disabled"
    print("  ✓ \(label) \(status)")
    print("  Restart the daemon for the change to take effect.")
    #endif
}
