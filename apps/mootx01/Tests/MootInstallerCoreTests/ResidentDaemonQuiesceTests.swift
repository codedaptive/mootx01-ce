// ResidentDaemonQuiesceTests.swift
//
// The upgrade-time quiesce helper, driven with a recording daemon control
// so every test can state exactly which daemon calls a step made. No
// launchctl is ever reached: the recorder IS the daemon.

import EstateEncryption
import Foundation
import GeniusLocusKit
import Testing
@testable import MootInstallerCore

/// Records every daemon-control call in order.
private final class DaemonRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let running: Bool
    private let stopSucceeds: Bool

    init(running: Bool, stopSucceeds: Bool = true) {
        self.running = running
        self.stopSucceeds = stopSucceeds
    }

    var calls: [String] { lock.withLock { recorded } }

    private func record(_ call: String) { lock.withLock { recorded.append(call) } }

    var control: EstateEncryptionMigrator.DaemonControl {
        EstateEncryptionMigrator.DaemonControl(
            isRunning: { self.record("isRunning"); return self.running },
            stop: { self.record("stop"); return self.stopSucceeds },
            start: { self.record("start"); return true })
    }
}

@Suite("ResidentDaemonQuiesce")
struct ResidentDaemonQuiesceTests {

    /// The one input the helper takes: whether a live resident serves the
    /// estate the step will open. Production derives it from the estate's own
    /// PID marker (`residentServes(pidURL:)`); these tests inject it.

    @Test("an estate no resident serves runs the work and never touches the daemon")
    func unservedEstateNeverTouchesTheDaemon() async {
        let daemon = DaemonRecorder(running: true)
        var ran = false
        let result = await ResidentDaemonQuiesce.run(
            residentServes: false,
            step: "kg_facts identity backfill", daemon: daemon.control
        ) { ran = true; return true }
        #expect(result == true)
        #expect(ran)
        #expect(daemon.calls.isEmpty)
    }

    @Test("a served estate stops a running daemon and restarts it after the work")
    func servedEstateStopsThenRestarts() async {
        let daemon = DaemonRecorder(running: true)
        var order: [String] = []
        let result = await ResidentDaemonQuiesce.run(
            residentServes: true,
            step: "daemon stop restart test", daemon: daemon.control
        ) { order.append("work"); return true }
        #expect(result == true)
        #expect(order == ["work"])
        #expect(daemon.calls == ["isRunning", "stop", "start"])
    }

    @Test("a failed step still restarts the daemon")
    func failedWorkStillRestarts() async {
        let daemon = DaemonRecorder(running: true)
        let result = await ResidentDaemonQuiesce.run(
            residentServes: true,
            step: "shared-content reclaim", daemon: daemon.control
        ) { false }
        #expect(result == false)
        #expect(daemon.calls == ["isRunning", "stop", "start"])
    }

    @Test("a served estate with no daemon running neither stops nor starts one")
    func servedEstateWithDaemonDownNeverStartsOne() async {
        let daemon = DaemonRecorder(running: false)
        let result = await ResidentDaemonQuiesce.run(
            residentServes: true,
            step: "distilled representation convergence", daemon: daemon.control
        ) { true }
        #expect(result == true)
        #expect(daemon.calls == ["isRunning"])
    }

    @Test("a daemon that will not stop skips the work and reports nil")
    func daemonThatWillNotStopSkipsTheWork() async {
        let daemon = DaemonRecorder(running: true, stopSucceeds: false)
        var ran = false
        let result: Bool? = await ResidentDaemonQuiesce.run(
            residentServes: true,
            step: "kg_facts identity backfill", daemon: daemon.control
        ) { ran = true; return true }
        #expect(result == nil)
        #expect(!ran)
        #expect(daemon.calls == ["isRunning", "stop"])
    }

    @Test("the PID marker decides: absent, dead or our own pid means no resident")
    func pidMarkerDecidesResidency() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quiesce-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidURL = dir.appendingPathComponent("estate.pid")
        #expect(!ResidentDaemonQuiesce.residentServes(pidURL: pidURL))            // absent
        try "999999".write(to: pidURL, atomically: true, encoding: .utf8)
        #expect(!ResidentDaemonQuiesce.residentServes(pidURL: pidURL))            // dead
        try String(ProcessInfo.processInfo.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
        #expect(!ResidentDaemonQuiesce.residentServes(pidURL: pidURL))            // ourselves
        try "not a pid".write(to: pidURL, atomically: true, encoding: .utf8)
        #expect(!ResidentDaemonQuiesce.residentServes(pidURL: pidURL))            // garbage
    }

    /// A live process whose executable is NOT a mootx01 binary must be rejected
    /// by the identity gate even though `kill(pid, 0)` succeeds. Proves that
    /// `ProcessIdentity.isLiveProcess` uses `proc_pidpath` on macOS (or
    /// `/proc/<pid>/comm` on Linux) and not bare existence alone.
    ///
    /// Mutation proof: replacing `name.hasPrefix("mootx01")` with `true` in
    /// `ProcessIdentity.isLiveProcess` would make this test fail, because the
    /// sleep(1) child is live and signallable.
    @Test("a live non-mootx01 process does not pass the resident identity gate")
    func liveNonMootx01ProcessIsNotServed() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quiesce-foreign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pidURL = dir.appendingPathComponent("estate.pid")
        // Spawn a child process whose executable name does not start with
        // "mootx01" — sleep(1) lives at /bin/sleep.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }
        // Write the child's PID so the marker-absent and dead-pid checks pass.
        try String(child.processIdentifier).write(to: pidURL, atomically: true, encoding: .utf8)
        // The identity gate must reject the non-mootx01 binary even though the
        // process is live and signallable.
        let result = ResidentDaemonQuiesce.residentServes(pidURL: pidURL)
        #expect(!result,
            "live sleep(1) process must not pass the mootx01 identity gate")
    }

    /// `EstateRecord.pidURL` returns the PID file inside the estate directory
    /// (not at the catalog root). StatusCommand uses this to find the correct
    /// PID file regardless of which estate is active.
    @Test("estate record's pidURL is estate.pid inside the estate directory, not at the catalog root")
    func pidURLIsInsideEstateDirectory() {
        let estateDir = URL(fileURLWithPath: "/tmp/test-estate", isDirectory: true)
        let record = EstateRecord(
            name: "default",
            directory: estateDir,
            kind: .registered,
            backend: .sqlite
        )
        #expect(record.pidURL == estateDir.appendingPathComponent("estate.pid"))
        #expect(!record.pidURL.path.contains("mootx01.pid"),
                "pidURL must not use the legacy catalog-root path")
    }
}
