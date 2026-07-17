// PollTierPolicy.swift
//
// Pure adaptive tier decision table for the CloudKit inbound poll scheduler.
//
// WHY POLLING IS THE CORRECTNESS PATH:
// The resident process is a launchd service and cannot hold an APNs entitlement
// without a running host app. CKRecordZoneSubscription silent-push wakeups are
// therefore optional latency accelerators — not the inbound delivery guarantee.
// Polling is the delivery guarantee. This tier table keeps polling battery-friendly
// when the zone is quiet while staying responsive when it is not.
//
// DESIGN PRINCIPLE — PURE TABLE:
// This struct contains no OS time calls. It accepts `nowMs` (Int64 milliseconds
// since Unix epoch) as a parameter so the full transition table is deterministically
// testable with injected times. The scheduler (AdaptivePollScheduler) owns the clock
// and feeds nowMs here.
//
// TIER TRANSITIONS:
//   recordNonEmptyPull(nowMs:)
//     → tier = fast, stamp lastActivityMs
//       (remote zone had changes; stay close)
//   recordNudge(nowMs:)
//     → tier = fast, stamp lastActivityMs
//       (external accelerator: local write debounce, APNs hint, IPC wakeup)
//   recordEmptyPull(nowMs:) when within activityWindowMs of lastActivityMs
//     → hold fast  (zone may still be active; we just missed a write this cycle)
//   recordEmptyPull(nowMs:) outside window:
//     fast → mid    (zone going quiet; begin decaying)
//     mid  → idle   (zone clearly quiet; conserve battery/network)
//     idle → idle   (already at floor)
//
// SPEC: CONVERGENCEKIT_SPEC.md § 5 B-11 (convergence loop).
// INTERFACE: CONVERGENCEKIT_INTERFACE.md § 2 AdaptivePollScheduler + nudge().

import Foundation

// MARK: - Tier

/// The three polling cadences for the adaptive scheduler.
public enum PollTier: Equatable, Sendable, CustomStringConvertible {
    /// Fast polling — zone recently showed remote or local activity.
    ///
    /// WHY ~20 s: short enough that a user writing on device A sees the
    /// change on device B within one push-poll round (push + ≤20 s poll ≈
    /// sub-30 s end-to-end). Not so short that we hit CloudKit's per-device
    /// zone-change-fetch quota during extended active sessions.
    case fast

    /// Mid polling — activity window elapsed; zone appears to be calming.
    ///
    /// WHY ~90 s: 4.5× less frequent than fast. Gives the zone a chance to
    /// "settle" between bursts of activity without jumping straight to idle
    /// cadence. Represents the "I just finished editing" window.
    case mid

    /// Idle polling — zone is quiet; conserve battery and CloudKit quota.
    ///
    /// WHY ~5 min: battery-friendly background heartbeat aligned with
    /// iCloud Drive's voluntary background sync budget. Keeps the engine
    /// alive for serendipitous catchup without paging the radio unnecessarily.
    case idle

    public var description: String {
        switch self {
        case .fast: return "fast"
        case .mid:  return "mid"
        case .idle: return "idle"
        }
    }
}

// MARK: - PollTierPolicy

/// Pure adaptive tier decision table for the inbound poll scheduler.
///
/// All mutation methods accept `nowMs` (milliseconds since Unix epoch) as an
/// explicit parameter so transitions are deterministically testable without OS
/// time calls. The scheduler drives this struct — it owns the clock.
///
/// Callers:
///   - `AdaptivePollScheduler` (ConvergenceKitCloudKit) — runs the poll loop.
///   - Unit tests — drive the table directly with synthetic timestamps.
public struct PollTierPolicy: Sendable {

    // MARK: - Tier cadences (named constants)

    /// Fast-tier poll interval: 20 seconds.
    ///
    /// WHY 20 s: one fast-tier interval adds at most 20 s to end-to-end
    /// latency between a push on device A and a pull on device B. This is
    /// below the perceptible "is sync broken?" threshold (~30 s) while
    /// staying well within CloudKit's recommended per-device quota
    /// (~400 zone-change fetches/day = one every ~3.6 min; fast tier fires
    /// only during active use windows, not around the clock).
    public static let fastIntervalMs: Int64 = 20_000   // 20 s

    /// Mid-tier poll interval: 90 seconds.
    ///
    /// WHY 90 s: a 4.5× step from fast reduces background traffic materially
    /// while remaining short enough to catch changes within 90 s — acceptable
    /// for a zone that appears to be quieting down between write bursts.
    public static let midIntervalMs:  Int64 = 90_000   // 90 s

