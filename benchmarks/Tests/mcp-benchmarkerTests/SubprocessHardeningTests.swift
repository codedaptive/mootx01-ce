import Testing
import Foundation
@testable import mcp_benchmarker

// SubprocessHardeningTests.swift — E2: stderr deadlock prevention and timeout.
//                                   E4: command text not in ps argv (env var injection).
//
// E2: The two subprocess runners (runRerankSubprocess, lmeRunJudge) were
// vulnerable to a pipe-buffer deadlock: if the child wrote more than ~64 KB
// to stderr, it blocked trying to write while the parent was blocked waiting
// on stdout or waitUntilExit. The fix drains stderr on a background thread.
//
// E4: Both runners now pass the command via MOOT_BENCH_CMD_INTERNAL env var
// instead of embedding it in argv, so API keys in the command string are not
// visible in `ps` output. CLI parsing checks MOOT_BENCH_JUDGE_CMD /
// MOOT_BENCH_RERANK_CMD env vars before the flag values.
//
// Tests here verify:
// 1. A process that writes a large stderr block does not hang (no deadlock).
// 2. A fast-exiting process returns the correct stdout.
// 3. A non-zero-exit process is treated as failure (nil / Err).
// 4. The env var injection mechanism works end-to-end (E4).
// 5. The usage text names both the flag and env var paths (E4).
//
// Tests use /bin/sh commands so they run without any external tooling.

@Suite("Subprocess hardening — E2 stderr drain and timeout") struct SubprocessHardeningTests {

    // MARK: runRerankSubprocess

    @Test("reranker: a well-behaved process returns its stdout")
    func rerankSubprocessReturnsStdout() {
        let result = runRerankSubprocess(cmd: "/bin/echo hello-rerank", prompt: "ignored")
        #expect(result == "hello-rerank\n")
    }

    @Test("reranker: stdin is delivered to the subprocess")
    func rerankSubprocessDeliversStdin() {
        // /bin/cat echoes stdin back to stdout.
        let result = runRerankSubprocess(cmd: "/bin/cat", prompt: "rerank-input")
        #expect(result == "rerank-input")
    }

    @Test("reranker: a non-zero exit returns nil")
    func rerankSubprocessNonzeroExitReturnsNil() {
        let result = runRerankSubprocess(cmd: "/bin/sh -c 'exit 1'", prompt: "prompt")
        #expect(result == nil)
    }

    @Test("reranker: large stderr output does not deadlock — returns stdout correctly")
    func rerankSubprocessLargeStderrNoDeadlock() {
        // Write 256 KB of 'x' to stderr and one line to stdout.
        // Without the concurrent stderr drain, this would block once the 64 KB
        // pipe buffer fills. With the drain, it completes quickly.
        let cmd = "/bin/sh -c 'dd if=/dev/zero bs=262144 count=1 2>/dev/null | tr \"\\0\" x >&2; echo rerank-done'"
        let result = runRerankSubprocess(cmd: cmd, prompt: "test")
        #expect(result == "rerank-done\n")
    }

    // MARK: lmeRunJudge

    @Test("judge: a well-behaved process returns its trimmed stdout")
    func judgeSubprocessReturnsStdout() throws {
        let result = try lmeRunJudge(cmd: "/bin/echo  hello-judge  ", prompt: "ignored")
        #expect(result == "hello-judge")
    }

    @Test("judge: stdin is delivered to the subprocess")
    func judgeSubprocessDeliversStdin() throws {
        let result = try lmeRunJudge(cmd: "/bin/cat", prompt: "judge-input")
        #expect(result == "judge-input")
    }

