// SetupViewModel.swift
//
// Drives the setup assistant: detects installed MCP clients, tracks
// user selection, runs wiring, and reports results. All detection and
// wiring delegates to MootInstallerCore — this class is a thin
// @Observable wrapper that bridges the library to SwiftUI.

import Foundation
import MootInstallerCore

/// The phases the setup assistant walks through.
enum SetupPhase: Equatable {
    case detecting
    case selecting
    case installing
    case complete
    case error(String)
}

/// One row in the client list — wraps MCPClient with selection state.
struct ClientItem: Identifiable {
    let client: MCPClient
    var isSelected: Bool
    let isDetected: Bool
    let isAlreadyWired: Bool

    var id: String { client.id }
}

@MainActor
@Observable
final class SetupViewModel {

    // MARK: - Published state

    var phase: SetupPhase = .detecting
    var clients: [ClientItem] = []
    var results: [String] = []
    var skipped: [String] = []

    /// Integration depth the user picks (Server only / Skills / Full plugin).
    /// Passed to `mootx01 install --mode`. Defaults to the fullest integration,
    /// but the user chooses — silently forcing one depth produced installs the
    /// user did not ask for.
    var depth: InstallDepth = .default

    /// Set once the silent background convergence pass (see `detect()`'s
    /// doc comment) finishes. Not surfaced in the UI today — this app has
    /// no persistent log view — but observable for tests and for a future
    /// UI hook, and worth keeping distinct from `results`/`skipped` (the
    /// interactive "Connect" flow's own outcome) so the two never conflate.
    private(set) var convergenceOutcome: String?

    // MARK: - Derived

    /// At least one client is selected and not yet wired.
    var canInstall: Bool {
        clients.contains { $0.isSelected }
    }

    var detectedCount: Int {
        clients.filter(\.isDetected).count
    }

    // MARK: - Private

    private let home: URL
    private let binaryPath: String
    private let daemonURL: String

    // MARK: - Init

