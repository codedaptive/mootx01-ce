// LegacyPackedHLCMigration.swift
//
// One-time migration helper (gap 6, 2026-07): reconstruct a full-width HLC
// from a legacy 40-bit-truncated `HLC.packed` value, for backfilling the
// shipped v1.0.33 `_ck_sync_meta.sync_hlc` column during the v1.0→v1.1
// schema migration. See HLC.swift:99-104 for the packing scheme this
// inverts, and SyncMetaStore.swift's migration code for the call site.
//
// SCOPE: `_ck_sync_meta` is the ONLY carrier that needs this. Every other
// gap-6 carrier (_ck_sync_meta_cols, _fed_sync_meta, _fed_sync_meta_cols,
// _ck_outbox, _fed_outbox) is develop/1.1.x-only — confirmed absent from
// the shipped v1.0.33 tag (`git grep` against that tag) — so those widen
// via a clean additive schema bump with no pre-existing data to recover.
// `_ck_sync_meta` alone carries real, already-truncated production data
// from shipped devices.
//
// RECOVERABILITY PROOF (verified against the packing code before
// implementing, per SPEC-BEFORE-REALITY):
//
//   packed = (nodeID_low8 << 56) | (logicalCount_low16 << 40)
//            | (physicalTime & 0xFF_FFFF_FFFF)
//
// - nodeID has been minted in range `1...15` since the shipped v1.0.33 tag
//   (`CloudKitSyncEngine.swift:108`, `HLCGenerator(nodeID: Int32.random(in:
//   1...0x0F))`) — this is the actual shipped-data guarantee this backfill
//   depends on for EVERY row it will ever touch, not merely the current-pin
//   precondition (SlotRecordMapping.swift:66-69, which documents today's
//   constraint on freshly-claimed slots but says nothing about what data
//   v1.0.33 devices already wrote). Both sources agree on the same 1...15
//   range, so nodeID fits losslessly in the low 8 bits of the packed form
//   and recovers exactly via the Int8 bit-pattern round trip already used
//   by `HLC(packed:)`.
// - logicalCount is a same-millisecond tie-break counter that increments
//   by 1 per collision and resets to 0 whenever physical time advances
//   (HLCGenerator.send/receive, HLC.swift:139-174) — it never remotely
//   approaches 2^16 in real operation, so the low-16-bit mask never loses
//   information for real data.
// - physicalTime is masked to its low 40 bits; bit 40 and above are
//   discarded. Every physicalTime value genuinely stamped by this system's
//   HLCGenerator (real wall-clock ms since the Unix epoch) falls in
//   "band 1" — the half-open interval [2^40, 2^41) ms, i.e. dates between
//   2004-09-17 and 2039-09-07 — because bit 40 (value 2^40 ≈ 1.0995e12) is
//   SET and bits 41+ are CLEAR for any real timestamp in that 35-year
//   window, which comfortably covers this system's entire operational
//   lifetime (shipped 2026, thirteen years of runway before the window
//   closes). For any such value, `packed`'s low-40-bit portion equals
//   exactly `physicalTime - 2^40`, so `(1 << 40) | low40` recovers the
//   EXACT original physicalTime — a lossless reconstruction in practice,
//   not an approximation, for every row this migration will ever touch.
//
// GUARD: `packed == 0` is the unambiguous "never written" sentinel — a
// genuine HLC can never legitimately encode to 0, because nodeID would
// have to be 0, which the `1...15` precondition forbids for any row a
// live HLCGenerator ever stamped. `packed == 0` therefore means "this
// column's SQL default, never overwritten" (e.g. a row inserted through a
// path that doesn't stamp `sync_hlc`), and decodes straight to `HLC.zero`
// — it is NEVER band-1-reconstructed, which would otherwise wrongly
// inflate an absent/never-written value into a spurious ~2004-era
// timestamp.
import Foundation
import SubstrateTypes

public enum LegacyPackedHLCMigration {

    /// Reconstruct the full-width HLC a legacy `packed` value encoded,
    /// under the band-1 assumption proved above. `packed == 0` returns
    /// `HLC.zero` unconditionally (the never-written sentinel), never
    /// band-1-reconstructed.
    public static func reconstruct(fromLegacyPacked packed: Int64) -> HLC {
        guard packed != 0 else { return .zero }
        let bits = UInt64(bitPattern: packed)
        let node = Int32(Int8(bitPattern: UInt8(truncatingIfNeeded: (bits >> 56) & 0xFF)))
        let logical = Int32(UInt16(truncatingIfNeeded: (bits >> 40) & 0xFFFF))
        let low40 = Int64(bits & 0xFF_FFFF_FFFF)
        let fullPhysicalTime = (Int64(1) << 40) | low40
        return HLC(physicalTime: fullPhysicalTime, logicalCount: logical, nodeID: node)
    }
}
