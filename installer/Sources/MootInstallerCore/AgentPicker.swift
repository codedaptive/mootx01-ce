// AgentPicker.swift
//
// Interactive agent selection for `mootx01 install`. Detects which
// MCP clients are installed on the machine, prompts the user to select
// among them, and returns the chosen subset.
//
// Interaction modes:
//   - Non-interactive (--yes or stdin is not a tty): return all detected clients.
//   - Explicit target (--target "claude,cursor"): validate and return named clients.
//   - Interactive terminal: numbered list prompt; user types comma-separated numbers.
//
// ANSI checkbox UI is approximated by a numbered list with detected/missing
// annotations. True cursor-movement checkbox navigation requires full termios
// control and is deferred to a future UI sprint.

import Foundation

/// Picks which MCP clients to wire during install or uninstall.
public enum AgentPicker {

    // MARK: - Public entry point

    /// Select which clients to operate on.
    ///
    /// - Parameters:
    ///   - yes: when true, skip prompts and return all detected clients.
    ///   - target: comma-separated list of client ids. When non-nil, returns
    ///     only those clients (detected or not — caller decides whether to skip
    ///     uninstalled ones). Validated against `MCPClients.supported`.
    ///   - homeDirectory: injected for detection; pass `FileManager.default.homeDirectoryForCurrentUser`.
    /// - Returns: the selected `[MCPClient]`. May be empty if no clients are
    ///   detected or none are selected.
    /// - Throws: `AgentPickerError.unknownClient` if `target` names an unsupported id.
    public static func pick(
        yes: Bool,
        target: String?,
        homeDirectory: URL
    ) throws -> [MCPClient] {
        // Explicit target list: validate and return without prompting.
        if let target {
            return try resolveExplicit(target: target)
        }

        let detected = MCPClients.supported.filter { $0.isPresent(homeDirectory: homeDirectory) }

        // Non-interactive: return all detected.
        if yes || !isInteractiveTerminal() {
            return detected
        }

        // Interactive: numbered prompt.
        return promptUser(detected: detected, all: MCPClients.supported)
    }

    // MARK: - Explicit target resolution

    private static func resolveExplicit(target: String) throws -> [MCPClient] {
        let ids = target.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [MCPClient] = []
        for id in ids {
            guard let client = MCPClients.supported.first(where: { $0.id == id }) else {
                throw AgentPickerError.unknownClient(id)
            }
            result.append(client)
        }
        return result
    }

    // MARK: - Interactive prompt

    private static func promptUser(detected: [MCPClient], all: [MCPClient]) -> [MCPClient] {
        print("\nDetected MCP clients on this machine:")
        print("")
        for (i, client) in all.enumerated() {
            let tag = detected.contains(where: { $0.id == client.id }) ? "[✓]" : "[ ]"
            print("  \(i + 1). \(tag) \(client.displayName)")
        }
        print("")
        print("Enter numbers to install (comma-separated), 'all' for all detected,")
        print("or press Enter to skip: ", terminator: "")

        guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else {
            return []
        }

        if line.lowercased() == "all" {
            return detected
        }

        let indices = line.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 >= 1 && $0 <= all.count }
            .map { all[$0 - 1] }
        return indices
    }

    // MARK: - Terminal detection

    private static func isInteractiveTerminal() -> Bool {
        isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    }
}

// MARK: - Error types

/// Errors from AgentPicker operations.
public enum AgentPickerError: Error, CustomStringConvertible {
    case unknownClient(String)

    public var description: String {
        switch self {
        case .unknownClient(let id):
            let known = MCPClients.supported.map { $0.id }.joined(separator: ", ")
            return "unknown client id '\(id)'. Known clients: \(known)"
        }
    }
}
