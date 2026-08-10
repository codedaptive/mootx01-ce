// HookCaptureCommand.swift
//
// `mootx01 hook-capture`
//
// Claude Code PreToolUse hook handler for Harness Memory Mode.
// Invoked via `~/.mootx01/hooks/capture-harness-memory.sh`, which passes
// stdin through directly:
//
//   #!/bin/sh
//   exec "$HOME/.mootx01/bin/mootx01" hook-capture
//
// Stdin shape (Claude Code PreToolUse event per recon 2026-08-07):
// ```json
// {
//   "session_id": "<str>",
//   "hook_event_name": "PreToolUse",
//   "tool_name": "Write",
//   "tool_input": { "path": "...", "content": "..." },
//   "tool_use_id": "<str>"
// }
// ```
//
// Behavior:
//   1. Parse stdin as JSON; extract `tool_name` and `tool_input`.
//   2. If `tool_input.path` matches `<any>/.claude/projects/<slug>/memory/<name>`:
//      a. For Write: POST content to estate via daemon (location harness/<slug>/<name>).
//         Daemon unreachable → print allow decision, exit 0 (write through).
//         Daemon success  → print deny decision + teaching message, exit 0.
//      b. For Edit / MultiEdit: deny with teaching message (nothing on disk to edit).
//   3. If path does not match: exit 0 silently (allow, Claude Code default).
//
// Output (when a decision is needed): JSON to stdout, exit 0.
// Claude Code reads the permissionDecision field (option 2 deny mechanism):
// ```json
// {
//   "hookSpecificOutput": {
//     "hookEventName": "PreToolUse",
//     "permissionDecision": "deny",
//     "permissionDecisionReason": "..."
//   }
// }
// ```

import ArgumentParser
import Foundation
import MootInstallerCore
import os

private let log = Logger(subsystem: "com.mootx01.kit", category: "HookCapture")

struct HookCaptureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook-capture",
        abstract: "Claude Code PreToolUse hook for Harness Memory Mode (internal).",
        shouldDisplay: false // Not shown in `mootx01 --help`; invoked by the hook script.
    )

    func run() async throws {
        // Read all of stdin.
        let stdinData = try readStdin()
        guard let json = try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any] else {
            // Unparseable stdin → allow (don't block Claude Code unexpectedly).
            return
        }

        let toolName = json["tool_name"] as? String ?? ""
        guard let toolInput = json["tool_input"] as? [String: Any],
              let targetPath = toolInput["path"] as? String else {
            return
        }

        // Check if the target is a Claude Code project memory file.
        guard let (slug, fileName) = HarnessMemoryMatcher.match(path: targetPath) else {
            // Not a project-memory path — allow.
            return
        }

        // Resolve daemon port from the installed data directory.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = MootPaths.resolveDataDirectory(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: home
        )
        let port = MootPaths.resolvedResidentPort(dataDir: dataDir)
        // Hook path: 1s request / 2s resource to avoid freezing Claude Code.
        // The general LiveDaemonClient (5/10s) is kept for ingest, restore,
        // and enable/disable paths where long lens/synthesis calls are possible.
        let daemon = LiveDaemonClient(
            port: port,
            timeoutIntervalForRequest: 1,
            timeoutIntervalForResource: 2
        )

        // (observability: harness.capture.count — MXE-HM-2)
        switch toolName {
        case "Write":
            let content = toolInput["content"] as? String ?? ""
            await handleWrite(
                slug: slug, fileName: fileName, content: content,
                daemon: daemon, now: Date()
            )

        case "Edit", "MultiEdit":
            // There is no file on disk to edit — it was captured into the estate
            // the last time it was written. Deny with teaching message.
            printDeny(reason: HarnessMemoryMatcher.teachingMessage)

        default:
            // Unknown tool — allow.
            break
        }
    }

    // MARK: - Write handler

    /// - Parameter now: capture timestamp; injected so tests can pass a fixed clock.
    ///   Callers pass `Date()` — `Date()` is called once at the outermost call
    ///   site (`run()`) so the timestamp is deterministic for the full call tree.
    internal func handleWrite(
        slug: String,
        fileName: String,
        content: String,
        daemon: some DaemonClient,
        now: Date
    ) async {
        // Skip the ping() round-trip — go straight to fileMemory(). The catch
        // block already handles daemon-down (throws → printAllow). Dropping ping
        // saves one HTTP round-trip on the hook path; with 1s/2s timeouts a
        // ping+file failure would block Claude Code for up to 2s instead of 1s.
        let location = "harness/\(slug)/\(fileName)"
        let kind: String? = fileName.lowercased() == "memory.md" ? "list" : nil
        do {
            let confirmed = try await daemon.fileMemory(
                location: location,
                content: content,
                eventTime: now,
                kind: kind
            )
            if confirmed {
                printDeny(reason: HarnessMemoryMatcher.teachingMessage)
            } else {
                // Estate accepted but didn't confirm — allow as fallback.
                printAllow()
            }
        } catch {
            // Any error calling the daemon (including unreachable) → allow (write through).
            log.warning("hook-capture daemon call failed, allowing write-through: \(error)")
            printAllow()
        }
    }

    // MARK: - Output helpers

    /// Emit a JSON deny decision to stdout. Claude Code reads this and
    /// blocks the disk write, showing `reason` to the user.
    private func printDeny(reason: String) {
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            ] as [String: Any]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    /// Emit a JSON allow decision to stdout. Used when daemon is unreachable
    /// so the session is not blocked.
    private func printAllow() {
        let output: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "allow",
            ] as [String: Any]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: output),
           let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    // MARK: - Stdin

    private func readStdin() throws -> Data {
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = read(STDIN_FILENO, &buffer, bufferSize)
            if count <= 0 { break }
            data.append(contentsOf: buffer[..<count])
        }
        return data
    }
}