    @Test("judge: a non-zero exit throws MCPError")
    func judgeSubprocessNonzeroExitThrows() {
        #expect(throws: MCPError.self) {
            _ = try lmeRunJudge(cmd: "/bin/sh -c 'exit 2'", prompt: "prompt")
        }
    }

    @Test("judge: large stderr output does not deadlock — returns stdout correctly")
    func judgeSubprocessLargeStderrNoDeadlock() throws {
        let cmd = "/bin/sh -c 'dd if=/dev/zero bs=262144 count=1 2>/dev/null | tr \"\\0\" x >&2; echo judge-done'"
        let result = try lmeRunJudge(cmd: cmd, prompt: "test")
        #expect(result == "judge-done")
    }

    @Test("judge: stderr content appears in the MCPError description on failure")
    func judgeSubprocessStderrInError() {
        do {
            _ = try lmeRunJudge(
                cmd: "/bin/sh -c 'echo diagnostic-text >&2; exit 1'",
                prompt: "prompt")
            Issue.record("expected MCPError not thrown")
        } catch let error as MCPError {
            #expect(error.description.contains("diagnostic-text"))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }

    // MARK: E4 — env var injection (command not in ps argv)

    @Test("reranker: env var injection — a command set via cmd parameter runs correctly")
    func rerankSubprocessEnvVarInjectionWorks() {
        // The E4 fix passes cmd via MOOT_BENCH_CMD_INTERNAL so `ps` shows
        // `eval "$MOOT_BENCH_CMD_INTERNAL"` rather than the actual command.
        // Verify the mechanism delivers the command correctly end-to-end.
        let result = runRerankSubprocess(cmd: "/bin/echo env-injection-works", prompt: "test")
        #expect(result == "env-injection-works\n")
    }

    @Test("judge: env var injection — a command set via cmd parameter runs correctly")
    func judgeSubprocessEnvVarInjectionWorks() throws {
        let result = try lmeRunJudge(cmd: "/bin/echo judge-injection-works", prompt: "test")
        #expect(result == "judge-injection-works")
    }

    @Test("reranker: env var injection preserves shell features (piped command works)")
    func rerankSubprocessEnvVarInjectionPreservesShellFeatures() {
        // eval preserves pipes, env-var expansion, and quoted args — the same
        // shell features that /bin/sh -c <cmd> offered before the E4 change.
        let result = runRerankSubprocess(
            cmd: "/bin/echo shell-features | /bin/cat",
            prompt: "test")
        #expect(result == "shell-features\n")
    }

    // MARK: E4 — help text names both paths

    @Test("usage text names MOOT_BENCH_JUDGE_CMD and MOOT_BENCH_RERANK_CMD env vars")
    func usageTextNamesEnvVarPaths() {
        let text = usageText()
        #expect(text.contains("MOOT_BENCH_JUDGE_CMD"))
        #expect(text.contains("MOOT_BENCH_RERANK_CMD"))
        // Help text must also mention the flag form so both paths are documented.
        #expect(text.contains("--judge-cmd"))
        #expect(text.contains("--rerank-cmd"))
    }

    // MARK: Wave-3 G2 — every subprocess stage is bounded

    @Test("bounded: a child that closes both pipes and keeps running is killed, not awaited")
    func boundedSubprocessPipesClosedStillAliveIsKilled() throws {
        // Closing stdout+stderr satisfies the pipe drains instantly; only the
        // bounded exit wait can end this run. Sub-second bounds keep the test
        // fast; production uses the shared 120s/5s constants.
        let start = Date()
        let result = try runBoundedCmdSubprocess(
            cmd: "exec 1>&- 2>&-; sleep 60",
            prompt: "test", timeout: 0.5, killGrace: 0.5)
        #expect(result == nil, "a pipe-closing sleeper must read as timeout")
        #expect(Date().timeIntervalSince(start) < 10,
                "control must return within the bounds, not after sleep 60")
    }

    @Test("bounded: a child that ignores SIGTERM is escalated to SIGKILL")
    func boundedSubprocessSigtermIgnoredEscalatesToSigkill() throws {
        let start = Date()
        let result = try runBoundedCmdSubprocess(
            cmd: "trap '' TERM; sleep 60",
            prompt: "test", timeout: 0.5, killGrace: 0.5)
        #expect(result == nil, "a TERM-ignoring sleeper must read as timeout")
        #expect(Date().timeIntervalSince(start) < 10,
                "SIGKILL escalation must return within the bounds")
    }

    @Test("bounded: rerank path treats a timed-out child as failure, ranking unchanged upstream")
    func rerankTimeoutReadsAsFailure() throws {
        // The runner wraps the bounded helper; nil from the helper is the
        // rerank-failure signal applyRerank counts and ignores.
        let result = try runBoundedCmdSubprocess(
            cmd: "exec 1>&-; sleep 60", prompt: "p", timeout: 0.5, killGrace: 0.5)
        #expect(result == nil)
    }

    // MARK: Wave-3 G4 — command string not inherited by the child environment

    @Test("G4: the child's environment does not contain MOOT_BENCH_CMD_INTERNAL")
    func commandStringNotInChildEnvironment() throws {
        // The command dumps its own environment. The shell stub unsets the
        // carrier var before eval, so a command embedding an API key is not
        // inherited by the judge/rerank process or its descendants.
        let result = try lmeRunJudge(cmd: "/usr/bin/env", prompt: "test")
        #expect(!result.contains("MOOT_BENCH_CMD_INTERNAL"),
                "the carrier env var must be unset before the command runs; got: \(result)")
    }

    @Test("G4: reranker child environment also clean")
    func rerankCommandStringNotInChildEnvironment() {
        let result = runRerankSubprocess(cmd: "/usr/bin/env", prompt: "test")
        #expect(result != nil)
        #expect(result?.contains("MOOT_BENCH_CMD_INTERNAL") == false,
                "the carrier env var must be unset before the command runs")
    }
}
