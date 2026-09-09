// ServeInMemoryGateTests.swift — source-shape guard for the in-memory serve gate.
//
// `--in-memory` must not write an `estate.pid` file and must not spawn a
// dreamer or mount the dreaming queue. The gate is `onDisk` (computed as
// `!inMemory && estate.backend == .sqlite`) and must be ANDed into every
// site that writes, removes, or checks the PID file and every dreamer spawn.
//
// These tests inspect the source text of ServeCommand.swift directly because
// the test target cannot import the executable target. A mutation that drops
// the `!inMemory` term from `onDisk` would remove the gate on all dependent
// sites and these tests would fail, catching the regression before it ships.

import Testing
import Foundation

@Suite("ServeCommand in-memory gate (source shape)")
struct ServeInMemoryGateTests {

    private func serveCommandSource() throws -> [String] {
        let here = URL(fileURLWithPath: #filePath)
        let source = here
            .deletingLastPathComponent()   // strip the file name
            .deletingLastPathComponent()   // MootInstallerCoreTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Sources/mootx01/Commands/ServeCommand.swift")
        return try String(contentsOf: source, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// `onDisk` must be computed as `!inMemory && estate.backend == .sqlite`.
    /// Dropping `!inMemory` would allow in-memory serves to write pid files
    /// and spawn dreamers.
    @Test func onDiskIncludesInMemoryTerm() throws {
        let lines = try serveCommandSource()
        let found = lines.contains { $0.contains("!inMemory && estate.backend == .sqlite") }
        #expect(found, "ServeCommand.swift must compute `onDisk` as `!inMemory && estate.backend == .sqlite`")
    }

    /// Every `estate.pid` write and removal must be gated on `onDisk` so that
    /// in-memory serves never touch the filesystem estate directory.
    @Test func pidWriteAndRemoveGatedOnOnDisk() throws {
        let lines = try serveCommandSource()
        for (index, line) in lines.enumerated() where line.contains("pidURL, atomically: true") {
            // The PID write is inside an `if residentPort != nil, onDisk {` block;
            // look back 10 lines to find the guard.
            let window = lines[max(0, index - 10)..<index].joined(separator: "\n")
            let gated = window.contains("onDisk") || line.contains("onDisk")
            #expect(gated, "pidURL write at line \(index + 1) is not gated on onDisk")
        }
        // Guard `removeItem(at: pidURL)` calls that are NOT part of the stale-pid
        // cleanup (which is inside a guard that already has onDisk). Look back 12
        // lines to cover both the defer cleanup and the stale-pid branch.
        for (index, line) in lines.enumerated()
        where line.contains("removeItem(at: pidURL)") && !line.hasPrefix("//") {
            let window = lines[max(0, index - 12)..<index].joined(separator: "\n")
            let gated = window.contains("onDisk") || line.contains("onDisk")
            #expect(gated, "pidURL removal at line \(index + 1) is not gated on onDisk")
        }
    }

    /// The dreaming queue must only be mounted when `onDisk`. An in-memory estate
    /// has no queue.sqlite to mount.
    @Test func dreamingQueueMountGatedOnOnDisk() throws {
        let source = try serveCommandSource()
        // Match only actual call sites, not comments referencing the function name.
        for (index, line) in source.enumerated()
        where line.contains("kit.mountDreamingQueue") {
            let window = source[max(0, index - 2)..<index].joined(separator: "\n")
            let gated = window.contains("onDisk") || line.contains("onDisk")
            #expect(gated, "mountDreamingQueue at line \(index + 1) is not gated on onDisk")
        }
    }

    /// The periodic dreamer must be gated on `onDisk` so that in-memory stdio
    /// serves do not start a timer that would try to spawn a dream process.
    @Test func periodicDreamerGatedOnOnDisk() throws {
        let lines = try serveCommandSource()
        let found = lines.contains {
            $0.contains("posture == .live && onDisk ? Task") ||
            $0.contains("posture == .live && onDisk")
        }
        #expect(found, "periodic dreamer Task must be gated on `posture == .live && onDisk`")
    }
}
