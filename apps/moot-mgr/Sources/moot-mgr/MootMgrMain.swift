// MootMgrMain.swift
//
// Entry point for the moot-mgr observer/manager process (Phase 1 CLI).
//
// The thin executable: resolve config from the environment, parse the
// subcommand, open the manager's store, run the command, print the result,
// and exit. The HTTP read-plane and the macOS menu-bar shell are later phases
// (MANAGER_1.0_PLAN.md §3 Phase 3 / §5 Phase 5).
//
// stdout carries the command output; usage/errors go to stderr with a nonzero
// exit so the surface is script-friendly.

import Foundation
import MootManager

@main
struct MootMgrMain {

    static func main() async {
        // Drop argv[0]; parse the remainder into a typed command.
        let arguments = Array(CommandLine.arguments.dropFirst())

        guard let command = ManagerCLI.parse(arguments) else {
            // Unrecognised command: usage to stderr, nonzero exit.
            fputs(ManagerCLI.usage + "\n", stderr)
            exit(2)
        }

        // `help` needs no store — print and exit cleanly before opening anything.
        if command == .help {
            print(ManagerCLI.usage)
            return
        }

        // `serve` is the long-running resident-host surface (P3): own the store,
        // serve the loopback HTTP read-API + gated UDS control channel, run the
        // retention loop, and block until the process is signalled. Handled here
        // (not via ManagerCLI.run, which covers only one-shot store operations).
        if command == .serve {
            await runResidentHost()
            return
        }

        // Resolve configuration (store path + retention window) from the env.
        let config = ManagerConfig.fromEnvironment()
        let manager = MootManager(config: config)

        do {
            try await manager.start()
            // The CLI is a one-shot invocation, so reading the clock here is
            // the app's own boundary (determinism applies to engines/libs, not
            // the app's own loop — the computed cutoff is passed into the store).
            let output = try await ManagerCLI.run(command, manager: manager, now: Date())
            await manager.stop()
            print(output)
        } catch {
            fputs("moot-mgr error: \(error)\n", stderr)
            await manager.stop()
            exit(1)
        }
    }

    /// Launch the resident host from the environment and block until the process
    /// is terminated. The retention loop and both network surfaces run inside
    /// the host; this entry point just keeps the process alive.
    static func runResidentHost() async {
        let config = ResidentHostConfig.fromEnvironment()
        let host = ResidentHost(config: config)
        do {
            try await host.start()
        } catch {
            fputs("moot-mgr serve error: \(error)\n", stderr)
            exit(1)
        }
        let port = await host.boundHTTPPort()
        print("moot-mgr resident host running — HTTP 127.0.0.1:\(port), control UDS \(config.controlSocketPath)")
        // Block forever: the host's accept threads and retention loop do the
        // work. A real deployment installs SIGTERM/SIGINT handlers to call
        // host.stop(); for the prototype the process is stopped externally.
        while true {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
    }
}
