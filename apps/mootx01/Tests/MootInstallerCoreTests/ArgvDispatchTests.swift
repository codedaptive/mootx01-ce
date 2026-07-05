// ArgvDispatchTests.swift
//
// Wave 6 addendum: argv0-based `mootx01-proxy` dispatch, plus the
// pre-existing bare-pipe → `serve` default it was extracted alongside
// (previously inline and untested in MootMain.swift).

import Testing
@testable import MootInstallerCore

@Suite("ArgvDispatch")
struct ArgvDispatchTests {

    @Test("argv0 basename mootx01-proxy with no args injects proxy")
    func argv0ProxyBasenameInjectsProxy() {
        #expect(ArgvDispatch.resolvedArguments(
            argv0: "/Users/dev/.local/bin/mootx01-proxy", rawArgs: [], stdinIsPipe: false
        ) == ["proxy"])
        #expect(ArgvDispatch.resolvedArguments(
            argv0: "mootx01-proxy", rawArgs: [], stdinIsPipe: true
        ) == ["proxy"], "argv0 dispatch takes precedence over the bare-pipe serve default")
    }

    @Test("argv0 mootx01-proxy with an explicit subcommand is left untouched")
    func argv0ProxyBasenameWithExplicitArgsUntouched() {
        #expect(ArgvDispatch.resolvedArguments(
            argv0: "/usr/local/bin/mootx01-proxy", rawArgs: ["install", "--yes"], stdinIsPipe: false
        ) == ["install", "--yes"])
    }

    @Test("bare pipe invocation (no argv0 match) defaults to serve")
    func barePipeInvocationDefaultsToServe() {
        #expect(ArgvDispatch.resolvedArguments(
            argv0: "/Users/dev/.local/bin/mootx01", rawArgs: [], stdinIsPipe: true
        ) == ["serve"])
    }

    @Test("bare TTY invocation (no argv0 match, no pipe) is left untouched")
    func bareTTYInvocationUntouched() {
        #expect(ArgvDispatch.resolvedArguments(
            argv0: "mootx01", rawArgs: [], stdinIsPipe: false
        ) == [], "a bare TTY invocation must fall through to ArgumentParser's usage text, not silently start serve")
    }

    @Test("an explicit subcommand is always passed through unchanged, any argv0/stdin combination")
    func explicitSubcommandAlwaysPassesThrough() {
        for argv0 in ["mootx01", "mootx01-proxy", "/opt/bin/mootx01"] {
            for pipe in [true, false] {
                #expect(ArgvDispatch.resolvedArguments(argv0: argv0, rawArgs: ["status"], stdinIsPipe: pipe) == ["status"])
            }
        }
    }

    @Test("only the exact basename mootx01-proxy triggers dispatch — a partial match does not")
    func onlyExactBasenameTriggersDispatch() {
        #expect(ArgvDispatch.resolvedArguments(
            argv0: "mootx01-proxy-dev", rawArgs: [], stdinIsPipe: false
        ) == [], "a differently-named executable must not accidentally trigger proxy dispatch")
        #expect(ArgvDispatch.resolvedArguments(
            argv0: "not-mootx01-proxy", rawArgs: [], stdinIsPipe: false
        ) == [])
    }

    @Test("--help style flags with no subcommand are untouched (neither default overrides them)")
    func helpFlagUntouched() {
        #expect(ArgvDispatch.resolvedArguments(
            argv0: "mootx01", rawArgs: ["--help"], stdinIsPipe: true
        ) == ["--help"])
        #expect(ArgvDispatch.resolvedArguments(
            argv0: "mootx01-proxy", rawArgs: ["--version"], stdinIsPipe: false
        ) == ["--version"])
    }
}
