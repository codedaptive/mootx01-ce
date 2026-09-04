// DbCommandSourceTests.swift
//
// Source invariants for `mootx01 db composition --set`: the rebuild routes
// its daemon quiesce through ResidentDaemonQuiesce (whose stop / restart /
// leave-alone / never-start rules ResidentDaemonQuiesceTests pin with a
// recording daemon) and drains the encode queue before the rebuild. launchd
// is not testable headless, so the routing is checked statically, the same
// way UpgradeCommandSourceTests checks the upgrade steps.

import Foundation
import Testing

@Suite("DbCommand source invariants")
struct DbCommandSourceTests {
    private static var commandSourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/mootx01
            .appendingPathComponent("Sources/mootx01/Commands/DbCommand.swift")
    }

    @Test("db composition --set quiesces through ResidentDaemonQuiesce and drains before the rebuild")
    func compositionSetQuiescesAndDrainsFirst() throws {
        let source = try String(contentsOf: Self.commandSourceURL, encoding: .utf8)
        let start = try #require(source.range(of: "struct DbCompositionCommand")?.lowerBound)
        let body = source[start...]

        // The one quiesce call, on the --set arm, through the shared helper.
        #expect(body.components(separatedBy: "ResidentDaemonQuiesce.run(").count == 2,
                "--set routes its quiesce through the shared helper exactly once; show never quiesces")
        #expect(body.contains("residentDataDirectory: MootPaths.residentDataDirectory(homeDirectory: home)"),
                "the quiesce compares against the resident data directory")
        #expect(body.contains("daemon: .launchd(homeDirectory: home)"),
                "the quiesce is handed the launchd seam")
        #expect(body.contains("step: \"index composition rebuild\""))
        #expect(!body.contains("LaunchAgent.stopDaemon"))
        #expect(!body.contains("LaunchAgent.startDaemon"))
        #expect(!body.contains("LaunchAgent.isDaemonRunning"))

        // The encode queue drains to empty after the wire and before the
        // rebuild, never after it.
        let wire = try #require(body.range(of: "wireGLKSubstores(for: handle, backingStorage: storage, reindexPending: true)")?.upperBound)
        let drain = try #require(body.range(of: "awaitEncodeDrain(for: handle)", range: wire..<body.endIndex)?.upperBound)
        let reindex = try #require(body.range(of: "reindexCorpus(handle: handle", range: drain..<body.endIndex)?.lowerBound)
        #expect(wire < drain && drain < reindex)
    }
}
