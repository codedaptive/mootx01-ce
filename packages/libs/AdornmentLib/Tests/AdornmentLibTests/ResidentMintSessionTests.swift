// ResidentMintSessionTests.swift — batch-protocol tests for the resident
// minter seam (capability-probe selected: CMD --mint-capabilities lists 'batch').
//
// A fake minter (python3 script speaking the NUL protocol) stands in for
// candle-mint. It answers each prompt with "<pid>:<prompt-prefix>" so the
// tests can prove BOTH the protocol round-trip and that consecutive mints
// reuse ONE resident process — the entire point of the mode.

import Darwin
import Foundation
import Testing
@testable import AdornmentLib

@Suite("ResidentMintSession", .serialized)
struct ResidentMintSessionTests {

    /// Write the fake batch minter to a temp path and return it.
    private func makeFakeMinter(failOn: String? = nil) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-minter-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("fake-mint.py")
        // Assembled as joined lines: python is indentation-sensitive and a
        // Swift multi-line literal re-indents interpolations unpredictably.
        var lines = [
            "#!/usr/bin/env python3",
            "import os, sys",
            "if '--mint-capabilities' in sys.argv:",
            "    print('batch'); sys.exit(0)",
            "if '--batch' not in sys.argv:",
            "    sys.exit(3)  # tests only exercise batch mode",
            "buf = b''",
            "while True:",
            "    ch = sys.stdin.buffer.read(1)",
            "    if not ch:",
            "        sys.exit(0)",
            "    if ch != b'\\0':",
            "        buf += ch",
            "        continue",
            "    prompt = buf.decode('utf-8'); buf = b''",
        ]
        if let failOn {
            lines.append("    if \(String(reflecting: failOn)) in prompt:")
            lines.append("        sys.stdout.buffer.write(b'\\0'); sys.stdout.flush(); continue")
        }
        lines.append("    reply = f\"{os.getpid()}:{prompt[:20]}\"")
        lines.append("    sys.stdout.buffer.write(reply.encode('utf-8') + b'\\0')")
        lines.append("    sys.stdout.flush()")
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    @Test("round-trip: two mints answered in order by ONE resident process")
    func residentReuse() async throws {
        let cmd = try makeFakeMinter()
        setenv("MOOT_MINT_CMD", cmd, 1)
        defer { unsetenv("MOOT_MINT_CMD") }

        let a = await invokeAdornmentCommand(prompt: "first prompt body", maxLength: 280)
        let b = await invokeAdornmentCommand(prompt: "second prompt body", maxLength: 280)
        let pa = try #require(a).split(separator: ":", maxSplits: 1)
        let pb = try #require(b).split(separator: ":", maxSplits: 1)
        #expect(pa[1] == "first prompt body")
        #expect(pb[1] == "second prompt body")
        // Same pid on both replies = one model load served both prompts.
        #expect(pa[0] == pb[0], "consecutive mints must reuse the resident process")
    }

    @Test("per-prompt failure (bare NUL) yields nil and the session survives")
    func perPromptFailureIsolated() async throws {
        let cmd = try makeFakeMinter(failOn: "POISON")
        setenv("MOOT_MINT_CMD", cmd, 1)
        defer { unsetenv("MOOT_MINT_CMD") }

        let bad = await invokeAdornmentCommand(prompt: "POISON pill", maxLength: 280)
        #expect(bad == nil, "empty batch response must count as a failed pair")
        let good = await invokeAdornmentCommand(prompt: "healthy prompt", maxLength: 280)
        #expect(try #require(good).hasSuffix("healthy prompt"))
    }

    @Test("batchFrame strips embedded NUL so exactly one terminator remains")
    func batchFrameStripsNUL() {
        // Cross-port pin: the Rust twin asserts the same byte sequence.
        let frame = ResidentMintSession.batchFrame("ab\u{0}cd")
        #expect(Array(frame) == [0x61, 0x62, 0x63, 0x64, 0x00])
    }

    @Test("a NUL inside a prompt does not shift later replies")
    func embeddedNULKeepsFramesAligned() async throws {
        let cmd = try makeFakeMinter()
        setenv("MOOT_MINT_CMD", cmd, 1)
        defer { unsetenv("MOOT_MINT_CMD") }

        // Untrusted drawer content with U+0000 in the middle: without
        // stripping, the child would answer TWO frames and the next
        // logical prompt would receive the second half's reply.
        let first = await invokeAdornmentCommand(prompt: "left\u{0}right", maxLength: 280)
        let second = await invokeAdornmentCommand(prompt: "second prompt", maxLength: 280)
        let pa = try #require(first).split(separator: ":", maxSplits: 1)
        let pb = try #require(second).split(separator: ":", maxSplits: 1)
        #expect(pa[1] == "leftright")
        #expect(pb[1] == "second prompt")
        #expect(pa[0] == pb[0], "one resident process answered both prompts")
    }

    @Test("truncation applies to batch responses")
    func truncation() async throws {
        let cmd = try makeFakeMinter()
        setenv("MOOT_MINT_CMD", cmd, 1)
        defer { unsetenv("MOOT_MINT_CMD") }

        let out = await invokeAdornmentCommand(prompt: "abcdefghij", maxLength: 5)
        #expect(try #require(out).count == 5)
    }
}
