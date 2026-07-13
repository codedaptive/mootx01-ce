// ProcessIdentity.swift
//
// Identity-verified process liveness for the estate writer-lock PID file.
//
// A bare `kill(pid, 0)` existence check is UNSOUND across reboots: PIDs
// are recycled, so a stale `mootx01.pid` left by a crash or power loss can
// point at an unrelated live process (field report: PID 644 recycled to
// mediaanalysisd after reboot). The serve guard then refuses to start —
// launchd restarts it, it refuses again, and the daemon crash-loops while
// `status` reports "running". Liveness for the writer lock therefore
// requires BOTH: the process exists AND its executable is actually a
// mootx01 binary.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum ProcessIdentity {

    /// True when `pid` is a live process AND its executable name starts
    /// with `executableNamedLike` (default: the product binary name).
    ///
    /// Identity resolution: macOS `proc_pidpath` (libproc via libSystem);
    /// Linux `/proc/<pid>/comm`. When the process exists but cannot be
    /// identified (e.g. EPERM on another user's process), it is treated as
    /// NOT ours: the resident daemon runs as the invoking user, so a
    /// same-estate writer is always inspectable — anything else is a
    /// recycled PID, not our lock holder.
    public static func isLiveProcess(
        _ pid: Int32,
        executableNamedLike expectedPrefix: String = "mootx01"
    ) -> Bool {
        guard pid > 0 else { return false }
        // Existence gate: 0 = exists and signallable; EPERM = exists but
        // owned elsewhere (falls through to identity, which will refuse it).
        if kill(pid, 0) != 0 && errno != EPERM { return false }

        #if canImport(Darwin)
        // PROC_PIDPATHINFO_MAXSIZE (4 × MAXPATHLEN) — proc_pidpath refuses
        // smaller buffers outright rather than truncating.
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return false }
        let path = String(cString: buffer)
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix(expectedPrefix)
        #elseif canImport(Glibc)
        // /proc/<pid>/comm is the kernel's 15-char executable name.
        guard let comm = try? String(
            contentsOfFile: "/proc/\(pid)/comm", encoding: .utf8) else { return false }
        return comm.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix(expectedPrefix)
        #else
        // Unknown platform: no identity source — never claim the lock holder
        // is live on existence alone.
        return false
        #endif
    }
}
