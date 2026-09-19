// BoundedSubprocess.swift
//
// The one subprocess seam for external judge/rerank commands. Both runners
// (lmeRunJudge, runRerankSubprocess) execute the same class of command —
// prompt on stdin, reply on stdout — and MUST share one bounded lifecycle:
// every stage (exit wait, TERM→KILL escalation, post-exit pipe drains) is
// bounded, so no child behaviour can hang the benchmark. Twin of the Rust
// `config::wait_with_deadline` + judge/reranker runner pair.

import Foundation

/// Wall-clock bound for judge/reranker/answer subprocess execution, in
/// seconds. One shared bound: the judge, the reranker, and the offline
/// answer command are the same class of external command and must time out
/// identically. The default 120 s accommodates a slow local model on an idle
/// machine; `MOOT_BENCH_SUBPROCESS_TIMEOUT` (whole seconds, > 0) raises it
/// when one local server is shared by several lanes at once, where a 27B
/// judge on a long prompt legitimately exceeds two minutes. A hung command
/// past this bound is killed, never awaited. Twin of Rust
/// `config::subprocess_timeout_secs()`.
let subprocessTimeoutSeconds: Double = {
    if let raw = ProcessInfo.processInfo.environment["MOOT_BENCH_SUBPROCESS_TIMEOUT"],
       let secs = Double(raw), secs > 0 {
        return secs
    }
    return 120.0
}()

/// Grace period, in seconds, between SIGTERM and SIGKILL on the timeout
/// path, and the bound on post-exit pipe drains. A child that ignores
/// SIGTERM gets SIGKILL; a pipe held open by an orphaned grandchild after
/// the child exited must not convert a bounded runner into an unbounded
/// read (Wave-3 G2).
let subprocessKillGraceSeconds: Double = 5.0

/// Outcome of a bounded subprocess run that reached process exit.
struct BoundedSubprocessResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data
}

/// Runs `cmd` via `/bin/sh` with `prompt` on stdin, every stage bounded.
///
/// The command travels in the private MOOT_BENCH_CMD_INTERNAL env var so a
/// command carrying an API key is not visible in `ps` argv. The shell stub
/// copies it to a local and UNSETS the export before eval, so the command
/// string is NOT inherited by the judge/rerank process or its descendants
/// (`ps e`, crash reports, child tools that log their environment).
///
/// Bounds, in order (Wave-3 G2 — no stage may be unbounded):
///  1. Exit wait ≤ `subprocessTimeoutSeconds`.
///  2. On timeout: SIGTERM, then ≤ `subprocessKillGraceSeconds` before
///     SIGKILL; returns nil (timed out, child killed).
///  3. Post-exit stdout/stderr drain waits ≤ `subprocessKillGraceSeconds`
///     each — an orphaned grandchild holding the pipe cannot hang the run;
///     an undrained stdout returns nil rather than partial data.
///
/// - Returns: the exit status and captured pipes, or nil when any bound
///   fired (the caller treats nil as a timeout failure).
/// - Throws: only on launch failure (`Process.run()`).
/// `timeout` and `killGrace` default to the shared constants; tests pass
/// sub-second values so the timeout paths run in seconds, not minutes.
func runBoundedCmdSubprocess(
    cmd: String,
    prompt: String,
    timeout: Double = subprocessTimeoutSeconds,
    killGrace: Double = subprocessKillGraceSeconds
) throws -> BoundedSubprocessResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    var env = ProcessInfo.processInfo.environment
    env["MOOT_BENCH_CMD_INTERNAL"] = cmd
    process.environment = env
    // Copy → unset → eval: the unset runs BEFORE the command, so the
    // command's own environment never contains MOOT_BENCH_CMD_INTERNAL.
    // The shell local `__moot_bench_cmd` is process-private and gone when
    // the shell exec's/forks the command.
    process.arguments = [
        "-c",
        #"__moot_bench_cmd="$MOOT_BENCH_CMD_INTERNAL"; unset MOOT_BENCH_CMD_INTERNAL; eval "$__moot_bench_cmd""#,
    ]

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    // Termination handler signals the exit semaphore whether the process
    // exits normally or is killed, so every wait below has a signal source.
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    try process.run()

    // Write the prompt to stdin, then close to signal EOF.
    stdinPipe.fileHandleForWriting.write(Data(prompt.utf8))
    stdinPipe.fileHandleForWriting.closeFile()

    // Drain BOTH pipes concurrently. Without the drains, a child that
    // writes more than the ~64 KB pipe buffer blocks on its write while
    // the parent waits for exit — deadlock. Draining from the start also
    // means the timeout path never needs a synchronous read.
    nonisolated(unsafe) var stdoutData = Data()
    nonisolated(unsafe) var stderrData = Data()
    let stdoutDrained = DispatchSemaphore(value: 0)
    let stderrDrained = DispatchSemaphore(value: 0)
    DispatchQueue(label: "moot-bench.subprocess.stdout").async {
        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        stdoutDrained.signal()
    }
    DispatchQueue(label: "moot-bench.subprocess.stderr").async {
        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        stderrDrained.signal()
    }

    // 1. Bounded exit wait.
    if exited.wait(timeout: .now() + timeout) == .timedOut {
        // 2. TERM → grace → KILL. terminate() is SIGTERM and a child may
        // ignore it; SIGKILL cannot be ignored.
        process.terminate()
        if exited.wait(timeout: .now() + killGrace) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + killGrace)
        }
        return nil
    }

    // 3. Bounded drain waits. The child exited, but a grandchild that
    // inherited the write end can hold the pipe open indefinitely —
    // treat an undrained stdout as a timeout, not as partial data.
    if stdoutDrained.wait(timeout: .now() + killGrace) == .timedOut {
        return nil
    }
    // Missing stderr is not a failure — it is diagnostic-only for callers.
    _ = stderrDrained.wait(timeout: .now() + killGrace)

    return BoundedSubprocessResult(
        terminationStatus: process.terminationStatus,
        stdout: stdoutData,
        stderr: stderrData)
}
