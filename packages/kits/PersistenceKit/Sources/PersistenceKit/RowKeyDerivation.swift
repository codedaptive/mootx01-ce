// RowKeyDerivation.swift
//
// Deterministic, content-derived `RowKey` minting for single-column TEXT
// primary keys (gap 5 — LocusKit TEXT-PK federation HLC ordering).
//
// THE DEFECT THIS CLOSES:
// `InMemoryStorage.resolveOrAllocateKey` and `SQLiteBackend.extractRowKey`
// each resolve a row's internal `RowKey` (a `UUID`, `RowStore.swift:8`) from
// the row's declared primary-key column. When that column is `.uuid`-typed,
// the value itself IS the key — trivially stable and identical across every
// spoke that writes the same logical row. When the column is `.text`-typed
// (LocusKit's `drawers.id` / `kg_facts.id`, `LocusKitSchema.swift:184-187,
// 426-429`), the OLD behavior minted a brand-new random `UUID()` on every
// resolution that didn't already match an existing row — meaning two
// different storage instances (two federation spokes) resolve two
// DIFFERENT, unrelated `RowKey`s for what is logically the SAME row (same
// `.text` PK value). ConvergenceKit's fieldLevelLWW/lastWriterWinsByHLC
// gates key their HLC bookkeeping (`_ck_sync_meta`/`_ck_sync_meta_cols`,
// `_fed_sync_meta*`) by this `RowKey` — so a mismatched `RowKey` across
// spokes means the HLC gate compares against a side-table entry that has no
// relationship to the edit actually being applied, and ordering silently
// degrades to pull-order instead of HLC-order (an older edit arriving later
// can clobber a newer one). Value-level dedup is unaffected (upsert's
// `conflictColumns` match on the actual PK VALUE, not `RowKey`), so this is
// an ORDERING defect only, never a duplication defect.
//
// THE FIX: derive `RowKey` deterministically from the PK's TEXT content
// instead of minting randomly, so every spoke resolves the SAME `RowKey`
// for the SAME PK value. Parses the string as a UUID when possible
// (matches today's reality — LocusKit's ids are always UUID strings in
// current code paths); otherwise derives a stable UUID from SHA-256 of the
// string, so the fix also covers LocusKit's documented (if not yet
// exercised) non-UUID deterministic-id capability (`Drawer.id`/`KGFact.id`
// doc comments, `Drawer.swift:33-36`, `KGFact.swift:54-58`).
//
// SIBLING TO KEEP IN LOCKSTEP: this is a deliberate duplication (not a
// shared-package promotion, to avoid a new PersistenceKit→SubstrateKernel
// package dependency edge) of `Estate.deterministicUUID(from:)`
// (`LocusKit/MerkleRollup.swift:329-350`) and its Rust twin
// `deterministic_uuid` (`LocusKit/rust/src/merkle_rollup.rs:308-324`), which
// in turn is byte-for-byte the same SHA-256 primitive as
// `SubstrateKernel.SHA256` (`SubstrateKernel/Sources/SubstrateKernel/
// SHA256.swift`) / `substrate_kernel::sha256::hash`
// (`SubstrateKernel/rust/src/sha256.rs`). Any change to the derivation
// algorithm (parse rule, hash function, version/variant bit placement) must
// be applied identically to ALL FOUR copies (this file, its Rust twin in
// `persistence_kit`, MerkleRollup.swift, merkle_rollup.rs) or cross-spoke
// rowKey agreement breaks silently. `RowKeyDerivationCrossCheckTests.swift`
// (LocusKit test target, which can import both PersistenceKit and LocusKit)
// asserts this file's output is byte-identical to `Estate.deterministicUUID
// (from:)`'s output across a shared vector set.
//
// SCOPE: single-column TEXT primary keys only. Composite (multi-column) PKs
// and `.uuid`-typed PKs are untouched — callers already resolve those via
// their own existing paths; this function is called ONLY as the `.text`
// fallback branch, mirroring exactly where the old `return UUID()` used to
// sit in each resolver cell.

import Foundation
import OSLog

private let rowKeyDerivationLogger = Logger(subsystem: "com.mootx01.kit", category: "RowKeyDerivation")

