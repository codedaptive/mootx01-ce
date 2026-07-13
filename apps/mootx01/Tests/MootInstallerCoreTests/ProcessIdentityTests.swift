// ProcessIdentityTests.swift
//
// Identity-verified writer-lock liveness (ProcessIdentity.isLiveProcess).
//
// The regression these tests pin: a stale mootx01.pid surviving a reboot
// points at a RECYCLED pid — a live process that is not mootx01 (field
// report: PID 644 → mediaanalysisd). The old bare kill(pid, 0) check
// called that "live", so `serve` refused to start (launchd crash loop)
// and `status` reported a phantom running server. Liveness must require
// process identity, not mere pid existence.

import Testing
import Foundation
@testable import MootInstallerCore

@Suite("ProcessIdentity")
struct ProcessIdentityTests {

    /// The bug case: a LIVE pid whose executable is not mootx01 must not
    /// count as a live writer. The test runner's own pid is guaranteed
    /// live and guaranteed not to be named mootx01.
    @Test func livePidWithForeignIdentityIsNotOurs() {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        #expect(!ProcessIdentity.isLiveProcess(selfPID),
                "the test runner is live but is not a mootx01 binary")
    }

    /// Positive identity path: the same live pid DOES count when the
    /// expected name matches its actual executable.
    @Test func livePidWithMatchingIdentityIsOurs() throws {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let selfName = try #require(Bundle.main.executableURL?.lastPathComponent)
        #expect(ProcessIdentity.isLiveProcess(
            selfPID, executableNamedLike: String(selfName.prefix(4))))
    }

    /// A pid that exists but belongs to another user's process (launchd,
    /// pid 1) is not ours — EPERM on the existence probe must not read as
    /// "live mootx01".
    @Test func foreignUserProcessIsNotOurs() {
        #expect(!ProcessIdentity.isLiveProcess(1))
    }

    /// Nonexistent and invalid pids are dead.
    @Test func deadAndInvalidPidsAreNotLive() {
        // PID_MAX on macOS is 99998; anything above cannot exist.
        #expect(!ProcessIdentity.isLiveProcess(2_000_000))
        #expect(!ProcessIdentity.isLiveProcess(0))
        #expect(!ProcessIdentity.isLiveProcess(-1))
    }
}
