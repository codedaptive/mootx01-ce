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
//! Structural differences from Swift, both mechanical rather than semantic:
//!
//! 1. Swift uses an `actor` for interior mutability; Rust wraps the two
//!    expiry fields in a `Mutex` for the same guarantee on `&self` methods
//!    (matching `SurfacedRecallLedger`'s existing pattern in this same crate).
//! 2. Swift injects the calendar/timezone as a defaulted parameter
//!    (`grantRestricted(now:calendar: = .current)`); Rust has no default
//!    arguments, so the injected form is a second function
//!    (`grant_restricted_in`) taking a `ZoneOffsetRule`. Both ports read the
//!    host zone by default and let tests pin a zone explicitly.
//!
//! Time unit: epoch-MILLISECONDS (`i64`) everywhere — matching
//! `dispatch::wall_now()`, the canonical "now" this crate's dispatch/recall
//! stack already uses (NOT `SurfacedRecallLedger`'s epoch-SECONDS, a
//! different, unrelated ledger with its own established convention).

use std::sync::Mutex;

/// A timezone rule: seconds EAST of UTC (the `tm_gmtoff` convention) in effect
/// at a given epoch-SECOND instant.
///
/// Resolving a local midnight needs exactly this much of a calendar system,
/// and it must be asked as a *function of the instant* rather than sampled
/// once: across a DST transition the offset at grant time and the offset at
/// the boundary being computed are different numbers, and it is the
/// boundary's offset that defines the instant.
///
/// `host_utc_offset_seconds_at` is the real rule. Tests pass fixed or
/// synthetic rules — the Rust analogue of the `calendar:` parameter that
/// Swift's `grantRestricted(now:calendar:)` injects.
pub type ZoneOffsetRule = fn(i64) -> i64;

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
    /// strictly after `now_ms`, in the HOST timezone — the boundary is
    /// resolved against the zone's rules on the target local day, so a grant
    /// issued on one side of a DST transition still expires when local
    /// midnight actually occurs.
    ///
    /// Mirrors Swift `grantRestricted(now:)`, which takes `.current`.
    pub fn grant_restricted(&self, now_ms: i64) {
        self.grant_restricted_in(now_ms, host_utc_offset_seconds_at);
    }

    /// `grant_restricted` with the timezone rule supplied explicitly, so a
    /// caller (in practice: a test) can pin the boundary regardless of which
    /// machine it runs on. Mirrors Swift `grantRestricted(now:calendar:)`.
    pub fn grant_restricted_in(&self, now_ms: i64, zone: ZoneOffsetRule) {
        let until = next_local_midnight_ms(now_ms, zone);
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
}

