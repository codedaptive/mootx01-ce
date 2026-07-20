//! sensitivity_grant_ledger.rs — sensitivity unlock: daemon-RAM-only
//! grant state for the restricted/secret sensitivity tiers.
//!
//! Rust mirror of Swift `SensitivityGrantLedger.swift` (AriaMcpKit). Same
//! two independent tiers, same expiry semantics (restricted: next LOCAL
//! midnight after grant; secret: fixed 30-minute window, not sliding), same
//! RAM-only/no-persistence contract (`Dispatcher::new` constructs exactly
//! one instance per `mootx01 serve` process, so "daemon restart = locked"
//! falls out of construction, not special-cased reset logic).
//!
//! Structural difference from Swift: Swift uses an `actor` for interior
//! mutability; Rust wraps the two expiry fields in a `Mutex` for the same
//! guarantee on `&self` methods (matching `SurfacedRecallLedger`'s existing
//! pattern in this same crate).
//!
//! Time unit: epoch-MILLISECONDS (`i64`) everywhere — matching
//! `dispatch::wall_now()`, the canonical "now" this crate's dispatch/recall
//! stack already uses (NOT `SurfacedRecallLedger`'s epoch-SECONDS, a
//! different, unrelated ledger with its own established convention).

use std::sync::Mutex;

/// One of the two lockable sensitivity tiers out-of-band sensitivity grants governs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SensitivityTier {
    Restricted,
    Secret,
}

/// Daemon-RAM-only grant ledger for out-of-band sensitivity grants. Thread-safe via `Mutex`.
#[derive(Debug, Default)]
pub struct SensitivityGrantLedger {
    restricted_granted_until_ms: Mutex<Option<i64>>,
    secret_granted_until_ms: Mutex<Option<i64>>,
}

impl SensitivityGrantLedger {
    /// Create a new, fully-locked ledger (both tiers ungranted).
    pub fn new() -> Self {
        Self::default()
    }

    /// Grant the `restricted` tier. Expires at the next LOCAL midnight
    /// strictly after `now_ms`. `tz_offset_seconds` is the
    /// caller's local UTC offset in seconds (e.g. `-18000` for US Eastern
    /// Standard Time) — Rust has no `Calendar`/`TimeZone` in std, so the
    /// offset is an explicit parameter (deterministic, testable) rather
    /// than an implicit host-timezone read inside this function.
    pub fn grant_restricted(&self, now_ms: i64, tz_offset_seconds: i64) {
        let until = Self::next_local_midnight_ms(now_ms, tz_offset_seconds);
        if let Ok(mut guard) = self.restricted_granted_until_ms.lock() {
            *guard = Some(until);
        }
    }

    /// Grant the `secret` tier. Expires exactly 30 minutes after `now_ms`,
    /// fixed — a subsequent read under the grant does NOT extend it.
    pub fn grant_secret(&self, now_ms: i64) {
        if let Ok(mut guard) = self.secret_granted_until_ms.lock() {
            *guard = Some(now_ms + 30 * 60 * 1000);
        }
    }

    /// Drop all grants immediately, regardless of individual expiry
    /// (`mootx01 lock`).
    pub fn lock(&self) {
        if let Ok(mut guard) = self.restricted_granted_until_ms.lock() {
            *guard = None;
        }
        if let Ok(mut guard) = self.secret_granted_until_ms.lock() {
            *guard = None;
        }
    }

    /// `true` if a live (unexpired) restricted grant exists at `now_ms`.
    /// Fails closed: a poisoned mutex or absent grant reports ungranted.
    pub fn is_restricted_granted(&self, now_ms: i64) -> bool {
        self.restricted_granted_until_ms
            .lock()
            .ok()
            .and_then(|g| *g)
            .map(|until| now_ms < until)
            .unwrap_or(false)
    }

    /// `true` if a live (unexpired) secret grant exists at `now_ms`.
    pub fn is_secret_granted(&self, now_ms: i64) -> bool {
        self.secret_granted_until_ms
            .lock()
            .ok()
            .and_then(|g| *g)
            .map(|until| now_ms < until)
            .unwrap_or(false)
    }

