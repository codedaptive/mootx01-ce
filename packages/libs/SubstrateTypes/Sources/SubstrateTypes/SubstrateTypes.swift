// SubstrateTypes — placeholder
//
// This file exists so the target compiles before real type
// migrations land. Per
// docs/decisions/DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md
// Phase 6, the migration moves types from SubstrateLib into this
// package one logical group at a time.
//
// Migration order (proposed):
//   1. Fingerprint256 + HLC (no deps inside SubstrateLib)
//   2. LatticeAnchor, NounType, RowStateValue
//   3. Row, RowLite, AuditEvent (struct shape only)
//   4. MatrixF/C/O/T (storage + indexing, no algorithms)
//   5. BlockMask, RowBitmaps, BitVector216, TimeRange
//   6. Enums: MutationKind, PairingScope, GeneratedByClass, ...
//
// Each migration removes one file from
// packages/libs/SubstrateLib/Sources/SubstrateLib/ AFTER the type
// has been moved here and the legacy SubstrateLib's import has
// been re-pointed.
//
// The legacy SubstrateLib continues to ship until the final
// atomic swap.

import Foundation

public enum SubstrateTypes {
    public static let version = "1.0.0-skeleton"
}