/// The instant at which the next LOCAL day begins, strictly after `now_ms`,
/// in epoch-milliseconds, resolved against `zone`.
///
/// Day arithmetic is only valid on the local wall clock; converting a wall
/// clock back to an instant is the part that needs the zone, and it needs the
/// offset in effect AT THE BOUNDARY, not the one in effect at `now_ms`. Those
/// differ whenever a DST transition falls between the two, which is why the
/// zone is consulted per-instant rather than sampled once.
///
/// `now_ms` at exactly local midnight still advances a full day forward (a
/// grant issued at 00:00:00.000 lasts the following day, not zero seconds) —
/// matching Swift `nextLocalMidnight`, which adds one day on top of
/// `startOfDay(for:)`.
///
/// Edge behaviour is FAIL-CLOSED, and equals what Foundation resolves for the
/// same zones and instants — measured directly against `Calendar.startOfDay`
/// rather than assumed, because a security boundary that differs between the
/// Swift and Rust ports is worse than the DST defect itself:
///
/// - **Ambiguous** midnight — a fall-back that rewinds across 00:00, so local
///   midnight happens twice (`America/Havana`, first Sunday of November,
///   01:00 CDT → 00:00 CST): the EARLIER of the two instants. Expiring an
///   hour early is acceptable; expiring an hour late is the defect.
/// - **Nonexistent** midnight — a spring-forward that skips 00:00
///   (`America/Havana` in March, clocks jump 00:00 → 01:00): the first instant
///   that exists on the new local day, which is the transition itself.
///
/// Both follow from one rule: the EARLIEST instant whose local wall clock
/// reads at or after the target midnight.
fn next_local_midnight_ms(now_ms: i64, zone: ZoneOffsetRule) -> i64 {
    const SECS_PER_DAY: i64 = 86_400;

    // "Naive" seconds = a local clock reading counted as though it were UTC.
    // Flooring to a day boundary is meaningful only in this space.
    let now_secs = now_ms.div_euclid(1_000);
    let offset_at_now = zone(now_secs);
    let local_now = now_secs + offset_at_now;
    let target_naive = local_now.div_euclid(SECS_PER_DAY) * SECS_PER_DAY + SECS_PER_DAY;

    // Resolve that wall clock back to real instants. `t = target - zone(t)` is
    // a fixed point; iterating from the offset at `now` reaches it in one step
    // when no transition intervenes, and surfaces the second candidate when
    // one does. Three iterations is enough to see both sides of a single
    // transition and terminate — a zone cannot change offset twice inside the
    // few hours these candidates span.
    let mut candidates: Vec<i64> = Vec::with_capacity(2);
    let mut offset = offset_at_now;
    for _ in 0..3 {
        let candidate = target_naive - offset;
        if !candidates.contains(&candidate) {
            candidates.push(candidate);
        }
        let resolved = zone(candidate);
        if resolved == offset {
            break;
        }
        offset = resolved;
    }

    // An instant is a genuine occurrence of the target wall clock when the
    // zone maps it back to exactly that reading.
    let reads_as = |t: i64| t + zone(t);
    if let Some(earliest) = candidates
        .iter()
        .copied()
        .filter(|&t| reads_as(t) == target_naive)
        .min()
    {
        // Normal case: exactly one occurrence. Ambiguous case: `now` precedes
        // the rewind, so the iteration lands on the earlier occurrence — the
        // `min` also holds the rule if both are ever surfaced at once.
        return earliest * 1_000;
    }

    // No instant carries that wall clock, so local midnight is skipped in this
    // zone: the answer is the transition instant, the first moment of the new
    // local day. Bracket it between the candidate still reading as the old day
    // and the one already reading past midnight, then bisect. Exactly one
    // transition lies inside that bracket, so "reads at or after midnight" is
    // monotone across it.
    let below = candidates
        .iter()
        .copied()
        .filter(|&t| reads_as(t) < target_naive)
        .max();
    let above = candidates
        .iter()
        .copied()
        .filter(|&t| reads_as(t) > target_naive)
        .min();
    // Unreachable on any real zone: a skipped midnight requires two offsets,
    // which puts one candidate on each side. A single-candidate resolution is
    // always an exact occurrence and returned above. The day-wide bracket is a
    // structural fallback so the bisection below cannot run on garbage.
    let mut lo = below.unwrap_or_else(|| target_naive - offset_at_now - SECS_PER_DAY);
    let mut hi = above.unwrap_or(lo + SECS_PER_DAY);
    while hi - lo > 1 {
        let mid = lo + (hi - lo) / 2;
        if reads_as(mid) >= target_naive {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    hi * 1_000
}

/// The host timezone's offset, seconds EAST of UTC, in effect at `epoch_secs`.
///
/// This is the only point at which the ledger reaches outside itself, and it
/// is deliberately the narrowest question available: "what was the offset at
/// THIS instant". Day arithmetic and the ambiguous/nonexistent rules are pure
/// Rust above it, so the behaviour that matters is testable without touching
/// the host's timezone at all.
///
/// No new crate dependency on either platform — both paths are bare
/// `extern "C"` into the platform C library, the route this crate already used
/// for the same question.
///
/// - **Unix** (macOS, Linux): POSIX `localtime_r`, whose `tm_gmtoff` is
///   seconds east of UTC directly. `#[repr(C)]` inserts the 4 bytes of
///   alignment padding after `tm_isdst` (i32, at offset 32) so `tm_gmtoff`
///   (i64) lands at offset 40, matching the C ABI on both platforms.
/// - **Windows**: `localtime_r` does not exist in the MSVC CRT (LNK2019 —
///   gate run 28734286362). `_localtime64_s` is the replacement; note the
///   REVERSED argument order (result pointer first, then time pointer) and the
///   errno_t return (0 = success). Windows `struct tm` carries no `tm_gmtoff`,
///   so the offset is reconstructed from `_get_timezone` (standard bias,
///   seconds WEST) plus `_get_dstbias` (DST adjustment).
///
/// Failure path on both platforms: return 0 (UTC). A daemon crash inside an
/// unlock request would be worse than a boundary resolved in the wrong zone.
fn host_utc_offset_seconds_at(epoch_secs: i64) -> i64 {
    #[cfg(unix)]
    {
        #[repr(C)]
        struct Tm {
            tm_sec: i32,
            tm_min: i32,
            tm_hour: i32,
            tm_mday: i32,
            tm_mon: i32,
            tm_year: i32,
            tm_wday: i32,
            tm_yday: i32,
            tm_isdst: i32,
            tm_gmtoff: i64,     // seconds east of UTC (POSIX extension)
            tm_zone: *const i8, // timezone abbreviation pointer (unused)
        }

        extern "C" {
            // time_t is i64 on all 64-bit POSIX targets (macOS, Linux aarch64/x86_64).
            fn localtime_r(timep: *const i64, result: *mut Tm) -> *mut Tm;
        }

        let mut tm: Tm = unsafe { std::mem::zeroed() };
        let ret = unsafe { localtime_r(&epoch_secs, &mut tm) };
        if ret.is_null() {
            return 0; // system call failed; UTC is a safe fallback
        }
        return tm.tm_gmtoff;
    }

    #[cfg(windows)]
    {
        #[repr(C)]
        struct WinTm {
            tm_sec: i32,
            tm_min: i32,
            tm_hour: i32,
            tm_mday: i32,
            tm_mon: i32,
            tm_year: i32,
            tm_wday: i32,
            tm_yday: i32,
            tm_isdst: i32, // positive = DST in effect; Windows tm ends here (no tm_gmtoff)
        }

        extern "C" {
            // Note: arg order reversed vs POSIX; __time64_t = i64 on MSVC.
            fn _localtime64_s(result: *mut WinTm, time: *const i64) -> i32;
            // Stores seconds WEST of UTC for the local standard timezone.
            // e.g. UTC-5 → 18000; UTC+5 → -18000. `long` = i32 on Windows.
            fn _get_timezone(seconds: *mut i32) -> i32;
            // Stores the DST offset: typically -3600 ("spring forward" = 1 hr ahead).
            fn _get_dstbias(bias: *mut i32) -> i32;
        }

        unsafe {
            let mut tm: WinTm = std::mem::zeroed();
            if _localtime64_s(&mut tm, &epoch_secs) != 0 {
                return 0; // errno_t nonzero = failure; UTC is a safe fallback
            }

            let mut tz_west: i32 = 0;
            if _get_timezone(&mut tz_west) != 0 {
                return 0;
            }

            // Apply DST when it is in effect AT THIS INSTANT (tm_isdst comes
            // from the converted time, not from "now"). _get_dstbias is
            // negative for "spring forward", so the effective west offset
            // shrinks by that hour.
            if tm.tm_isdst > 0 {
                let mut dst_bias: i32 = 0;
                if _get_dstbias(&mut dst_bias) == 0 {
                    // Convert seconds WEST → seconds EAST (tm_gmtoff convention).
                    return -i64::from(tz_west + dst_bias);
                }
                // _get_dstbias failed; fall through to the standard-time offset.
            }

            -i64::from(tz_west)
        }
    }

    // Unreachable on our target matrix (macOS, Linux, Windows), but the
    // function must compile on any target. UTC is correct for unknown platforms.
    #[cfg(not(any(unix, windows)))]
    {
        let _ = epoch_secs;
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Fixed-UTC zone rule. Used by the tests whose subject is grant lifecycle
    /// rather than timezone resolution, so their boundaries do not depend on
    /// the machine running them — the same role `utcCalendar` plays in the
    /// Swift ledger tests.
    fn utc(_epoch_secs: i64) -> i64 {
        0
    }

    #[test]
    fn restricted_grant_is_live_immediately() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000; // 2025-07-04T15:00:00Z
        ledger.grant_restricted_in(now, utc);
        assert!(ledger.is_restricted_granted(now));
    }

    #[test]
    fn restricted_grant_expires_at_next_midnight_not_before() {
        let ledger = SensitivityGrantLedger::new();
        let granted_at = 1_751_641_200_000; // 2025-07-04T15:00:00Z
        ledger.grant_restricted_in(granted_at, utc);

        let just_before_midnight = 1_751_673_599_000; // 2025-07-04T23:59:59Z
        assert!(ledger.is_restricted_granted(just_before_midnight));

        let at_midnight = 1_751_673_600_000; // 2025-07-05T00:00:00Z
        assert!(!ledger.is_restricted_granted(at_midnight));
    }

    #[test]
    fn restricted_grant_at_midnight_lasts_full_following_day() {
        let ledger = SensitivityGrantLedger::new();
        let granted_at = 1_751_587_200_000; // 2025-07-04T00:00:00Z
        ledger.grant_restricted_in(granted_at, utc);
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
        ledger.grant_restricted_in(now, utc);
        assert!(ledger.is_restricted_granted(now));
        assert!(!ledger.is_secret_granted(now));
    }

    #[test]
    fn lock_drops_both_tiers_immediately() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000;
        ledger.grant_restricted_in(now, utc);
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
        ledger.grant_restricted_in(now, utc);
        ledger.grant_secret(now);
        assert_eq!(ledger.live_tier(now), Some(SensitivityTier::Secret));
        assert_eq!(ledger.ceiling_sensitivity(now), Some(locus_kit::adjectives::AdjectiveSensitivity::Secret));
    }

    #[test]
    fn ceiling_sensitivity_restricted_only() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000;
        ledger.grant_restricted_in(now, utc);
        assert_eq!(ledger.ceiling_sensitivity(now), Some(locus_kit::adjectives::AdjectiveSensitivity::Restricted));
    }

    #[test]
    fn grant_state_snapshot_returns_tier_and_expiry() {
        let ledger = SensitivityGrantLedger::new();
        let now = 1_751_641_200_000; // 2025-07-04T15:00:00Z

        // No grant: None.
        assert!(ledger.grant_state_snapshot(now).is_none());

        // Restricted grant: returns (Restricted, next_midnight).
        ledger.grant_restricted_in(now, utc);
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
