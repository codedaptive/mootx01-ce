// ResidentDaemonQuiesce.swift
//
// The one place `mootx01 upgrade` stops and restarts the resident daemon
// around a data-directory step. Every step routes through `run`, so the
// rule "quiesce only when the estate being upgraded is the resident one"
// is decided once, and the stop → work → restart shape cannot drift
// between steps.

import EstateEncryption
import Foundation

public enum ResidentDaemonQuiesce {

    /// Run `work` with the resident daemon quiesced when `dataDirectory`
    /// is the resident estate; otherwise run it with the daemon untouched.
    ///
    /// Resident estate (`MootPaths.isResidentEstate`): capture whether the
    /// daemon is running, stop it — single-writer discipline, because the
    /// step opens the estate SQLite the daemon has open — run `work`, then
    /// start the daemon again if it was running. The restart happens on
    /// every outcome of `work`, so a failed step never leaves the daemon
    /// down.
    ///
    /// Not the resident estate: print one line naming the directory so an
    /// operator sees why nothing restarted, then run `work`. The daemon
    /// serves a different estate and has no stake in this one.
    ///
    /// Unreadable registration (`MootPaths.ResidentDataDirectory
    /// .unreadableRegistration`): print the registration warning, then
    /// proceed exactly as for the resident estate. SAFETY: an estate the
    /// daemon may hold open is never migrated under a running daemon.
    ///
    /// - Parameters:
    ///   - dataDirectory: the data directory the step will open.
    ///   - residentDataDirectory: the daemon's data directory, from
    ///     `MootPaths.residentDataDirectory(homeDirectory:)`.
    ///   - step: the step's operator-facing name, used in the skip line.
    ///   - daemon: the daemon control seam. `.launchd(homeDirectory:)` in
    ///     the executable; tests inject a recorder.
    ///   - work: the step body.
    /// - Returns: `work`'s result, or `nil` when the daemon was running
    ///   and would not stop — the step is skipped, nothing is half-done,
    ///   and the next `mootx01 upgrade` retries.
    public static func run<T>(
        dataDirectory: URL,
        residentDataDirectory: MootPaths.ResidentDataDirectory,
        step: String,
        daemon: EstateEncryptionMigrator.DaemonControl,
        work: () async -> T
    ) async -> T? {
        guard MootPaths.isResidentEstate(
            dataDirectory: dataDirectory, residentDataDirectory: residentDataDirectory)
        else {
            print("  data directory \(dataDirectory.path) is not the resident estate; daemon left running")
            return await work()
        }
        if let warning = residentDataDirectory.registrationWarning(for: dataDirectory) {
            print(warning)
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
}
