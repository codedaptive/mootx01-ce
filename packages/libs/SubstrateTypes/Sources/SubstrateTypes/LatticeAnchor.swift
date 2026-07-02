// LatticeAnchor.swift
//
// Phase 6.3 (DECISION_SUBSTRATELIB_PRESHIP_REFACTOR_2026-05-28.md §6.6)
// Moved from SubstrateLib/Sources/SubstrateLib/Verbs.swift.
//
// Lattice anchor reference per cookbook §2.7 / I-16: sixteen
// bytes — an 8-byte UDC code plus an 8-byte Q-ID pointer (or 0
// for null). Pure data.

import Foundation

public struct LatticeAnchor: Hashable, Sendable {
    public let udcCode: UInt64
    public let qidPointer: UInt64       // 0 indicates null

    public init(udcCode: UInt64, qidPointer: UInt64 = 0) {
        self.udcCode = udcCode
        self.qidPointer = qidPointer
    }

    public var isNull: Bool {
        return udcCode == 0 && qidPointer == 0
    }

    /// FNV-1a 64-bit hash of a UTF-8 string. Two callers using the same
    /// string produce the same value; matches the Rust port bit-for-bit.
    static func fnv1a64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for byte in s.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001B3
        }
        return h
    }

    /// Convenience factory used by Block 2a/2b code that
    /// references UDC codes as dotted strings (e.g. "613.71"
    /// for "medicine / body care"). Hashes the string with FNV-1a
    /// 64-bit so two callers using the same string produce the
    /// same anchor.
    public static func udc(_ udcString: String) -> LatticeAnchor {
        return LatticeAnchor(udcCode: fnv1a64(udcString), qidPointer: 0)
    }

    /// Factory that carries BOTH the UDC class AND the varied per-content
    /// Q-ID: hashes each string with FNV-1a 64-bit. Without this the anchor
    /// collapses to the UDC code alone (a uniform "Knowledge" class for most
    /// prose), so downstream matrix O/T coordinates lose all per-content
    /// signal. An empty `qidString` yields qidPointer 0 (null), identical to
    /// `udc(_:)`.
    public static func udcQid(_ udcString: String, qid qidString: String) -> LatticeAnchor {
        return LatticeAnchor(
            udcCode: fnv1a64(udcString),
            qidPointer: qidString.isEmpty ? 0 : fnv1a64(qidString)
        )
    }
}
