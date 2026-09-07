#if MOOTX01_MINERS
import Darwin
import Foundation
import Testing
@testable import AdornmentLib

@Suite("CommandEngine resident lifecycle", .serialized)
struct CommandEngineLifecycleTests {
    private struct FakeMinter {
        let directory: URL
        let executable: String
    }

    private func makeFakeMinter(
        expectedBaseArguments: [String] = []
    ) throws -> FakeMinter {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("command-engine-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-mint.py")
        let crashMarker = directory.appendingPathComponent("crashed-once").path
        let expected = String(reflecting: expectedBaseArguments)
        let lines = [
            "#!/usr/bin/env python3",
            "import os, sys, time",
            "expected = \(expected)",
            "if sys.argv[1:-1] != expected:",
            "    print(f'bad base args: {sys.argv[1:-1]!r}', file=sys.stderr)",
            "    sys.exit(20)",
            "mode = sys.argv[-1] if len(sys.argv) > 1 else ''",
            "if mode == '--mint-capabilities':",
            "    print('batch'); sys.exit(0)",
            "if mode != '--batch':",
            "    sys.exit(21)",
            "buf = b''",
            "while True:",
            "    ch = sys.stdin.buffer.read(1)",
            "    if not ch:",
            "        sys.exit(0)",
            "    if ch != b'\\0':",
            "        buf += ch; continue",
            "    prompt = buf.decode('utf-8'); buf = b''",
            "    if prompt == 'crash-once' and not os.path.exists(\(String(reflecting: crashMarker))):",
            "        open(\(String(reflecting: crashMarker)), 'w').close()",
            "        sys.exit(91)",
            "    if prompt == 'always-crash':",
            "        sys.exit(92)",
            "    if prompt == 'slow-first':",
            "        time.sleep(0.1)",
            "    if prompt == 'empty':",
            "        reply = b''",
            "    else:",
            "        reply = f'{os.getpid()}:{prompt}'.encode('utf-8')",
            "    sys.stdout.buffer.write(reply + b'\\0')",
            "    sys.stdout.flush()",
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return FakeMinter(directory: directory, executable: script.path)
    }

    private func pid(from response: String?) throws -> String {
        String(try #require(response).split(separator: ":", maxSplits: 1)[0])
    }

    private func withShutdown<T: Sendable>(
        _ engine: CommandEngine,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            let result = try await operation()
            await engine.shutdown()
            return result
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    @Test("concurrent callers cannot interleave one ordered NUL stream")
    func residentStreamIsSerialized() async throws {
        let fake = try makeFakeMinter()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let engine = CommandEngine(
            command: fake.executable,
            lifecyclePolicy: ResidentMintLifecyclePolicy(
                maxRequestsPerProcess: 16,
                maxCrashRetries: 1,
                gracefulEOFShutdown: true))

        try await withShutdown(engine) {
            let firstTask = Task { await engine.mint(prompt: "slow-first") }
            try await Task.sleep(nanoseconds: 20_000_000)
            let secondTask = Task { await engine.mint(prompt: "second") }
            let first = await firstTask.value
            let second = await secondTask.value

            #expect(first?.hasSuffix(":slow-first") == true)
            #expect(second?.hasSuffix(":second") == true)
            #expect(try pid(from: first) == pid(from: second))
        }
    }

    @Test("Core AI launch passes fixed args and forces one child")
    func coreAILaunchIsExactAndSingleProcess() async throws {
        let expected = [
            "coreai-mint-worker",
            "--asset", "/models/qwen3-q8.aimodel",
            "--tokenizer", "/models/qwen3/tokenizer.json",
            "--style", "chat3",
            "--max-new-tokens", "256",
            "--identity", "qwen3-q8",
        ]
        let fake = try makeFakeMinter(expectedBaseArguments: expected)
        defer { try? FileManager.default.removeItem(at: fake.directory) }

        let oldWidth = getenv("MOOT_MINT_WIDTH").map { String(cString: $0) }
        let oldRows = getenv("MOOT_MINT_ROWS").map { String(cString: $0) }
        setenv("MOOT_MINT_WIDTH", "8", 1)
        setenv("MOOT_MINT_ROWS", "1", 1)
        defer {
            if let oldWidth { setenv("MOOT_MINT_WIDTH", oldWidth, 1) }
            else { unsetenv("MOOT_MINT_WIDTH") }
            if let oldRows { setenv("MOOT_MINT_ROWS", oldRows, 1) }
            else { unsetenv("MOOT_MINT_ROWS") }
        }

        let engine = CommandEngine(
            coreAIWorkerExecutable: fake.executable,
            assetPath: "/models/qwen3-q8.aimodel",
            tokenizerPath: "/models/qwen3/tokenizer.json",
            style: .chat3,
            maxNewTokens: 256,
            identity: "qwen3-q8")

        try await withShutdown(engine) {
            #expect(engine.maxConcurrentMints == 1)
            #expect(engine.identity == "qwen3-q8")
            #expect(engine.supportsRowBatching == false)
            #expect((await engine.mint(prompt: "hello"))?.hasSuffix(":hello") == true)
            let snapshot = await engine.lifecycleSnapshot()
            #expect(snapshot.logicalRequests == 1)
            #expect(snapshot.processStarts == 1)
            #expect(snapshot.activeChildren == 1)
        }
        #expect((await engine.lifecycleSnapshot()).activeChildren == 0)
    }

    @Test("request bound recycles before the next prompt")
    func requestBoundRecycles() async throws {
        let fake = try makeFakeMinter()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let engine = CommandEngine(
            command: fake.executable,
            lifecyclePolicy: ResidentMintLifecyclePolicy(
                maxRequestsPerProcess: 2,
                maxCrashRetries: 1,
                gracefulEOFShutdown: true))

        try await withShutdown(engine) {
            let firstPID = try pid(from: await engine.mint(prompt: "one"))
            let secondPID = try pid(from: await engine.mint(prompt: "two"))
            let thirdPID = try pid(from: await engine.mint(prompt: "three"))
            #expect(firstPID == secondPID)
            #expect(thirdPID != firstPID)

            let snapshot = await engine.lifecycleSnapshot()
            #expect(snapshot.logicalRequests == 3)
            #expect(snapshot.requestAttempts == 3)
            #expect(snapshot.processStarts == 2)
            #expect(snapshot.boundedRecycles == 1)
            #expect(snapshot.requestsInActiveChildren == 1)
        }
    }

    @Test("an unexpected exit retries each request at most once")
    func crashRetryIsBounded() async throws {
        let fake = try makeFakeMinter()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let engine = CommandEngine(
            command: fake.executable,
            lifecyclePolicy: ResidentMintLifecyclePolicy(
                maxRequestsPerProcess: 16,
                maxCrashRetries: 1,
                gracefulEOFShutdown: true))

        try await withShutdown(engine) {
            #expect((await engine.mint(prompt: "crash-once"))?
                .hasSuffix(":crash-once") == true)
            #expect(await engine.mint(prompt: "always-crash") == nil)

            let snapshot = await engine.lifecycleSnapshot()
            #expect(snapshot.logicalRequests == 2)
            #expect(snapshot.requestAttempts == 4)
            #expect(snapshot.processStarts == 3)
            #expect(snapshot.unexpectedExits == 3)
            #expect(snapshot.crashRetries == 2)
            #expect(snapshot.activeChildren == 0)
        }
    }

    @Test("idle reaping and per-prompt failures are visible")
    func idleAndFailureCountersAreVisible() async throws {
        let fake = try makeFakeMinter()
        defer { try? FileManager.default.removeItem(at: fake.directory) }
        let engine = CommandEngine(
            command: fake.executable,
            lifecyclePolicy: ResidentMintLifecyclePolicy(
                idleSeconds: 0,
                maxCrashRetries: 1,
                gracefulEOFShutdown: true))

        try await withShutdown(engine) {
            #expect(await engine.mint(prompt: "empty") == nil)
            for _ in 0..<50 {
                if (await engine.lifecycleSnapshot()).idleReaps == 1 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let snapshot = await engine.lifecycleSnapshot()
            #expect(snapshot.perPromptFailures == 1)
            #expect(snapshot.idleReaps == 1)
            #expect(snapshot.activeChildren == 0)
        }
    }
}
#endif // MOOTX01_MINERS: the library compiles to nothing with the switch off, so do its tests.
