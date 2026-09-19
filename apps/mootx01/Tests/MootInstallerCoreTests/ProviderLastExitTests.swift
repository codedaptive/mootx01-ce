// ProviderLastExitTests.swift
//
// The reader that turns the provider's own exit report into the lines
// `mootx01 status` and `mootx01 install` print beneath a registered provider
// that is not hosting. Filesystem tests use a fresh UUID-named temp home per
// test, so the suite is safe under swift-testing's parallel execution.

import Foundation
import Testing
@testable import MootInstallerCore

@Suite("ProviderLastExit")
struct ProviderLastExitTests {

    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("provider-last-exit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: MootPaths.logsDirURL(homeDirectory: home), withIntermediateDirectories: true
        )
        return home
    }

    @Test("the last resident report wins, and serve-loop chatter is skipped")
    func parsePicksLastResidentReport() {
        let text = """
        {"mode":"resident","outcome":"startup-failed","reason":"pre-bind-failed: busy"}
        listening on 4242
        {"mode":"census","disposition":"none-found"}
        {"mode":"resident","moduleDigest":"abc","outcome":"startup-failed","reason":"activation-failed: matrix storage upgrade required; run mootx01 upgrade with the estate stopped"}
        not json at all
        """
        let last = ProviderLastExit.parse(text)
        #expect(last?.outcome == "startup-failed")
        #expect(last?.reason == "activation-failed: matrix storage upgrade required; run mootx01 upgrade with the estate stopped")
    }

    @Test("a clean shutdown carries no reason")
    func parseCleanShutdown() {
        let last = ProviderLastExit.parse(#"{"mode":"resident","outcome":"clean-shutdown"}"#)
        #expect(last == ProviderLastExit(outcome: "clean-shutdown", reason: nil))
    }

    @Test("no resident report means nil, not a guess")
    func parseNothing() {
        #expect(ProviderLastExit.parse("") == nil)
        #expect(ProviderLastExit.parse("plain log line\n{\"mode\":\"census\"}\n") == nil)
        #expect(ProviderLastExit.parse(#"{"mode":"resident"}"#) == nil)
    }

    @Test("the log path is the plist writer's stdout path")
    func logPathMatchesPlist() throws {
        let home = try temporaryHome()
        let plist = LaunchAgent.makeDaemonBundlePlistEnabled(homeDirectory: home)
        #expect(plist.contains(ProviderLastExit.logURL(homeDirectory: home).path))
    }

    @Test("an absent log explains itself and still names the log")
    func explanationWithoutLog() throws {
        let home = try temporaryHome()
        let lines = ProviderLastExit.explanationLines(homeDirectory: home)
        #expect(lines.count == 2)
        #expect(lines[0].contains("has not recorded an exit"))
        #expect(lines[1].contains(LaunchAgent.providerStdoutLogName))
    }

    @Test("a recorded failure is quoted verbatim from the log")
    func explanationReadsLog() throws {
        let home = try temporaryHome()
        let report = #"{"mode":"resident","outcome":"startup-failed","reason":"activation-failed: needs upgrade"}"#
        try (report + "\n").write(
            to: ProviderLastExit.logURL(homeDirectory: home), atomically: true, encoding: .utf8
        )
        let lines = ProviderLastExit.explanationLines(homeDirectory: home)
        #expect(lines[0] == "  Last provider exit: startup-failed — activation-failed: needs upgrade")
        #expect(ProviderLastExit.read(homeDirectory: home)?.reason == "activation-failed: needs upgrade")
    }

    @Test("only the tail of a long log is read, and a cut line is skipped")
    func readTailOfLongLog() throws {
        let home = try temporaryHome()
        var text = ""
        for i in 0..<3_000 {
            text += #"{"mode":"resident","outcome":"startup-failed","reason":"attempt \#(i)"}"# + "\n"
        }
        try text.write(to: ProviderLastExit.logURL(homeDirectory: home), atomically: true, encoding: .utf8)
        #expect(ProviderLastExit.read(homeDirectory: home)?.reason == "attempt 2999")
    }
}
