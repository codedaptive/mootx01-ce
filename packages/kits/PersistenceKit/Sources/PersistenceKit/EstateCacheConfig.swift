// EstateCacheConfig.swift
//
// Per-estate cache configuration — the byte ceiling, the sensitivity
// ceiling, and the hard Secret exclusion. Follows the ENC-01 precedent
// (EstateEncryptionConfig): a defaulted field on EstateConfiguration so
// every existing call site compiles unchanged.
//
// Sensitivity levels use the ARIA adjective raw integer scale where
// Secret = 3. Items at that level must never enter the cache; the
// threshold is therefore clamped to ≤2 at construction to enforce this
// invariant without requiring callers to remember the numeric boundary.

import Foundation

/// Per-estate cache configuration. Carries the byte ceiling for the
/// cache, the highest sensitivity level eligible for caching, and the
/// enabled flag. Use the `.disabled` constant as the zero-change
/// default — it compiles into every `EstateConfiguration` without any
/// behavioral impact until explicitly opted in.
///
/// `EstateCacheConfig` is an extensible struct (not an enum) so that a
/// future `encryptInMemory` field or similar can be added non-breakingly.
public struct EstateCacheConfig: Sendable {
    /// Whether the cache layer is active for this estate.
    public let enabled: Bool
    /// Maximum byte size of the cache. Clamped to ≥0 at construction.
    public let ceilingBytes: Int
    /// Highest sensitivity level (raw integer) eligible for caching.
    /// Clamped to ≤2 at construction — items at level 3 (Secret) are
    /// never cacheable per the ARIA adjective contract.
    public let sensitivityThreshold: Int

    /// Designated initialiser.
    ///
    /// - Parameters:
    ///   - enabled: Whether caching is active. Pass `false` to disable.
    ///   - ceilingBytes: Byte ceiling; values below 0 are clamped to 0.
    ///   - sensitivityThreshold: Sensitivity ceiling; values above 2 are
    ///     clamped to 2 to enforce the Secret-exclusion invariant.
    public init(enabled: Bool, ceilingBytes: Int, sensitivityThreshold: Int) {
        self.enabled = enabled
        self.ceilingBytes = max(0, ceilingBytes)
        // Secret level (raw 3) must never be cached; clamp the caller-supplied
        // threshold down to 2 so the invariant holds without caller discipline.
        self.sensitivityThreshold = min(sensitivityThreshold, 2)
    }

    /// The default, zero-change configuration: cache disabled.
    ///
    /// Every `EstateConfiguration` uses this default until a caller
    /// explicitly opts in, preserving identical behaviour across all
    /// existing estates.
    public static let disabled = EstateCacheConfig(
        enabled: false,
        ceilingBytes: 0,
        sensitivityThreshold: 0
    )
}
