// ResidentDaemonQuiesce.swift
//
// The one place `mootx01 upgrade` stops and restarts the resident daemon
// around an estate migration step. Every step routes through `run`, so the
// rule "quiesce only when the estate being upgraded is the resident one"
// is decided once, and the stop → work → restart shape cannot drift
// between steps.

import EstateEncryption
import Foundation

public enum ResidentDaemonQuiesce {

    /// Quiesce the resident daemon around `work` when the estate's own PID
    /// marker names a live mootx01 process: that is the one fact that says a
    /// resident serves THIS estate. No marker, or a dead one, and the daemon is
    /// left running because it is serving some other estate or nothing.
    public static func run<T>(
        estatePIDURL: URL,
        step: String,
        daemon: EstateEncryptionMigrator.DaemonControl,
        work: () async -> T
    ) async -> T? {
        await run(residentServes: residentServes(pidURL: estatePIDURL), step: step, daemon: daemon, work: work)
    }

    /// The decision already made: `residentServes` says whether a live resident
    /// serves the estate the step will open. Tests inject it directly.
    public static func run<T>(
        residentServes: Bool,
        step: String,
        daemon: EstateEncryptionMigrator.DaemonControl,
        work: () async -> T
    ) async -> T? {
        guard residentServes else {
            print("  no live resident serves this estate; daemon left running")
            return await work()
        }
        let wasRunning = daemon.isRunning()
        if wasRunning && !daemon.stop() {
            print("  ✗ \(step) skipped — the resident daemon would not stop; run `mootx01 upgrade` again")
            return nil
        }
        let result = await work()
        if wasRunning {
            _ = daemon.start()
        }
        return result
    }

    /// True when `pidURL` names a live, identity-verified mootx01 process other
    /// than this one. Twin of the check `serve` makes before forwarding (T4).
    public static func residentServes(pidURL: URL) -> Bool {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != ProcessInfo.processInfo.processIdentifier
        else { return false }
        return ProcessIdentity.isLiveProcess(pid)
    }

}
