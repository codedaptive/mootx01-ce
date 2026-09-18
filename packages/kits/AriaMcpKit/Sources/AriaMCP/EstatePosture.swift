// EstatePosture.swift — the live / frozen posture of a served estate.
//
// A frozen serve makes a served estate behave like a read-only, side-effect-
// free snapshot: no background workers are spawned, no recall traces or
// reward marks are written on the read path, and every mutating tool is
// refused. The posture lives on the serve process and its dispatcher only;
// nothing about it is persisted in the estate.
//
// Rust twin: packages/kits/AriaMcpKit/rust/src/estate_posture.rs.

import Foundation

/// Whether the served estate is live (the default) or frozen.
public enum EstatePosture: String, Sendable, Equatable {
    /// Normal serve: background workers run, recall traces and reward marks
    /// are written, mutating tools execute.
    case live
    /// Snapshot serve: `mootx01 serve --frozen` or `MOOTX01_FROZEN=1`.
    case frozen

    /// Environment twin of `mootx01 serve --frozen`. The value `"1"` enables
    /// the frozen posture; any other value, or absence, leaves the estate live.
    /// Strict on purpose: a benchmark lane that exports a stray value must not
    /// silently freeze a seeding serve.
    public static let environmentKey = "MOOTX01_FROZEN"

    /// Resolve the posture from the `--frozen` flag and the environment.
    /// The flag wins: `--frozen` freezes even when the variable is absent or
    /// holds another value. Without the flag, `MOOTX01_FROZEN=1` freezes.
    public static func resolve(frozenFlag: Bool, environment: [String: String]) -> EstatePosture {
        if frozenFlag { return .frozen }
        return environment[environmentKey] == "1" ? .frozen : .live
    }

    /// The line a frozen serve logs at startup. Byte-identical in both ports.
    public static let frozenLogLine =
        "FROZEN: no background workers, no recall traces, mutating tools refused"

    /// The `isError` text a frozen dispatcher returns for a mutating tool.
    /// Byte-identical in both ports.
    public static func refusalMessage(tool: String) -> String {
        "estate is frozen (serve --frozen): \(tool) is a mutating tool and was refused"
    }

    /// The `isError` text a frozen dispatcher returns for a command-classified
    /// tool (`ToolMutationInventory.frozenReadCommands`) whose `command`
    /// argument is not a read. `command` is nil when the argument is absent
    /// or not a string and renders as `(missing)`. Byte-identical in both
    /// ports.
    public static func refusalMessage(tool: String, command: String?) -> String {
        "estate is frozen (serve --frozen): \(tool) command \(command ?? "(missing)") is not a read command and was refused"
    }

    /// Value rendered on the `frozen:` line of `moot_estate_status`.
    public var statusValue: String {
        self == .frozen ? "true" : "false"
    }
}
