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
// Interactive UI is a hand-rolled ANSI multiselect driven by raw
// terminal mode (termios): arrow keys (or j/k) move the cursor, space
// toggles a row, Enter confirms. Detected clients are pre-checked. No
// external dependency — the project ships zero non-argument-parser deps,
// so the clack-style UX is built directly on ANSI escape codes.
//
// Fallbacks, in order:
//   - --target "claude,cursor"  → explicit, no prompt.
//   - --yes OR non-TTY          → all detected, no prompt.
//   - TTY but raw mode fails    → numbered list prompt (readLine).

import Foundation
#if canImport(Glibc)
import Glibc
#endif

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

        // Interactive: ANSI multiselect when raw mode is available,
        // numbered prompt otherwise. Detected clients are pre-checked.
        let all = MCPClients.supported
        let preChecked = Set(detected.map { $0.id })
        if let chosen = multiselect(all: all, preChecked: preChecked) {
            return chosen
        }
        return promptUser(detected: detected, all: all)
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

    // MARK: - ANSI multiselect (raw terminal mode)

    /// Hand-rolled clack-style multiselect. Returns the chosen clients,
    /// or `nil` if raw terminal mode could not be entered (the caller
    /// then falls back to the numbered prompt).
    ///
    /// Controls: ↑/↓ or k/j move, space toggles, a toggles all, Enter
    /// confirms, q/Ctrl-C cancels (returns an empty selection). Detected
    /// clients start checked.
    ///
    /// The raw-mode contract: we put the terminal into noncanonical,
    /// no-echo mode so single keypresses (and the multi-byte escape
    /// sequences arrow keys produce) arrive immediately without waiting
    /// for a newline. The original termios is always restored via the
    /// `defer`, even on an early return or thrown error.
    private static func multiselect(
        all: [MCPClient],
        preChecked: Set<String>
    ) -> [MCPClient]? {
        guard isInteractiveTerminal() else { return nil }

        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            // No controlling terminal we can configure — fall back.
            return nil
        }
        var raw = original
        // Drop canonical (line-buffered) mode and echo so keypresses are
        // delivered one byte at a time and the cursor keys we draw don't
        // double up with the terminal's own echo.
        raw.c_lflag &= ~(UInt(ECHO) | UInt(ICANON))
        // VMIN=1, VTIME=0: block until at least one byte is available.
        withUnsafeMutableBytes(of: &raw.c_cc) { ptr in
            ptr[Int(VMIN)] = 1
            ptr[Int(VTIME)] = 0
        }
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            return nil
        }
        defer {
            var restore = original
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
            // Make the cursor visible again in case we hid it.
            print("\u{1B}[?25h", terminator: "")
        }

        var checked = Set(all.filter { preChecked.contains($0.id) }.map { $0.id })
        var cursor = 0
        var firstDraw = true

        // Hide the cursor while we own the screen region.
        print("\u{1B}[?25l", terminator: "")
        print("Select agents to configure  (↑/↓ move · space toggle · a all · enter confirm)")

        func redraw() {
            if !firstDraw {
                // Move back up over the rows we drew last time.
                print("\u{1B}[\(all.count)A", terminator: "")
            }
            firstDraw = false
            for (i, client) in all.enumerated() {
                let box = checked.contains(client.id) ? "[x]" : "[ ]"
                let detectedTag = preChecked.contains(client.id) ? " (detected)" : ""
                let pointer = i == cursor ? "›" : " "
                // \u{1B}[2K clears the whole line so a shorter row never
                // leaves stale characters from a previous render.
                let line = "\u{1B}[2K \(pointer) \(box) \(client.displayName)\(detectedTag)"
                print(line)
            }
        }

        redraw()

        // Read loop. Returns from inside on Enter / cancel.
        while true {
            var byte: UInt8 = 0
            let n = read(STDIN_FILENO, &byte, 1)
            if n != 1 { break } // EOF / error — treat as cancel.

            switch byte {
            case 0x03, 0x71: // Ctrl-C, 'q' → cancel (empty selection)
                print("")
                return []
            case 0x0D, 0x0A: // CR / LF → confirm
                print("")
                return all.filter { checked.contains($0.id) }
            case 0x20: // space → toggle current
                let id = all[cursor].id
                if checked.contains(id) { checked.remove(id) } else { checked.insert(id) }
                redraw()
            case 0x61: // 'a' → toggle all (check all unless all already checked)
                if checked.count == all.count {
                    checked.removeAll()
                } else {
                    checked = Set(all.map { $0.id })
                }
                redraw()
            case 0x6B: // 'k' → up
                cursor = (cursor - 1 + all.count) % all.count
                redraw()
            case 0x6A: // 'j' → down
                cursor = (cursor + 1) % all.count
                redraw()
            case 0x1B: // ESC — start of an arrow-key sequence: ESC [ A/B
                var seq: [UInt8] = [0, 0]
                let r1 = read(STDIN_FILENO, &seq[0], 1)
                let r2 = read(STDIN_FILENO, &seq[1], 1)
                if r1 == 1 && r2 == 1 && seq[0] == 0x5B { // '['
                    if seq[1] == 0x41 { // 'A' → up
                        cursor = (cursor - 1 + all.count) % all.count
                        redraw()
                    } else if seq[1] == 0x42 { // 'B' → down
                        cursor = (cursor + 1) % all.count
                        redraw()
                    }
                }
                // A bare ESC (no following bytes) is ignored.
            default:
                break
            }
        }

        // Loop exited via EOF: treat as confirm with current selection.
        return all.filter { checked.contains($0.id) }
    }

    // MARK: - Depth prompt (§4.4)

    /// Prompt for the global integration depth. Shown only when `--mode` was
    /// not supplied AND not `--yes` (the caller enforces that). Placed AFTER
    /// the client picker and BEFORE apply. Default = Full Plugin (option 3);
    /// an empty line or a non-TTY returns the default.
    ///
    /// Numbered prompt (not the raw-mode multiselect) — depth is a single
    /// choice, so a numbered read keeps it simple and TTY-robust.
    public static func pickDepth() -> InstallDepth {
        guard isInteractiveTerminal() else { return .default }
        print("")
        print("Integration depth?")
        print("  1) Server only      — MCP tools (moot_*)")
        print("  2) Server + Skills  — tools + mootx01-memory skill (auto-loads)")
        print("  3) Full Plugin      — native plugin per tool                 [default]")
        print("Choice [3]: ", terminator: "")

        guard let line = readLine()?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else {
            return .default
        }
        switch line {
        case "1": return .server
        case "2": return .skills
        case "3": return .plugin
        default:  return .default   // unrecognised → default (Full Plugin)
        }
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
