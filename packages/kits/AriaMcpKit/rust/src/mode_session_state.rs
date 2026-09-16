//! Per-session mode sticky state and call counters for the modes coaching system.
//!
//! ## Thread safety
//!
//! `ModeSessionState` uses `std::sync::Mutex` for interior mutability, matching
//! the `Dispatcher`'s `&self` interface requirement. The Mutex wraps the inner
//! mutable state; the outer `ModeSessionState` is `Send + Sync`.
//!
//! ## Preference bitmap
//!
//! Bit 0 of `session_preference_bitmap` (i64) = `sticky_enabled` (default 1 = true).
//! No Bool stored fields — bitmap pattern per fleet-wide house-style rule.
//!
//! ## Extension points
//!
//! - Per-client-id sticky state for HTTP: the current implementation uses one
//!   shared state per `Dispatcher` instance (correct for stdio, advisory for HTTP).
//!   HTTP extension: wrap `Dispatcher` per-request and inject a fresh `ModeSessionState`.
//! - Preference keys from the estate manifest: `modes.sticky_enabled` and
//!   `modes.coaching_calls` are read at session start via
//!   `EstateCoordinator::provisioned_modes_config` and applied by
//!   `Dispatcher::tools_call` through `ModeSessionState::apply_preferences`.
//!
//! Parity: Rust twin of Swift `ModeSessionState.swift`.

use std::collections::HashMap;
use std::sync::Mutex;

use crate::mode_registry::ModeDeclaration;

// MARK: - CoachingSnapshot

/// Immutable snapshot of per-session call counters, passed to `PeriodicCoach`
/// for deterministic block rendering.
#[derive(Debug, Clone, PartialEq)]
pub struct CoachingSnapshot {
    /// Total moot tool calls this session.
    pub total_calls: usize,
    /// Calls per tool name.
    pub tool_counts: HashMap<String, usize>,
    /// Bigram counts: "toolA→toolB" → count.
    pub bigram_counts: HashMap<String, usize>,
    /// Mode attribution counts: mode name → calls attributed to that mode.
    pub mode_attribution_counts: HashMap<String, usize>,
}

// MARK: - Inner mutable state

struct ModeSessionStateInner {
    /// Preference bitmap — bit assignments:
    ///   bit 0 = sticky_enabled        (default 1 = true)
    ///   bit 1 = configured_from_estate (default 0 = false)
    ///   bits 2-63 = reserved
    /// No Bool stored fields — bitmap pattern per fleet-wide house-style rule.
    session_preference_bitmap: i64,
    /// How many moot tool calls between coaching blocks. 0 = off. Default: 25.
    coaching_calls_x: usize,
    /// The last-declared mode, or None.
    sticky_declaration: Option<ModeDeclaration>,
    /// Total calls this session.
    total_call_count: usize,
    /// Calls per tool name.
    tool_call_counts: HashMap<String, usize>,
    /// The previous call's tool name (for bigram tracking).
    last_tool_name: Option<String>,
    /// Bigram frequency map.
    bigram_counts: HashMap<String, usize>,
    /// Mode attribution counts.
    mode_attribution_counts: HashMap<String, usize>,
}

impl ModeSessionStateInner {
    fn new() -> Self {
        ModeSessionStateInner {
            // bit 0 = sticky_enabled = true; bit 1 = configured_from_estate = false
            session_preference_bitmap: 0b01,
            coaching_calls_x: 25,
            sticky_declaration: None,
            total_call_count: 0,
            tool_call_counts: HashMap::new(),
            last_tool_name: None,
            bigram_counts: HashMap::new(),
            mode_attribution_counts: HashMap::new(),
        }
    }

    fn sticky_enabled(&self) -> bool {
        self.session_preference_bitmap & (1 << 0) != 0
    }

    fn configured_from_estate(&self) -> bool {
        self.session_preference_bitmap & (1 << 1) != 0
    }

    fn set_sticky_enabled(&mut self, value: bool) {
        if value {
            self.session_preference_bitmap |= 1 << 0;
        } else {
            self.session_preference_bitmap &= !(1 << 0);
        }
    }

    fn set_configured_from_estate(&mut self, value: bool) {
        if value {
            self.session_preference_bitmap |= 1 << 1;
        } else {
            self.session_preference_bitmap &= !(1 << 1);
        }
    }
}

// MARK: - ModeSessionState

/// Session-scoped mode sticky state and call counters.
///
/// Thread-safe via `Mutex`. Create one instance per `Dispatcher`; for HTTP
/// where per-client isolation is required, inject a fresh instance per request.
pub struct ModeSessionState {
    inner: Mutex<ModeSessionStateInner>,
}

impl ModeSessionState {
    /// Construct with spec defaults (sticky_enabled = true, coaching_calls_x = 25).
    pub fn new() -> Self {
        ModeSessionState {
            inner: Mutex::new(ModeSessionStateInner::new()),
        }
    }

