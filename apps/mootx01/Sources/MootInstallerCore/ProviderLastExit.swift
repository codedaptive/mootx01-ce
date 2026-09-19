// ProviderLastExit.swift
//
// Why a registered provider is not hosting, in the provider's own words.
//
// launchd bootstraps the daemon provider bundle and then the provider takes
// its own census and activates its estate; either step may decline (an
// estate that needs `mootx01 upgrade`, more than one unverifiable estate
// candidate, a lost activation lock). When it declines it exits, and the
// only trace is the one-line JSON report it printed on the way out —
// `{"mode":"resident","outcome":"startup-failed","reason":...}` from
// CommunityResidentMain — which launchd redirects into the provider's
// stdout log. `mootx01 status` then shows "registered (not started)" and
// `mootx01 install` shows a registration that looked like a start.
//
// This reader surfaces that report. It quotes the provider's outcome and
// reason verbatim (the provider owns its vocabulary; this surface holds no
// second copy of it) and names the log so the user can read the rest.

import Foundation

public struct ProviderLastExit: Sendable, Equatable {
    /// The provider's `outcome` field (`startup-failed`, `clean-shutdown`, …).
    public let outcome: String
    /// The provider's `reason` field, present on failures.
    public let reason: String?

    public init(outcome: String, reason: String?) {
        self.outcome = outcome
        self.reason = reason
    }

    /// The launchd stdout log of the enabled provider bundle. The path is
    /// spelled once, in `LaunchAgent`'s plist writer; this mirrors that
    /// filename so the reader and the writer cannot drift apart silently.
    public static func logURL(homeDirectory: URL) -> URL {
        MootPaths.logsDirURL(homeDirectory: homeDirectory)
            .appendingPathComponent(LaunchAgent.providerStdoutLogName, isDirectory: false)
    }

    /// The most recent resident-mode report in the provider log, or nil
    /// when the log is absent or holds no report. Only the final 64 KiB are
    /// read: the log is append-only across every launchd retry, and the
    /// answer is always at the end.
    public static func read(homeDirectory: URL) -> ProviderLastExit? {
        guard let handle = try? FileHandle(forReadingFrom: logURL(homeDirectory: homeDirectory)) else {
            return nil
        }
        defer { try? handle.close() }
        let tailBytes: UInt64 = 64 * 1024
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > tailBytes ? end - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Pure parser over log text: the last line that is a resident-mode
    /// JSON report. A line cut in half by the tail window fails to parse
    /// and is skipped, as is anything the provider's serve loop printed
    /// that is not a report.
    public static func parse(_ text: String) -> ProviderLastExit? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"),
                  let data = trimmed.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["mode"] as? String == "resident",
                  let outcome = object["outcome"] as? String
            else { continue }
            return ProviderLastExit(outcome: outcome, reason: object["reason"] as? String)
        }
        return nil
    }

    /// The lines `status` and `install` print beneath a registered provider
    /// that is not answering. The report is quoted, not interpreted; the
    /// provider's reason already names the next step when there is one
    /// ("run mootx01 upgrade with the estate stopped").
    public static func explanationLines(homeDirectory: URL) -> [String] {
        let log = logURL(homeDirectory: homeDirectory).path
        guard let last = read(homeDirectory: homeDirectory) else {
            return [
                "  The provider has not recorded an exit yet.",
                "  Provider log: \(log)",
            ]
        }
        var line = "  Last provider exit: \(last.outcome)"
        if let reason = last.reason, !reason.isEmpty {
            line += " — \(reason)"
        }
        return [line, "  Provider log: \(log)"]
    }
}

/// One TCP liveness probe for the resident port, shared by `status` and
/// `install`. Answering proves only that something accepted a connection —
/// never identity or readiness (port liveness never elects; Kong).
public enum ResidentPortProbe {
    public static func isListening(port: Int, timeoutMs: Int = 400) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: Int32(timeoutMs * 1000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }

    /// Wait up to `deadlineMs` for the port to answer, polling every 250 ms.
    /// Returns true as soon as it answers; false when the deadline passes.
    public static func waitUntilListening(port: Int, deadlineMs: Int) -> Bool {
        var waited = 0
        while waited <= deadlineMs {
            if isListening(port: port) { return true }
            usleep(250_000)
            waited += 250
        }
        return false
    }
}