    /// Idle-tier poll interval: 5 minutes.
    ///
    /// WHY 5 min: minimum viable heartbeat for a background process. Matches
    /// iCloud Drive's voluntary background sync budget for non-critical paths.
    /// A user resuming after an idle period will see at most 5 min of staleness
    /// before the first pull; the first non-empty pull immediately promotes
    /// back to fast tier.
    public static let idleIntervalMs: Int64 = 300_000  // 5 min

    // MARK: - Activity window

    /// How long after last observed activity the scheduler holds fast tier
    /// before starting to decay on empty pulls: 2 minutes.
    ///
    /// WHY 2 min: covers two full fast-tier intervals (2 × 20 s) with generous
    /// headroom for network jitter, push lag, and scheduler wake-time variance.
    /// Without this window, the first empty poll after activity would trigger a
    /// fast→mid decay even if the remote device is still actively writing between
    /// polls — causing oscillation where the tier flip-flops on every cycle.
    public static let activityWindowMs: Int64 = 120_000 // 2 min

    // MARK: - Init

    /// Create a fresh policy at cold-start defaults (idle tier, no prior activity).
    public init() {}

    // MARK: - Mutable state

    /// Current polling tier. Starts at idle (cold-start assumption).
    ///
    /// WHY start idle: on first launch we have no evidence of zone activity.
    /// Starting fast would burn quota on cold installs. The first non-empty pull
    /// immediately promotes to fast, and nudge() also promotes immediately, so
    /// latency on first use is bounded by at most one idle-tier interval.
    public private(set) var tier: PollTier = .idle

    /// Wall time (ms) of the most recent activity signal: non-empty pull or nudge.
    ///
    /// Nil means no activity has been observed since the scheduler started.
    /// Used by `recordEmptyPull` to decide whether to hold fast or decay.
    public private(set) var lastActivityMs: Int64? = nil

    // MARK: - Activity recording

    /// Record a non-empty pull cycle: the remote zone had one or more changes.
    ///
    /// Resets tier to fast and stamps the activity timestamp. Both a single
    /// pulled record and a large batch count equally — what matters is that the
    /// zone was live, not how much changed.
    public mutating func recordNonEmptyPull(nowMs: Int64) {
        tier = .fast
        lastActivityMs = nowMs
    }

    /// Record an empty pull cycle: the zone had no changes this fetch.
    ///
    /// If the last activity falls within `activityWindowMs`, the tier holds
    /// fast — the zone may still be active and the write simply arrived after
    /// this fetch's observation window closed.
    ///
    /// Once outside the window, each empty pull decays the tier one step.
    /// One-step-at-a-time decay (fast→mid→idle) gives the zone a chance to
    /// produce another non-empty pull before reaching idle cadence, avoiding
    /// abrupt responsiveness cliffs when a user pauses for a moment between edits.
    public mutating func recordEmptyPull(nowMs: Int64) {
        // Within activity window: zone may still be active; hold fast.
        if let last = lastActivityMs,
           (nowMs - last) < Self.activityWindowMs {
            tier = .fast  // explicitly hold (no decay)
            return
        }
        // Outside window: one step toward idle.
        switch tier {
        case .fast: tier = .mid
        case .mid:  tier = .idle
        case .idle: break  // floor — no further decay
        }
    }

    /// Record a nudge signal: an external accelerator fired (local write, APNs
    /// hint, or IPC wakeup).
    ///
    /// Behaves identically to `recordNonEmptyPull`: resets to fast and stamps
    /// the activity timestamp. The pull that immediately follows the nudge may
    /// itself be empty (the remote device's push hasn't arrived yet), but the
    /// activity timestamp keeps the tier fast for the window period so the
    /// scheduler stays responsive while the write propagates.
    ///
    /// WHY treat nudge as activity: a nudge means "something interesting just
    /// happened." The caller should be optimistic that remote changes will arrive
    /// soon — fast polling for the next 2 minutes is the right posture.
    public mutating func recordNudge(nowMs: Int64) {
        tier = .fast
        lastActivityMs = nowMs
    }

    // MARK: - Interval query

    /// Milliseconds the scheduler should sleep before the next pull attempt
    /// for the current tier.
    public var nextIntervalMs: Int64 {
        switch tier {
        case .fast: return Self.fastIntervalMs
        case .mid:  return Self.midIntervalMs
        case .idle: return Self.idleIntervalMs
        }
    }
}
