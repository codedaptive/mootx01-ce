// ResidentDaemonQuiesceTests.swift
//
// The upgrade-time quiesce helper, driven with a recording daemon control
// so every test can state exactly which daemon calls a step made. No
// launchctl is ever reached: the recorder IS the daemon.

import EstateEncryption
import Foundation
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

    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    private var resident: URL { MootPaths.residentDataDirectory(homeDirectory: home) }
    private var scratch: URL {
        MootPaths.resolveDataDirectory(
            environment: ["MOOTX01_DATA_DIR": "/Users/test/Library/Application Support/com.mootx01.ce-bench"],
            homeDirectory: home)
    }

    @Test("a scratch estate runs the work and never touches the daemon")
    func scratchEstateNeverTouchesTheDaemon() async {
        let daemon = DaemonRecorder(running: true)
        var ran = false
        let result = await ResidentDaemonQuiesce.run(
            dataDirectory: scratch, residentDataDirectory: resident,
            step: "kg_facts identity backfill", daemon: daemon.control
        ) { ran = true; return true }
        #expect(result == true)
        #expect(ran)
        #expect(daemon.calls.isEmpty)
    }

    @Test("the resident estate stops a running daemon and restarts it after the work")
    func residentEstateStopsThenRestarts() async {
        let daemon = DaemonRecorder(running: true)
        var order: [String] = []
        let result = await ResidentDaemonQuiesce.run(
            dataDirectory: resident, residentDataDirectory: resident,
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
            dataDirectory: resident, residentDataDirectory: resident,
            step: "shared-content reclaim", daemon: daemon.control
        ) { false }
        #expect(result == false)
        #expect(daemon.calls == ["isRunning", "stop", "start"])
    }

    @Test("the resident estate with no daemon running neither stops nor starts one")
    func residentEstateWithDaemonDownNeverStartsOne() async {
        let daemon = DaemonRecorder(running: false)
        let result = await ResidentDaemonQuiesce.run(
            dataDirectory: resident, residentDataDirectory: resident,
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
            dataDirectory: resident, residentDataDirectory: resident,
            step: "kg_facts identity backfill", daemon: daemon.control
        ) { ran = true; return true }
        #expect(result == nil)
        #expect(!ran)
        #expect(daemon.calls == ["isRunning", "stop"])
    }
}
