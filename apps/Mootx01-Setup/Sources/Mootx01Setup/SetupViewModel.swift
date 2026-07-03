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

@Observable
final class SetupViewModel {

    // MARK: - Published state

    var phase: SetupPhase = .detecting
    var clients: [ClientItem] = []
    var results: [String] = []
    var skipped: [String] = []

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
        let ids = selected.map(\.client.id).joined(separator: ",")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["install", "--target", ids, "--yes"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            if proc.terminationStatus == 0 {
                results = selected.map(\.client.displayName)
            } else {
                skipped = ["mootx01 install exited \(proc.terminationStatus)"]
                    + output.split(separator: "\n").suffix(6).map(String.init)
            }
        } catch {
            skipped = ["Could not run mootx01 install: \(error.localizedDescription)"]
        }

        phase = .complete
    }
}