    /// The widest currently-live tier, or `None` if neither is granted.
    /// Secret is checked first (the wider tier).
    pub fn live_tier(&self, now_ms: i64) -> Option<SensitivityTier> {
        if self.is_secret_granted(now_ms) {
            Some(SensitivityTier::Secret)
        } else if self.is_restricted_granted(now_ms) {
            Some(SensitivityTier::Restricted)
        } else {
            None
        }
    }

    /// The effective sensitivity ceiling to inject into a recall frame's
    /// filter chain, expressed as the `AdjectiveSensitivity` ceiling value,
    /// or `None` when neither tier is granted (the caller injects nothing
    /// and `BitmapEvaluator`'s own default, `sensitivityAtMost(.elevated)`,
    /// applies unchanged).
    pub fn ceiling_sensitivity(&self, now_ms: i64) -> Option<locus_kit::adjectives::AdjectiveSensitivity> {
        match self.live_tier(now_ms) {
            Some(SensitivityTier::Secret) => Some(locus_kit::adjectives::AdjectiveSensitivity::Secret),
            Some(SensitivityTier::Restricted) => Some(locus_kit::adjectives::AdjectiveSensitivity::Restricted),
            None => None,
        }
    }

    /// The live tier and its expiry epoch-millisecond timestamp, or `None`
    /// if neither tier is granted.
    ///
    /// Mirrors Swift `SensitivityGrantLedger.grantStateSnapshot(now:)`.
    /// Used by the `/api/control/grants` HTTP handler so the response can
    /// include `expiresAt` without the handler duplicating tier-priority logic.
    pub fn grant_state_snapshot(&self, now_ms: i64) -> Option<(SensitivityTier, i64)> {
        if self.is_secret_granted(now_ms) {
            let until = self.secret_granted_until_ms
                .lock().ok().and_then(|g| *g)?;
            Some((SensitivityTier::Secret, until))
        } else if self.is_restricted_granted(now_ms) {
            let until = self.restricted_granted_until_ms
                .lock().ok().and_then(|g| *g)?;
            Some((SensitivityTier::Restricted, until))
        } else {
            None
        }
    }

    /// The start of the calendar day (in the given fixed UTC offset)
    /// strictly after `now_ms`, in epoch-milliseconds. `now_ms` at exactly
    /// local midnight still advances a full day forward — mirrors Swift
    /// `nextLocalMidnight`'s same boundary behavior.
    fn next_local_midnight_ms(now_ms: i64, tz_offset_seconds: i64) -> i64 {
        const MS_PER_DAY: i64 = 86_400_000;
        let offset_ms = tz_offset_seconds * 1000;
        let local_now_ms = now_ms + offset_ms;
        // Floor to the start of the local day, then advance one full day.
        let local_midnight_today = local_now_ms.div_euclid(MS_PER_DAY) * MS_PER_DAY;
        let local_next_midnight = local_midnight_today + MS_PER_DAY;
        // Convert back to UTC epoch-ms.
        local_next_midnight - offset_ms
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const UTC: i64 = 0;

    #[test]
    fn restricted_grant_is_live_immediately() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000; // 2025-07-04T15:00:00Z
        ledger.grant_restricted(now, UTC);
        assert!(ledger.is_restricted_granted(now));
    }

    #[test]
    fn restricted_grant_expires_at_next_midnight_not_before() {
        let ledger = SensitivityGrantLedger::new();
        let granted_at = 1_751_641_200_000; // 2025-07-04T15:00:00Z
        ledger.grant_restricted(granted_at, UTC);

        let just_before_midnight = 1_751_673_599_000; // 2025-07-04T23:59:59Z
        assert!(ledger.is_restricted_granted(just_before_midnight));

        let at_midnight = 1_751_673_600_000; // 2025-07-05T00:00:00Z
        assert!(!ledger.is_restricted_granted(at_midnight));
    }

    #[test]
    fn restricted_grant_at_midnight_lasts_full_following_day() {
        let ledger = SensitivityGrantLedger::new();
        let granted_at = 1_751_587_200_000; // 2025-07-04T00:00:00Z
        ledger.grant_restricted(granted_at, UTC);
        assert!(ledger.is_restricted_granted(1_751_673_599_000)); // 2025-07-04T23:59:59Z
        assert!(!ledger.is_restricted_granted(1_751_673_600_000)); // 2025-07-05T00:00:00Z
    }