    /// Record a completed tool call and return the new total call count.
    ///
    /// Updates sticky declaration (when sticky_enabled), increments counters,
    /// records bigram from previous call, and updates mode attribution.
    pub fn record_call(&self, tool_name: &str, mode: Option<&ModeDeclaration>) -> usize {
        let mut inner = self.inner.lock().expect("ModeSessionState lock poisoned");

        // Update sticky declaration when sticky is enabled, a mode was declared, AND
        // the mode name is recognized. An unrecognized mode declaration is IGNORED
        // ENTIRELY for sticky purposes (ruling W4): it must not clobber an existing
        // valid sticky declaration. The AI is notified via a hint line by the dispatcher,
        // so fail-open is preserved — only sticky state is unaffected.
        if inner.sticky_enabled() {
            if let Some(m) = mode {
                if m.recognized_mode().is_some() {
                    inner.sticky_declaration = Some(m.clone());
                }
            }
        }

        // Increment total and per-tool counters.
        inner.total_call_count += 1;
        *inner.tool_call_counts.entry(tool_name.to_string()).or_insert(0) += 1;

        // Bigram: record toolA→toolB pair from the previous call.
        if let Some(last) = inner.last_tool_name.clone() {
            let bigram = format!("{}→{}", last, tool_name);
            *inner.bigram_counts.entry(bigram).or_insert(0) += 1;
        }
        inner.last_tool_name = Some(tool_name.to_string());

        // Mode attribution: declared mode name beats inferred bundle.
        let attributed_mode = if let Some(m) = mode {
            if m.recognized_mode().is_some() {
                Some(m.mode_name.clone())
            } else {
                crate::mode_registry::MootMode::inferred_bundle(tool_name)
                    .map(|mm| mm.raw_value().to_string())
            }
        } else {
            crate::mode_registry::MootMode::inferred_bundle(tool_name)
                .map(|mm| mm.raw_value().to_string())
        };
        if let Some(m) = attributed_mode {
            *inner.mode_attribution_counts.entry(m).or_insert(0) += 1;
        }

        inner.total_call_count
    }

    /// Returns true when coaching should fire for this call count.
    ///
    /// Must be called AFTER `record_call` so total_call_count reflects the current call.
    pub fn should_coach(&self) -> bool {
        let inner = self.inner.lock().expect("ModeSessionState lock poisoned");
        if inner.coaching_calls_x == 0 {
            return false;
        }
        inner.total_call_count % inner.coaching_calls_x == 0
    }

    /// Return an immutable snapshot for deterministic block rendering.
    pub fn snapshot(&self) -> CoachingSnapshot {
        let inner = self.inner.lock().expect("ModeSessionState lock poisoned");
        CoachingSnapshot {
            total_calls: inner.total_call_count,
            tool_counts: inner.tool_call_counts.clone(),
            bigram_counts: inner.bigram_counts.clone(),
            mode_attribution_counts: inner.mode_attribution_counts.clone(),
        }
    }

    /// Return the current sticky Recall variant's answer mode raw value, or None
    /// when no sticky Recall=<variant> is set.
    ///
    /// Called by the mode concern's pre-decode transform hook in
    /// `aria_v2_pre_decode_registrations` to inject `answer` into `moot_memory_search`
    /// arguments when the per-call `answer` arg is absent.
    pub fn sticky_recall_answer_mode(&self) -> Option<&'static str> {
        let inner = self.inner.lock().expect("ModeSessionState lock poisoned");
        inner.sticky_declaration
            .as_ref()
            .and_then(|d| d.recognized_recall_variant())
            .map(|v| v.answer_mode_raw_value())
    }

    /// Override the coaching cadence. Used by tests to trigger coaching quickly
    /// without provisioning an estate manifest entry. Sets `configured_from_estate`
    /// to true so that `Dispatcher::tools_call` skips the provisioned-config read
    /// on the first tool call — the seam takes full precedence over the estate key.
    ///
    /// Mirrors Swift `ModeSessionState.setCoachingCallsX(_:)`.
    pub fn set_coaching_calls_x(&self, value: usize) {
        let mut inner = self.inner.lock().expect("ModeSessionState lock poisoned");
        inner.coaching_calls_x = value;
        inner.set_configured_from_estate(true);
    }

    /// Apply preferences read from the estate manifest
    /// (`EstateCoordinator::provisioned_modes_config`). Guards itself:
    /// subsequent calls are no-ops (bit 1 = configured_from_estate).
    ///
    /// Called by `Dispatcher::tools_call` on the first tool call of the session.
    /// Mirrors Swift `ModeSessionState.applyPreferences(stickyEnabled:coachingCalls:)`.
    pub fn apply_preferences(&self, sticky_enabled: bool, coaching_calls: usize) {
        let mut inner = self.inner.lock().expect("ModeSessionState lock poisoned");
        if inner.configured_from_estate() {
            return;
        }
        inner.set_sticky_enabled(sticky_enabled);
        inner.coaching_calls_x = coaching_calls;
        inner.set_configured_from_estate(true);
    }

    /// Returns true if `apply_preferences` has already been called this session.
    ///
    /// Guards the apply-once pattern in `Dispatcher::tools_call`.
    pub fn is_configured_from_estate(&self) -> bool {
        let inner = self.inner.lock().expect("ModeSessionState lock poisoned");
        inner.configured_from_estate()
    }
}

impl Default for ModeSessionState {
    fn default() -> Self {
        Self::new()
    }
}
