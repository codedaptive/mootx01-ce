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
    /// The daemon is already held down by an enclosing `hold`; every step
    /// `run` inside it runs its work without stopping or starting anything.
    /// Task-local so the hold follows the sequence it wraps and nothing else.
    @TaskLocal static var heldByEnclosingHold = false

    /// Quiesce the resident daemon ONCE around a whole sequence of steps.
    /// Every step still calls `run`; inside the hold it finds the daemon
    /// already stopped and just does its work. One stop and one start per
    /// upgrade: each restart of the resident on an encrypted estate is a
    /// Keychain read, and the per-step quiesce cost the operator one prompt
    /// per migration step (six on 2026-09-17).
    public static func hold<T>(
        estatePIDURL: URL,
        daemon: EstateEncryptionMigrator.DaemonControl,
        sequence: () async -> T
    ) async -> T? {
        await hold(residentServes: residentServes(pidURL: estatePIDURL), daemon: daemon, sequence: sequence)
    }

    /// The decision already made; tests inject it. Returns nil only when the
    /// daemon would not stop, in which case nothing in the sequence runs.
    public static func hold<T>(
        residentServes: Bool,
        daemon: EstateEncryptionMigrator.DaemonControl,
        sequence: () async -> T
    ) async -> T? {
        guard residentServes else {
            print("  no live resident serves this estate; daemon left running")
            return await $heldByEnclosingHold.withValue(true) { await sequence() }
        }
        let wasRunning = daemon.isRunning()
        if wasRunning && !daemon.stop() {
            print("  ✗ estate migration skipped — the resident daemon would not stop; run `mootx01 upgrade` again")
            return nil
        }
        let result = await $heldByEnclosingHold.withValue(true) { await sequence() }
        if wasRunning {
            _ = daemon.start()
        }
        return result
    }


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
        if heldByEnclosingHold {
            return await work()
        }
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