/// Deterministic, content-derived `RowKey` minting for single-column TEXT
/// primary keys. See file header for the full gap-5 rationale.
package enum RowKeyDerivation {

    /// Derive a deterministic `RowKey` (`UUID`) from a single-column TEXT
    /// primary-key VALUE.
    ///
    /// Parses `stringId` as a UUID when possible (today's reality for every
    /// LocusKit drawer/kg_fact id); otherwise derives a stable UUID from
    /// SHA-256 of the string (UUIDv5-style version/variant bits set on the
    /// first 16 hash bytes), so a non-UUID deterministic id (LocusKit's
    /// documented, not-yet-exercised capability) ALSO resolves identically
    /// on every spoke.
    ///
    /// - Precondition (fail-loud, not silent): `stringId` must not be empty.
    ///   An empty single-column TEXT PK value is a data-quality violation —
    ///   every caller writing a row MUST supply the PK value being written,
    ///   there is no legitimate "absent PK" case for a declared single-column
    ///   PK. `assertionFailure` crashes DEBUG/test builds immediately; the
    ///   `OSLog` fault ensures RELEASE builds are never silent. The
    ///   random-`UUID()` fallback below executes ONLY for this already-
    ///   degenerate input — it is not the ordinary path and does not
    ///   reintroduce gap 5's defect for any well-formed PK value.
    package static func deterministicRowKey(from stringId: String) -> RowKey {
        guard !stringId.isEmpty else {
            assertionFailure("RowKeyDerivation.deterministicRowKey: PK value must not be empty")
            rowKeyDerivationLogger.fault("deterministicRowKey called with an empty single-column TEXT PK value — this indicates a caller bug, not a legitimate absent-PK case")
            return UUID()
        }
        if let uuid = UUID(uuidString: stringId) {
            return uuid
        }
        let hash = SHA256.hash(Array(stringId.utf8))
        var bytes = Array(hash.prefix(16))
        // Set version nibble (byte 6 high nibble) to 5 (name-based SHA-1 by
        // convention, repurposed here for deterministic derivation).
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        // Set variant bits (byte 8 high 2 bits) to 10.
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - SHA-256 (duplicated from SubstrateKernel — see file header)

    /// FIPS 180-4 SHA-256. Pure, dependency-free, deterministic. Byte-for-
    /// byte duplicate of `SubstrateKernel.SHA256` — PersistenceKit does not
    /// depend on the SubstrateKernel package (see file header for why this
    /// is a deliberate duplication, not a promotion).
    package enum SHA256 {

        /// Hash `bytes`, returning the 32-byte digest.
        package static func hash(_ bytes: [UInt8]) -> [UInt8] {
            let k: [UInt32] = [
                0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
                0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
                0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
                0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
                0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
                0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
                0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
                0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
                0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
                0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
                0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
                0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
                0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
                0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
                0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
                0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
            ]
            var h: [UInt32] = [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            ]
            // Pad: append 0x80, then zero bytes until length ≡ 56 (mod 64),
            // then 8-byte big-endian length in bits.
            var msg = bytes
            let bitLen = UInt64(bytes.count) &* 8
            msg.append(0x80)
            while msg.count % 64 != 56 {
                msg.append(0x00)
            }
            for shift in stride(from: 56, through: 0, by: -8) {
                msg.append(UInt8((bitLen >> shift) & 0xFF))
            }
            // Process each 512-bit block.
            var offset = 0
            while offset < msg.count {
                var w = [UInt32](repeating: 0, count: 64)
                for i in 0..<16 {
                    let j = offset + i * 4
                    w[i] = (UInt32(msg[j]) << 24)
                         | (UInt32(msg[j + 1]) << 16)
                         | (UInt32(msg[j + 2]) << 8)
                         |  UInt32(msg[j + 3])
                }
                for i in 16..<64 {
                    let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                    let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                    w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
                }
                var a = h[0], b = h[1], c = h[2], d = h[3]
                var e = h[4], f = h[5], g = h[6], hh = h[7]
                for i in 0..<64 {
                    let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let t1 = hh &+ S1 &+ ch &+ k[i] &+ w[i]
                    let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                    let mj = (a & b) ^ (a & c) ^ (b & c)
                    let t2 = S0 &+ mj
                    hh = g
                    g = f
                    f = e
                    e = d &+ t1
                    d = c
                    c = b
                    b = a
                    a = t1 &+ t2
                }
                h[0] = h[0] &+ a
                h[1] = h[1] &+ b
                h[2] = h[2] &+ c
                h[3] = h[3] &+ d
                h[4] = h[4] &+ e
                h[5] = h[5] &+ f
                h[6] = h[6] &+ g
                h[7] = h[7] &+ hh
                offset += 64
            }
            var out = [UInt8]()
            out.reserveCapacity(32)
            for word in h {
                for shift in stride(from: 24, through: 0, by: -8) {
                    out.append(UInt8((word >> shift) & 0xFF))
                }
            }
            return out
        }

        @inline(__always)
        private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
            return (x >> n) | (x << (32 - n))
        }
    }
}
