// ArgvDispatch.swift
//
// Wave 6 addendum: argv0-based subcommand dispatch for the `mootx01`
// binary. Multi-call-binary pattern (the same one `busybox`/`python3`
// use) — a caller can invoke the SAME binary under a different name
// (typically via a symlink) and have it default to a specific
// subcommand, without the caller needing to pass that subcommand
// explicitly.
//
// `mootx01-proxy`: an MCP client config whose schema can only express a
// single bare `command` string (no separate `args` array) cannot write
// `{"command": "mootx01", "args": ["proxy"]}` — it can only write
// `{"command": "mootx01-proxy"}` (or an absolute path ending in that
// name). Naming the executed program `mootx01-proxy` (argv[0]) is how
// such a config still reaches `ProxyCommand` without an args array.
//
// This file is the PURE decision logic only — extracted into
// MootInstallerCore (rather than living inline in MootMain.swift, an
// untested executable-target entry point) so it is directly unit
// testable, per this app's established split: MootInstallerCore holds
// testable logic, the `mootx01` executable target is a thin, largely
// untested CLI wrapper around it. Placing/naming the actual
// `mootx01-proxy` symlink (installer wiring, PATH placement) is
// OUT OF SCOPE for this file — see MootMain.swift's doc comment for the
// current caller-side wiring and its own scope note.

import Foundation

/// Resolves argv0-based and other bare-invocation subcommand defaults.
public enum ArgvDispatch {

    /// The argv0 basename that triggers implicit `proxy` dispatch.
    public static let proxyInvocationName = "mootx01-proxy"

    /// Resolve the effective CLI arguments given the raw argv and how
    /// the binary was invoked.
    ///
    /// Two back-compat injections, evaluated in this order, and BOTH
    /// only ever apply to a truly bare invocation (`rawArgs.isEmpty`).
    /// Neither fires when the caller already named an explicit
    /// subcommand (or passed `--help`/`--version`) — argv0 dispatch and
    /// the bare-serve default are defaults for absent input, never
    /// overrides of explicit input.
    ///
    /// 1. `argv0`'s last path component is `mootx01-proxy` → inject
    ///    `["proxy"]`. This is the NEW behavior this file adds.
    /// 2. Otherwise, `stdinIsPipe` (non-interactive) → inject `["serve"]`.
    ///    This is the PRE-EXISTING MCP-client back-compat default
    ///    (originally inline in MootMain.swift: a client config with
    ///    `"command": "mootx01"` and no subcommand still starts the
    ///    server). Moved here unchanged so both defaults share one
    ///    tested decision point.
    ///
    /// - Parameters:
    ///   - argv0: `CommandLine.arguments[0]` (the invoked program path
    ///     or name — may be an absolute path, a relative path, or a
    ///     bare name resolved via PATH, depending on how the shell/
    ///     parent process invoked it).
    ///   - rawArgs: the arguments AFTER argv0 (`CommandLine.arguments.dropFirst()`).
    ///   - stdinIsPipe: `true` when stdin is a pipe (non-interactive),
    ///     `false` for a TTY.
    /// - Returns: the arguments to actually parse — `rawArgs` unchanged
    ///   if neither default applies.
    public static func resolvedArguments(
        argv0: String,
        rawArgs: [String],
        stdinIsPipe: Bool
    ) -> [String] {
        guard rawArgs.isEmpty else { return rawArgs }
        if (argv0 as NSString).lastPathComponent == proxyInvocationName {
            return ["proxy"]
        }
        if stdinIsPipe {
            return ["serve"]
        }
        return rawArgs
    }
}
