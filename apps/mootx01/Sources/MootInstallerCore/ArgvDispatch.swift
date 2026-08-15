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
// `mootx01-botLink` (BL-1): the explicit AI data path for cloud agents
// whose only channel to this Mac is a permissioned one-shot shell. The
// agent execs `mootx01-botLink <subcommand>` by name; argv0 dispatch
// prepends `botlink` so the invocation reaches `BotLinkCommand`'s
// subcommands (`ping`/`list`/`call`/`rpc`). Unlike the proxy route —
// which is a bare-invocation default because ProxyCommand takes no
// subcommands — the botLink route namespaces args-carrying invocations
// too: `mootx01-botLink ping` becomes `botlink ping`.
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

    /// The argv0 basename that triggers implicit `botlink` dispatch (BL-1).
    /// Matches the `mootx01-botLink → mootx01` symlink the installer places
    /// beside the binary — capital L is deliberate and must match
    /// `Installer.placeBinary`'s symlink name exactly.
    public static let botLinkInvocationName = "mootx01-botLink"

    /// Resolve the effective CLI arguments given the raw argv and how
    /// the binary was invoked.
    ///
    /// Three injections, evaluated in this order:
    ///
    /// 1. `argv0`'s last path component is `mootx01-botLink` → PREPEND
    ///    `"botlink"` to the raw args (BL-1). This route namespaces rather
    ///    than defaulting: the symlink IS the cloud agent's command surface,
    ///    so `mootx01-botLink ping` must reach `botlink ping` and
    ///    `mootx01-botLink --help` must print botlink usage. A leading
    ///    explicit `botlink` is left untouched (no double-prepend).
    /// 2. `argv0`'s last path component is `mootx01-proxy` AND the
    ///    invocation is truly bare (`rawArgs.isEmpty`) → inject `["proxy"]`.
    ///    ProxyCommand takes no subcommands, so the bare-only default is the
    ///    whole surface; explicit args always pass through unchanged.
    /// 3. Otherwise, bare invocation with `stdinIsPipe` (non-interactive) →
    ///    inject `["serve"]`. This is the PRE-EXISTING MCP-client
    ///    back-compat default (originally inline in MootMain.swift: a client
    ///    config with `"command": "mootx01"` and no subcommand still starts
    ///    the server). Moved here unchanged so all defaults share one
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
        let basename = (argv0 as NSString).lastPathComponent
        if basename == botLinkInvocationName {
            // Namespacing route — see rule 1 in the doc comment. Evaluated
            // before the bare-invocation guard because it applies to args-
            // carrying invocations too (`mootx01-botLink ping`).
            if rawArgs.first == "botlink" { return rawArgs }
            return ["botlink"] + rawArgs
        }
        guard rawArgs.isEmpty else { return rawArgs }
        if basename == proxyInvocationName {
            return ["proxy"]
        }
        if stdinIsPipe {
            return ["serve"]
        }
        return rawArgs
    }
}
