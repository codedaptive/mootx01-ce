// SensitivityGrantLedger.swift — ADR-025 sensitivity unlock: daemon-RAM-only
// grant state for the restricted/secret sensitivity tiers.
//
// Two independent tiers, per ADR-025 §1 (Bob-ruled, 2026-07-04):
//   - restricted ("private"): an on/off grant that resets to OFF at the
//     next LOCAL start-of-day after the moment of grant.
//   - secret: a FIXED 30-minute grant from the moment of approval — not
//     sliding. Renewal requires a fresh approval.
//
// Grants are daemon RAM state only, NEVER persisted. There is no explicit
// "reset on restart" logic here — restart-resets-to-locked falls out of
// construction: a fresh `SensitivityGrantLedger()` starts with both tiers
// ungranted, and exactly one ledger instance is held for the lifetime of
// one `mootx01 serve` process (owned by the single `ToolDispatcher`
// constructed in ServeCommand.swift, mirroring `SurfacedRecallLedger`'s
// established pattern — see that file's header comment).
//
// Determinism: every method that needs "now" takes it as an explicit
// parameter. This type never calls Date()/SystemTime internally, per the
// project's engine-determinism doctrine.
//
// `mootx01 lock` calls `lock()`, dropping both tiers immediately regardless
// of their individual expiries. A secret grant does not imply a restricted
// grant or vice versa — `ceilingFilter` treats them independently and picks
// the WIDEST live grant (secret admits everything; restricted admits up to
// and including restricted; neither admits up to elevated, matching
// BitmapEvaluator's existing default).

import Foundation
import LocusKit

/// One of the two lockable sensitivity tiers ADR-025 governs.
public enum SensitivityTier: String, Sendable, Equatable, CaseIterable {
    case restricted
    case secret
}

/// Daemon-RAM-only grant ledger for ADR-025. Thread-safe via Swift actor
/// isolation, matching `SurfacedRecallLedger`'s structural pattern.
actor SensitivityGrantLedger: Sendable {

    private var restrictedGrantedUntil: Date?
    private var secretGrantedUntil: Date?

    /// Create a new, fully-locked ledger (both tiers ungranted).
    init() {}

    /// Grant the `restricted` tier. Expires at the next LOCAL midnight
    /// strictly after `now` (ADR-025 §1: "resets to OFF at the next local
    /// start-of-day"). `calendar` defaults to `.current` (the host's local
    /// calendar/timezone); tests inject a fixed-timezone calendar so the
    /// expiry boundary is deterministic regardless of the machine running
    /// the test.
    func grantRestricted(now: Date, calendar: Calendar = .current) {
        restrictedGrantedUntil = Self.nextLocalMidnight(after: now, calendar: calendar)
    }

    /// Grant the `secret` tier. Expires exactly 30 minutes after `now`,
    /// fixed — a subsequent read under the grant does NOT extend it.
    func grantSecret(now: Date) {
        secretGrantedUntil = now.addingTimeInterval(30 * 60)
    }

    /// Drop all grants immediately, regardless of individual expiry
    /// (`mootx01 lock`).
    func lock() {
        restrictedGrantedUntil = nil
        secretGrantedUntil = nil
    }

    /// `true` if a live (unexpired) restricted grant exists at `now`.
    /// Fails closed: an absent grant, or one whose expiry is not strictly
    /// after `now`, reports ungranted.
    func isRestrictedGranted(now: Date) -> Bool {
        guard let until = restrictedGrantedUntil else { return false }
        return now < until
    }

    /// `true` if a live (unexpired) secret grant exists at `now`.
    func isSecretGranted(now: Date) -> Bool {
        guard let until = secretGrantedUntil else { return false }
        return now < until
    }

    /// The widest currently-live tier, or `nil` if neither is granted.
    /// Secret is checked first because it is the wider tier (implies
    /// visibility of restricted content too, per ADR-025's ceiling model).
    func liveTier(now: Date) -> SensitivityTier? {
        if isSecretGranted(now: now) { return .secret }
        if isRestrictedGranted(now: now) { return .restricted }
        return nil
    }

    /// The effective sensitivity ceiling `Filter` to inject into a recall
    /// frame's filter chain, or `nil` when neither tier is granted — in
    /// which case the caller injects nothing and `BitmapEvaluator`'s own
    /// default (`sensitivityAtMost(.elevated)`) applies unchanged, exactly
    /// as it did before ADR-025.
    ///
    /// Injecting a `Filter.sensitivityAtMost` case here is what makes
    /// `BitmapEvaluator.insertDefaults` skip its own default insertion —
    /// see that function's doc comment: "Conditional on absence so an
    /// explicit sensitivity constraint from the caller suppresses this
    /// default rather than AND-ing against it." This ledger IS that
    /// caller-side constraint; `BitmapEvaluator` itself needs no ADR-025
    /// awareness at all — the substrate stays unchanged, per "the
    /// substrate does not orchestrate AI; consumers reach it through
    /// ARIA."
    func ceilingFilter(now: Date) -> Filter? {
        switch liveTier(now: now) {
        case .secret:
            return .sensitivityAtMost(.secret)
        case .restricted:
            return .sensitivityAtMost(.restricted)
        case nil:
            return nil
        }
    }

    /// The start of the calendar day strictly after `now`, in `calendar`.
    /// `now` at exactly local midnight still advances a full day forward
    /// (a grant issued at 00:00:00.000 lasts the full following day, not
    /// zero seconds) because `startOfDay(for:)` returns that same instant
    /// and this function always adds one more day on top.
    private static func nextLocalMidnight(after now: Date, calendar: Calendar) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? now.addingTimeInterval(86_400) // pathological calendar fallback
    }
}
