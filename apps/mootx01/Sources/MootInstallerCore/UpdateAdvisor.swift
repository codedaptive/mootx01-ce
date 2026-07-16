// UpdateAdvisor.swift
//
// Upstream-release advisory for the resident daemon's MCP orientation
// tools (`moot_estate_ping` / `moot_estate_status`). The daemon is
// long-lived — releases ship while it is resident — so a startup-only
// check (the `versionSkewAdvisory` pattern) would never notice a release
// published after launch. This advisor is instead evaluated lazily at
// ping/status time behind a TTL cache, so:
//
//   - the release feed is hit at most once per TTL (24h) per daemon,
//     and only when an orientation tool is actually called;
//   - every other MCP tool response is untouched (the non-annoying
//     contract: one line, in the two session-orientation tools only,
//     mirroring how version_skew is surfaced);
//   - failures are silent AND cached — an offline machine pays one
//     bounded probe per TTL window, not one per ping.
//
// Network boundary: this type owns the daemon's only recurring network
// call. It is disabled entirely by MOOTX01_NO_UPDATE_CHECK — the same
// variable the Claude Code plugin's SessionStart update hook honors
// (distribution/plugin/hooks/moot_update_check.py) — so one documented
// switch turns off every update phone-home surface.

import Foundation

/// Lazily-evaluated, TTL-cached "a newer release exists" advisory.
///
/// An actor so concurrent ping/status calls serialize on the cache and
/// at most one feed probe is in flight; the check function is injected
/// so tests never touch the network (production wiring passes
/// `ReleaseDownloader.latestTag`).
public actor UpdateAdvisor {

    /// Returns the newer-release tag (e.g. "v1.0.34") or nil when the
    /// installed version is current. Throws on network/decode failure.
    /// Semver gating lives in the check function (`ReleaseDownloader.
    /// latestTag` returns nil unless strictly newer), not here.
    private let latestNewerTag: @Sendable () async throws -> String?

    /// Installed semver (no leading v), echoed into the advisory line.
    private let installedVersion: String

    /// Cache lifetime. 24h matches the plugin hook's throttle — one
    /// probe per day is fresh enough for release discovery.
    private let ttl: TimeInterval

    /// Hard cap on a single probe. A ping must stay snappy even when
    /// the feed host is unreachable-but-not-refusing (default URLSession
    /// timeouts run to 60s); the loser of the race is cancelled.
    private let probeTimeout: TimeInterval

    /// Injectable clock so TTL expiry is testable without sleeping.
    private let now: @Sendable () -> Date

    /// True when MOOTX01_NO_UPDATE_CHECK disables the surface. Captured
    /// at construction: the daemon's environment is fixed for its
    /// lifetime, and per-call getenv would just be noise.
    private let disabled: Bool

    /// Cache: when the last probe ran and what it concluded. `cached`
    /// is the rendered advisory line, or nil for "no advisory" (up to
    /// date, or probe failed — both stay silent until the TTL expires).
    private var lastChecked: Date?
    private var cached: String?

    public init(
        installedVersion: String,
        ttl: TimeInterval = 24 * 60 * 60,
        probeTimeout: TimeInterval = 4,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        latestNewerTag: @escaping @Sendable () async throws -> String?
    ) {
        self.installedVersion = installedVersion
        self.ttl = ttl
        self.probeTimeout = probeTimeout
        self.now = now
        self.disabled = !(environment["MOOTX01_NO_UPDATE_CHECK"] ?? "").isEmpty
        self.latestNewerTag = latestNewerTag
    }

    /// The advisory line for ping/status, or nil when there is nothing
    /// to say. Never throws and never blocks longer than `probeTimeout`:
    /// a broken feed must never break an orientation tool.
    public func advisory() async -> String? {
        if disabled { return nil }
        if let lastChecked, now().timeIntervalSince(lastChecked) < ttl {
            return cached
        }
        // Stamp the attempt BEFORE probing so a hung/failed probe is
        // also rate-limited — otherwise an offline machine would retry
        // on every ping.
        lastChecked = now()
        cached = nil
        // `try?` flattens the probe's String? with the failure case: a
        // thrown error and an up-to-date nil tag both land here as nil,
        // and both mean the same thing — nothing to advise this window.
        if let tag = try? await withTimeout(probeTimeout, latestNewerTag) {
            cached = "\(tag) is available (installed \(installedVersion)) — upgrade with `mootx01 upgrade`"
        }
        return cached
    }

    /// Race `operation` against a deadline; the loser is cancelled.
    /// URLSession data tasks honor Swift task cancellation, so a probe
    /// against a black-holed host is torn down at the deadline instead
    /// of holding the ping for URLSession's own 60s default.
    private func withTimeout(
        _ seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> String?
    ) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            // First finisher wins; cancel the other.
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}
