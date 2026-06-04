//! Per-estate cache configuration mirroring Swift's `EstateCacheConfig`.
//!
//! Follows the ENC-01 precedent: a defaulted field on `EstateConfiguration`
//! so every existing call site compiles unchanged. The `disabled()` constructor
//! is the zero-change default.
//!
//! Sensitivity levels use the ARIA adjective raw integer scale where
//! Secret = 3. Items at that level must never enter the cache; the
//! threshold is therefore clamped to ≤2 at construction to enforce this
//! invariant without requiring caller discipline.

/// Per-estate cache configuration. Carries the byte ceiling for the cache,
/// the highest sensitivity level eligible for caching, and the enabled flag.
///
/// This is an extensible struct (not an enum) so that a future `encrypt_in_memory`
/// field can be added non-breakingly — mirroring the Swift design decision.
#[derive(Debug, Clone)]
pub struct EstateCacheConfig {
    /// Whether the cache layer is active for this estate.
    pub enabled: bool,
    /// Maximum byte size of the cache. Always ≥0 (enforced at construction).
    pub ceiling_bytes: i64,
    /// Highest sensitivity level (raw integer) eligible for caching.
    /// Always ≤2 (enforced at construction) — items at level 3 (Secret) are
    /// never cacheable per the ARIA adjective contract.
    pub sensitivity_threshold: i32,
}

impl EstateCacheConfig {
    /// Construct a cache configuration.
    ///
    /// `ceiling_bytes` is clamped to ≥0; `sensitivity_threshold` is clamped
    /// to ≤2 to enforce the Secret-exclusion invariant at level 3.
    pub fn new(enabled: bool, ceiling_bytes: i64, sensitivity_threshold: i32) -> Self {
        EstateCacheConfig {
            enabled,
            // Clamp negative ceiling to zero — a negative cache makes no sense.
            ceiling_bytes: ceiling_bytes.max(0),
            // Secret level (raw 3) must never be cached; clamp down to 2.
            sensitivity_threshold: sensitivity_threshold.min(2),
        }
    }

    /// The default, zero-change configuration: cache disabled.
    ///
    /// Every `EstateConfiguration` uses this default until a caller
    /// explicitly opts in, preserving identical behaviour across all
    /// existing estates.
    pub fn disabled() -> Self {
        EstateCacheConfig {
            enabled: false,
            ceiling_bytes: 0,
            sensitivity_threshold: 0,
        }
    }
}