    #[test]
    fn secret_grant_expires_after_30_minutes_fixed() {
        let ledger = SensitivityGrantLedger::new();
        let granted_at = 1_751_641_200_000;
        ledger.grant_secret(granted_at);
        assert!(ledger.is_secret_granted(granted_at + 29 * 60 * 1000));
        assert!(!ledger.is_secret_granted(granted_at + 30 * 60 * 1000));
    }

    #[test]
    fn secret_grant_is_fixed_not_sliding() {
        let ledger = SensitivityGrantLedger::new();
        let granted_at = 1_751_641_200_000;
        ledger.grant_secret(granted_at);
        let _ = ledger.is_secret_granted(granted_at + 10 * 60 * 1000);
        let _ = ledger.is_secret_granted(granted_at + 20 * 60 * 1000);
        assert!(!ledger.is_secret_granted(granted_at + 31 * 60 * 1000));
    }

    #[test]
    fn tiers_are_independent() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000;
        ledger.grant_restricted(now, UTC);
        assert!(ledger.is_restricted_granted(now));
        assert!(!ledger.is_secret_granted(now));
    }

    #[test]
    fn lock_drops_both_tiers_immediately() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000;
        ledger.grant_restricted(now, UTC);
        ledger.grant_secret(now);
        ledger.lock();
        assert!(!ledger.is_restricted_granted(now));
        assert!(!ledger.is_secret_granted(now));
    }

    #[test]
    fn fresh_ledger_starts_locked() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000;
        assert!(!ledger.is_restricted_granted(now));
        assert!(!ledger.is_secret_granted(now));
        assert!(ledger.live_tier(now).is_none());
        assert!(ledger.ceiling_sensitivity(now).is_none());
    }

    #[test]
    fn new_ledger_instance_simulates_restart_locked() {
        let ledger1 = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000;
        ledger1.grant_secret(now);
        assert!(ledger1.is_secret_granted(now));

        let ledger2 = SensitivityGrantLedger::new();
        assert!(!ledger2.is_secret_granted(now));
    }

    #[test]
    fn ceiling_sensitivity_prefers_secret_when_both_live() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000;
        ledger.grant_restricted(now, UTC);
        ledger.grant_secret(now);
        assert_eq!(ledger.live_tier(now), Some(SensitivityTier::Secret));
        assert_eq!(ledger.ceiling_sensitivity(now), Some(locus_kit::adjectives::AdjectiveSensitivity::Secret));
    }

    #[test]
    fn ceiling_sensitivity_restricted_only() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000;
        ledger.grant_restricted(now, UTC);
        assert_eq!(ledger.ceiling_sensitivity(now), Some(locus_kit::adjectives::AdjectiveSensitivity::Restricted));
    }

    #[test]
    fn grant_state_snapshot_returns_tier_and_expiry() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000; // 2025-07-04T15:00:00Z

        // No grant: None.
        assert!(ledger.grant_state_snapshot(now).is_none());

        // Restricted grant: returns (Restricted, next_midnight).
        ledger.grant_restricted(now, UTC);
        let (tier, expires) = ledger.grant_state_snapshot(now).expect("should be Some");
        assert_eq!(tier, SensitivityTier::Restricted);
        // Expiry should be 2025-07-05T00:00:00Z = 1_751_673_600_000 ms.
        assert_eq!(expires, 1_751_673_600_000);

        // Secret grant supersedes restricted in snapshot.
        ledger.grant_secret(now);
        let (tier2, expires2) = ledger.grant_state_snapshot(now).expect("should be Some");
        assert_eq!(tier2, SensitivityTier::Secret);
        // Secret expires 30 min after now.
        assert_eq!(expires2, now + 30 * 60 * 1000);
    }

    #[test]
    fn grant_state_snapshot_returns_none_after_lock() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000;
        ledger.grant_secret(now);
        assert!(ledger.grant_state_snapshot(now).is_some());
        ledger.lock();
        assert!(ledger.grant_state_snapshot(now).is_none());
    }
}
