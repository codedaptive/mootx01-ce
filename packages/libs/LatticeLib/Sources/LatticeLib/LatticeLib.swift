// LatticeLib.swift
//
// The LatticeLib module surface. Stateless from the caller's perspective;
// internally caches the parsed canon resources on first lookup so
// subsequent calls don't re-parse JSON.
//
// MDCC v1 ships as a frozen reference snapshot bundled with the kit.
// Network is never consulted. The fast-codes channel is the bundled
// codes table; the slow-docs channel is the bundled canon markdown.
// Determinism is guaranteed against the canon version recorded in
// LatticeCanonV1.json.

import Foundation

/// The LatticeLib module surface.
public enum LatticeLib {

    /// The module version. Bumped in lockstep with the bundled canon
    /// when a new canon ships. Patch bumps may carry assembler fixes
    /// that do not change codes; minor bumps carry a new canon.
    public static let version: String = "0.1.0"

    /// The canon version bundled with this build. Pinned in the
    /// canon JSON's `canonVersion` field. The fast-codes channel and
    /// the slow-docs channel both reference this version.
    public static let canonVersion: String = "v1"

    // Cached reference data. Parsed once on first access and reused
    // for the lifetime of the process. The cache does not expire
    // because the data is shipped as a build-time constant; if it
    // could change, it wouldn't be safe to cache like this.
    private static let cachedCanon: LatticeCanon? = LatticeCanon.loadBundledV1()

    /// Resolves a code string to its canon entry. Returns nil if the
    /// code is well-formed but absent from the current canon — this
    /// is the "valid-but-unknown" state described in the launch plan:
    /// the caller should treat the absence as a pending addition, not
    /// as malformed input. Callers that need to distinguish malformed
    /// from unknown should validate with `Code.isWellFormed(_:)` first.
    public static func entry(for code: String) -> LatticeEntry? {
        guard let canon = cachedCanon else { return nil }
        return canon.entry(for: code)
    }

    /// Returns the bundled v1 canon, or nil if the bundle could not be
    /// loaded. The canon is the in-memory representation of both the
    /// fast-codes channel (table of codes) and the slow-docs channel
    /// (documented spine + reserved ranges).
    public static func bundledCanon() -> LatticeCanon? {
        cachedCanon
    }
}
