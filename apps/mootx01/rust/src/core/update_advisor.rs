//! core/update_advisor.rs — upstream-release advisory for the resident
//! daemon's MCP orientation tools (`moot_estate_ping` / `moot_estate_status`).
//!
//! Rust twin of Swift's `MootInstallerCore.UpdateAdvisor`. The daemon is
//! long-lived — releases ship while it is resident — so a startup-only
//! check (the `version_skew_advisory` pattern) would never notice a
//! release published after launch. This advisor is instead evaluated
//! lazily at ping/status time behind a TTL cache, so:
//!
//!   - the release feed is hit at most once per TTL (24h) per daemon,
//!     and only when an orientation tool is actually called;
//!   - every other MCP tool response is untouched (the non-annoying
//!     contract: one line, in the two session-orientation tools only);
//!   - failures are silent AND cached — an offline machine pays one
//!     bounded probe per TTL window, not one per ping.
//!
//! Network boundary: the injected check closure owns the daemon's only
//! recurring network call (production wiring passes a bounded
//! `release::latest_version_within` probe; tests inject a fake). The
//! whole surface is disabled by MOOTX01_NO_UPDATE_CHECK — the same
//! variable the Claude Code plugin's SessionStart update hook honors
//! (distribution/plugin/hooks/moot_update_check.py) — so one documented
//! switch turns off every update phone-home surface.

use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Cache lifetime. 24h matches the plugin hook's throttle — one probe
/// per day is fresh enough for release discovery.
pub const DEFAULT_TTL: Duration = Duration::from_secs(24 * 60 * 60);

/// Lazily-evaluated, TTL-cached "a newer release exists" advisory.
///
/// The mutex serializes concurrent ping/status calls on the cache so at
/// most one feed probe runs per expiry; the check closure is injected so
/// tests never touch the network.
pub struct UpdateAdvisor {
    /// Returns the newer-release tag (e.g. "v1.0.34") or None when the
    /// installed version is current OR the probe failed — both mean the
    /// same thing here: nothing to advise this window. Semver gating and
    /// the probe deadline live in the closure, not in the advisor.
    check: Box<dyn Fn() -> Option<String> + Send + Sync>,
    /// Installed semver (no leading v), echoed into the advisory line.
    installed: String,
    /// See `DEFAULT_TTL`; injectable for tests.
    ttl: Duration,
    /// True when MOOTX01_NO_UPDATE_CHECK disables the surface. Captured
    /// at construction: the daemon's environment is fixed for its
    /// lifetime, and a per-call getenv would just be noise.
    disabled: bool,
    /// Injectable clock so TTL expiry is testable without sleeping.
    clock: Box<dyn Fn() -> Instant + Send + Sync>,
    /// (when last probed, rendered advisory line or None). The stamp is
    /// written BEFORE the probe result is known so a failed probe is
    /// also rate-limited — otherwise an offline machine would retry on
    /// every ping.
    state: Mutex<Option<(Instant, Option<String>)>>,
}

impl UpdateAdvisor {
    /// Production constructor: reads MOOTX01_NO_UPDATE_CHECK from the
    /// process environment, real clock, default TTL.
    pub fn new(installed: &str, check: Box<dyn Fn() -> Option<String> + Send + Sync>) -> Self {
        let disabled = !std::env::var("MOOTX01_NO_UPDATE_CHECK")
            .unwrap_or_default()
            .is_empty();
        Self::with_parts(installed, DEFAULT_TTL, disabled, Box::new(Instant::now), check)
    }

    /// Fully-injected constructor for tests (fake clock, custom TTL,
    /// explicit kill-switch state — no process-global env mutation,
    /// which races the parallel test runner).
    pub fn with_parts(
        installed: &str,
        ttl: Duration,
        disabled: bool,
        clock: Box<dyn Fn() -> Instant + Send + Sync>,
        check: Box<dyn Fn() -> Option<String> + Send + Sync>,
    ) -> Self {
        UpdateAdvisor {
            check,
            installed: installed.to_owned(),
            ttl,
            disabled,
            clock,
            state: Mutex::new(None),
        }
    }