    init() {
        self.home = FileManager.default.homeDirectoryForCurrentUser

        // Resolve the placed binary path. The .pkg postinstall script
        // places the binary before launching the setup assistant, so it
        // should be at the standard location.
        let placed = MootPaths.installedBinaryURL(homeDirectory: home)
        if FileManager.default.fileExists(atPath: placed.path) {
            self.binaryPath = placed.path
        } else {
            // Fallback: maybe running from a dev build — use the running
            // executable's own path.
            self.binaryPath = Bundle.main.executablePath ?? placed.path
        }

        // Resolve the daemon URL from the port file (if daemon is running)
        // or fall back to the default.
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: home
        )
        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        self.daemonURL = "http://127.0.0.1:\(port)"
    }

    // MARK: - Actions

    /// Scan for installed MCP clients. Called on appear.
    func detect() {
        phase = .detecting
        let supported = MCPClients.supported
        clients = supported.map { client in
            let detected = client.isPresent(homeDirectory: home)
            let wired = client.wired(homeDirectory: home)
            return ClientItem(
                client: client,
                // Pre-select detected clients that aren't already wired.
                isSelected: detected && !wired,
                isDetected: detected,
                isAlreadyWired: wired
            )
        }
        phase = .selecting

        // Wave 6, Defect B: the .pkg postinstall script launches THIS app
        // as its only user-context step (root cannot safely write to the
        // console user's ~/.claude directly) — see
        // distribution/macos/scripts/postinstall's "Launch setup assistant"
        // section. Before this fix, converging an EXISTING install (plugin
        // package rematerialization, ADR-024 Wave 3 Defect 1; permission
        // tier migration, Bob's 2026-07-04 ruling) only ever happened
        // inside `install()`, which only runs for clients the user
        // explicitly checked — and `detect()` above deliberately
        // pre-deselects already-wired clients (correctly: an upgrade
        // should not re-prompt for a connection that's already fine). The
        // combination meant a machine upgraded via .pkg with Claude Code
        // already wired (Bob's exact case) got NO convergence at all
        // unless the user happened to check an already-wired client
        // anyway and click Connect — clicking "Skip", or simply having
        // nothing new to select, silently skipped `mootx01 install`
        // entirely, stranding the plugin package and its permission
        // tiering exactly like Defect A did before that fix.
        //
        // Fix: run `mootx01 install --target <already-wired-ids> --yes`
        // silently in the background the moment detection completes,
        // independent of anything the user does next (Skip, Connect, or
        // leaving the window open). This is "prior-choice preservation":
        // already-wired clients are re-converged without re-prompting;
        // the interactive selection flow below remains reserved for
        // genuinely new connections. No-ops when nothing is already
        // wired (a first install has nothing to converge).
        convergeAlreadyWired()
    }

    /// See `detect()`'s call-site doc comment. Extracted as a pure
    /// function so the targeting decision is unit-testable without
    /// spawning the `mootx01` subprocess.
    nonisolated static func convergenceTargetIDs(for clients: [ClientItem]) -> [String] {
        clients.filter(\.isAlreadyWired).map(\.client.id)
    }

    private func convergeAlreadyWired() {
        let ids = Self.convergenceTargetIDs(for: clients)
        guard !ids.isEmpty else { return }
        let displayNames = clients.filter(\.isAlreadyWired).map(\.client.displayName)
        let launchPath = binaryPath
        let mode = depth.rawValue
        // Preserve prior vault posture (#5): read the daemon plist's
        // MOOTX01_VAULT value. If the user previously chose --vault-off
        // (MOOTX01_VAULT=0), pass --vault-off to the convergence install
        // so it doesn't silently re-enable vault tools.
        let vaultOff = Self.readDaemonVaultPosture(home: home)
        Task {
            let (converged, failed) = await Self.runInstall(
                launchPath: launchPath, ids: ids.joined(separator: ","), mode: mode, names: displayNames, vaultOff: vaultOff)
            if failed.isEmpty {
                self.convergenceOutcome = "converged: \(converged.joined(separator: ", "))"
            } else {
                self.convergenceOutcome = "convergence issue: \(failed.joined(separator: "; "))"
                print("Mootx01Setup: background convergence for \(ids) reported: \(failed)")
            }
        }
    }

    /// Toggle selection for a client.
    func toggle(_ id: String) {
        guard let idx = clients.firstIndex(where: { $0.id == id }) else { return }
        clients[idx].isSelected.toggle()
    }

    /// Select all detected clients.
    func selectAll() {
        for i in clients.indices where clients[i].isDetected {
            clients[i].isSelected = true
        }
    }

    /// Wire the selected clients.
    func install() {
        phase = .installing
        results = []
        skipped = []

        let selected = clients.filter(\.isSelected)
        guard !selected.isEmpty else { phase = .complete; return }

        // Run the REAL `mootx01 install` for the selected clients. It is the
        // single source of truth for a complete install — client wiring, the
        // plugin/skill depth, AND the resident daemon + management console. The
        // GUI must NOT reimplement those steps: doing so silently skipped the
        // daemon (clients wired to a dead 127.0.0.1:4242) and the plugin. This
        // makes the setup assistant a true projection of the CLI.
        //
        // The subprocess runs OFF the main thread: waitUntilExit on the main
        // actor froze the UI (beachball) for the several seconds the install
        // takes, hiding the .installing progress view.
        let ids = selected.map(\.client.id).joined(separator: ",")
        let names = selected.map(\.client.displayName)
        let launchPath = binaryPath
        let mode = depth.rawValue

        Task {
            let (results, skipped) = await Self.runInstall(
                launchPath: launchPath, ids: ids, mode: mode, names: names)
            self.results = results
            self.skipped = skipped
            self.phase = .complete
        }
    }

    /// Run the CLI install off the main actor and return (results, skipped).
    /// Read the daemon LaunchAgent plist's MOOTX01_VAULT value. Returns true
    /// when the user's prior posture was vault-off (MOOTX01_VAULT=0).
    private static func readDaemonVaultPosture(home: URL) -> Bool {
        let plistURL = home
            .appendingPathComponent("Library/LaunchAgents/com.mootx01.daemon.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String: Any],
              let envVars = plist["EnvironmentVariables"] as? [String: String]
        else { return false }
        return envVars["MOOTX01_VAULT"] == "0"
    }

    private nonisolated static func runInstall(
        launchPath: String, ids: String, mode: String, names: [String], vaultOff: Bool = false
    ) async -> ([String], [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        var args = ["install", "--target", ids, "--mode", mode, "--yes"]
        if vaultOff { args.append("--vault-off") }
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            // Drain the pipe BEFORE waitUntilExit — a full pipe buffer would
            // deadlock the child.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if proc.terminationStatus == 0 {
                return (names, [])
            }
            let tail = output.split(separator: "\n").suffix(6).map(String.init)
            return ([], ["mootx01 install exited \(proc.terminationStatus)"] + tail)
        } catch {
            return ([], ["Could not run mootx01 install: \(error.localizedDescription)"])
        }
    }
}
