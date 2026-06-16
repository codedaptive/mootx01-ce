// ManagerCLI.swift
//
// The Phase-1 CLI surface for moot-mgr: argument parsing into a typed command,
// and the driver that runs a command against a MootManager. Kept in the library
// (not the executable target) so the tests can exercise the full parse→dispatch
// path without spawning a process.
//
// Command surface (MANAGER_1.0_PLAN.md §3, Phase 1):
//   moot-mgr monitoring on        — set the global switch ON (broadcast)
//   moot-mgr monitoring off       — set the global switch OFF (broadcast)
//   moot-mgr monitoring status    — print "ON"/"OFF"
//   moot-mgr retention run        — run one retention pass now
//   moot-mgr status               — print the full read/status surface
//   moot-mgr help                 — usage
//
// The HTTP dashboard read-plane is Phase 3, not here.

import Foundation

// MARK: - ManagerCommand

/// A parsed moot-mgr CLI command.
public enum ManagerCommand: Sendable, Equatable {
    /// Set the global monitoring switch ON (the broadcast signal).
    case monitoringOn
    /// Set the global monitoring switch OFF.
    case monitoringOff
    /// Print the current monitoring state ("ON"/"OFF").
    case monitoringStatus
    /// Run one retention pass now (roll off samples older than the window).
    case retentionRun
    /// Print the full read/status surface (totals, by-dropbox, by-estate,
    /// recent events, store health).
    case status
    /// Run the resident host: own the store, serve the loopback HTTP read-API
    /// and the gated UDS control channel, and run the retention loop until the
    /// process is signalled. This is the long-running P3 surface; the other
    /// commands are one-shot. Handled by the executable's `main`, not by
    /// `ManagerCLI.run` (which covers only one-shot store operations).
    case serve
    /// Print usage text.
    case help
}

// MARK: - CLI parsing

public enum ManagerCLI {

    /// Parse `arguments` (excluding the program name) into a `ManagerCommand`.
    ///
    /// - Parameter arguments: The argument list without `argv[0]`.
    /// - Returns: The parsed command, or `nil` if the arguments are not a
    ///   recognised command (the caller prints usage and exits non-zero).
    public static func parse(_ arguments: [String]) -> ManagerCommand? {
        guard let first = arguments.first else {
            // No subcommand → show help (a bare invocation is informational,
            // not an error).
            return .help
        }
        switch first {
        case "help", "--help", "-h":
            return .help
        case "status":
            return .status
        case "serve":
            return .serve
        case "monitoring":
            // Second token selects the monitoring action.
            guard arguments.count >= 2 else { return nil }
            switch arguments[1] {
            case "on": return .monitoringOn
            case "off": return .monitoringOff
            case "status": return .monitoringStatus
            default: return nil
            }
        case "retention":
            guard arguments.count >= 2, arguments[1] == "run" else { return nil }
            return .retentionRun
        default:
            return nil
        }
    }

    /// Usage text for the `help` command and parse failures.
    public static let usage = """
    moot-mgr — MOOTx01 observer/manager (Phase 1)

    USAGE:
      moot-mgr <command>

    COMMANDS:
      monitoring on        Enable monitoring fleet-wide (broadcast to consumers)
      monitoring off       Disable monitoring fleet-wide
      monitoring status    Print the current monitoring state (ON/OFF)
      retention run        Run one retention pass now (roll off old samples)
      status               Print the full status surface
      serve                Run the resident host: loopback HTTP read-API +
                           gated UDS control channel + retention loop (blocks)
      help                 Print this message

    ENVIRONMENT:
      MOOT_MGR_STORE                      Override the stats-store path
      MOOT_MGR_RETENTION_SECONDS          Retention window in seconds (default 604800 = 7d)
      MOOT_MGR_RETENTION_CADENCE_SECONDS  Resident retention-loop cadence (default 3600 = 1h)
      MOOT_MGR_HTTP_PORT                  Loopback HTTP read-API port (serve; default 4200)
      MOOT_MGR_CONTROL_TOKEN             Bearer token gating HTTP control (serve; required, >=16 chars)
      MOOT_MGR_CONTROL_SOCKET            UDS path for the gated control channel (serve)
    """
}

// MARK: - CLI driver

extension ManagerCLI {

    /// Run a parsed command against a started manager and return the text to
    /// print to stdout. The caller owns process start/stop and the clock.
    ///
    /// `help` is handled by the caller (it needs no manager); this driver
    /// covers the commands that touch the store.
    ///
    /// - Parameters:
    ///   - command: The parsed command (must not be `.help`).
    ///   - manager: A manager on which `start()` has already been called.
    ///   - now:     The current time, injected for determinism in tests.
    /// - Returns: The stdout text for the command.
    /// - Throws: Any error from the underlying manager operation.
    public static func run(
        _ command: ManagerCommand,
        manager: MootManager,
        now: Date
    ) async throws -> String {
        switch command {
        case .help:
            return usage
        case .monitoringOn:
            try await manager.setMonitoring(true)
            return "monitoring: ON"
        case .monitoringOff:
            try await manager.setMonitoring(false)
            return "monitoring: OFF"
        case .monitoringStatus:
            let on = try await manager.isMonitoring()
            return "monitoring: \(on ? "ON" : "OFF")"
        case .retentionRun:
            let deleted = try await manager.runRetention(now: now)
            return "retention: rolled off \(deleted) rows"
        case .status:
            let report = try await manager.status(now: now)
            return report.renderText()
        case .serve:
            // `serve` is a long-running surface handled by the executable's
            // `main` (it owns the host lifecycle and blocks). It is not a
            // one-shot store operation, so this driver does not run it.
            return "serve: handled by the resident host entry point"
        }
    }
}