    /// The advisory line for ping/status, or None when there is nothing
    /// to say. Bounded by the check closure's own deadline (curl
    /// --max-time in production); never panics a ping — a poisoned
    /// mutex (a prior probe panicked) degrades to silence.
    pub fn advisory(&self) -> Option<String> {
        if self.disabled {
            return None;
        }
        let now = (self.clock)();
        let mut state = match self.state.lock() {
            Ok(guard) => guard,
            Err(_) => return None,
        };
        if let Some((checked_at, ref cached)) = *state {
            if now.duration_since(checked_at) < self.ttl {
                return cached.clone();
            }
        }
        let line = (self.check)().map(|tag| {
            format!(
                "{tag} is available (installed {}) — upgrade with `mootx01 upgrade`",
                self.installed
            )
        });
        *state = Some((now, line.clone()));
        line
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    /// Fake clock: a base Instant plus an atomically-advanced offset.
    fn fake_clock() -> (Arc<AtomicU64>, Box<dyn Fn() -> Instant + Send + Sync>) {
        let offset_secs = Arc::new(AtomicU64::new(0));
        let base = Instant::now();
        let reader = Arc::clone(&offset_secs);
        (
            offset_secs,
            Box::new(move || base + Duration::from_secs(reader.load(Ordering::SeqCst))),
        )
    }

    fn counting_check(
        result: Option<&'static str>,
    ) -> (Arc<AtomicU64>, Box<dyn Fn() -> Option<String> + Send + Sync>) {
        let probes = Arc::new(AtomicU64::new(0));
        let counter = Arc::clone(&probes);
        (
            probes,
            Box::new(move || {
                counter.fetch_add(1, Ordering::SeqCst);
                result.map(str::to_owned)
            }),
        )
    }

    #[test]
    fn renders_advisory_line() {
        let (_, check) = counting_check(Some("v1.0.34"));
        let advisor =
            UpdateAdvisor::with_parts("1.0.33", DEFAULT_TTL, false, Box::new(Instant::now), check);
        assert_eq!(
            advisor.advisory().as_deref(),
            Some("v1.0.34 is available (installed 1.0.33) — upgrade with `mootx01 upgrade`")
        );
    }

    #[test]
    fn up_to_date_is_silent() {
        let (_, check) = counting_check(None);
        let advisor =
            UpdateAdvisor::with_parts("1.0.33", DEFAULT_TTL, false, Box::new(Instant::now), check);
        assert_eq!(advisor.advisory(), None);
    }

    #[test]
    fn caches_within_ttl() {
        let (offset, clock) = fake_clock();
        let (probes, check) = counting_check(Some("v1.0.34"));
        let advisor =
            UpdateAdvisor::with_parts("1.0.33", Duration::from_secs(3600), false, clock, check);
        assert!(advisor.advisory().is_some());
        offset.store(3599, Ordering::SeqCst);
        assert!(advisor.advisory().is_some(), "cached advisory must still be returned");
        assert_eq!(probes.load(Ordering::SeqCst), 1, "second call inside the TTL must hit the cache");
    }

    #[test]
    fn reprobes_after_ttl() {
        let (offset, clock) = fake_clock();
        let (probes, check) = counting_check(Some("v1.0.34"));
        let advisor =
            UpdateAdvisor::with_parts("1.0.33", Duration::from_secs(3600), false, clock, check);
        let _ = advisor.advisory();
        offset.store(3601, Ordering::SeqCst);
        let _ = advisor.advisory();
        assert_eq!(probes.load(Ordering::SeqCst), 2, "TTL expiry must trigger a fresh probe");
    }

    #[test]
    fn failure_is_rate_limited() {
        // None models both "up to date" and "probe failed" — the check
        // closure collapses them. Either way the negative result must be
        // cached: one probe per TTL window, not one per ping.
        let (_, clock) = fake_clock();
        let (probes, check) = counting_check(None);
        let advisor =
            UpdateAdvisor::with_parts("1.0.33", Duration::from_secs(3600), false, clock, check);
        assert_eq!(advisor.advisory(), None);
        assert_eq!(advisor.advisory(), None);
        assert_eq!(probes.load(Ordering::SeqCst), 1, "negative result must be cached for the TTL");
    }

    #[test]
    fn kill_switch_disables_probe_entirely() {
        let (probes, check) = counting_check(Some("v1.0.34"));
        let advisor =
            UpdateAdvisor::with_parts("1.0.33", DEFAULT_TTL, true, Box::new(Instant::now), check);
        assert_eq!(advisor.advisory(), None);
        assert_eq!(
            probes.load(Ordering::SeqCst),
            0,
            "kill switch must prevent the probe itself, not just the line"
        );
    }
}
