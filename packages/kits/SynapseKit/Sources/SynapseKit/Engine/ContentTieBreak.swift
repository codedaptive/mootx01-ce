// ContentTieBreak.swift
//
// The content-derived tie key shared by every k-NN engine (SPEC 1.9.0,
// universal tie-break): FNV-1a 64 over the stored vector payload bytes.
//
// Why content and not itemID: item UUIDs are assigned per provisioning,
// so a UUID tie-break is stable within one estate but NOT across
// independent builds of the same content. Same content → same
// deterministic embedding → same bytes → same hash, making the order
// identical across estate imports (REPLAY_DRIFT_RCA 2026-08-26). The
// itemID remains the FINAL backstop after vecHash: rows with
// byte-identical vectors still fall to the per-run UUID, and such rows
// are interchangeable for every ordering consumer.
//
// Both ports implement this exact function (Rust: fnv1a64 in
// engine/float_brute_force.rs, shared by the binary engines) — the
// constants are the standard FNV-1a 64 offset basis and prime, so the
// hash values are bit-identical across ports.

import Foundation

/// FNV-1a 64 over a byte sequence — the `vecHash` tie key (SPEC 1.9.0 B-6).
@inlinable
internal func fnv1a64<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
    var hash: UInt64 = 0xcbf29ce484222325   // FNV offset basis
    for byte in bytes {
        hash ^= UInt64(byte)
        hash = hash &* 0x100000001b3        // FNV prime
    }
    return hash
}
