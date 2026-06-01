// StableKey.swift
//
// The MDCC stable-keying scheme. A concept must keep its code across
// reruns of the assembler so that downstream consumers — caches,
// indexes, citations — do not break when the canon is rebuilt.
//
// The keying scheme is:
//
//   1. The source-identity key. For Wikidata-sourced concepts this
//      is the Q-ID (Q42, Q7259, ...). The source-identity key is the
//      *only* input to code assignment; nothing about the position in
//      the input file, the order entities arrive, or the time of the
//      build affects the assignment. A concept's source-identity key
//      is forever its stable handle.
//
//   2. The deterministic per-class position. Within a class on the
//      collapsed single-parent tree, leaves are assigned codes by
//      sorting on (depth ascending, source-identity key ascending)
//      and then walking the resulting order to fill the unreserved
//      part of the class (NN00-NN79).
//
//   3. The stable-key registry. The v1 canon ships with a frozen
//      mapping from source-identity key to MDCC code. Subsequent
//      assembler runs consult the registry first; any concept whose
//      source-identity key is already in the registry is pinned to
//      its prior code. New concepts are appended to the next-free
//      slot inside their owning class, never inserted between
//      existing codes.
//
// This is what makes MDCC quarterly canons safe to adopt: code 540.027
// in v1 is 540.027 in v1.1, v1.2, v2 — the v2 canon can repurpose
// retired codes only under an explicit deprecation policy declared
// in the canon's release notes. Inside a major canon, codes are
// stable.
//
// A separate stable-key registry file (a JSON map keyed by Q-ID) is
// the persistence surface; this module provides the in-memory model
// and the next-free-slot computation.

import Foundation

/// A single entry in the stable-key registry: a CC0 source identity
/// pinned to an MDCC code. The registry is the durable contract
/// between canon revisions.
public struct StableKeyEntry: Sendable, Hashable, Codable {
    /// The CC0 source identity (Wikidata Q-ID like "Q42", or an
    /// LCC/LCSH identifier for US-government public-domain rows).
    public let sourceIdentity: String
    /// The MDCC code assigned to this identity.
    public let code: String
    /// The canon version that first assigned this code, e.g. "v1".
    /// Used by deprecation tooling to decide whether a code may be
    /// retired and reused in a future major canon.
    public let firstAssignedInCanon: String

    public init(sourceIdentity: String, code: String, firstAssignedInCanon: String) {
        self.sourceIdentity = sourceIdentity
        self.code = code
        self.firstAssignedInCanon = firstAssignedInCanon
    }
}

/// The stable-key registry. The in-memory model carries the canonical
/// mapping from source identity to MDCC code, plus the inverse lookup
/// for assembler use.
public struct StableKeyRegistry: Sendable {
    public let entries: [StableKeyEntry]
    private let bySourceIdentity: [String: StableKeyEntry]
    private let byCode: [String: StableKeyEntry]

    public init(entries: [StableKeyEntry]) {
        self.entries = entries
        var bySrc: [String: StableKeyEntry] = [:]
        var byCode: [String: StableKeyEntry] = [:]
        for entry in entries {
            bySrc[entry.sourceIdentity] = entry
            byCode[entry.code] = entry
        }
        self.bySourceIdentity = bySrc
        self.byCode = byCode
    }

    /// Returns the pinned code for a source identity, or nil if the
    /// identity is new (not yet in the registry).
    public func code(for sourceIdentity: String) -> String? {
        bySourceIdentity[sourceIdentity]?.code
    }

    /// True if a code is already pinned to some identity. Used by the
    /// next-free-slot computation to skip occupied codes.
    public func isOccupied(_ code: String) -> Bool {
        byCode[code] != nil
    }

    /// Returns the next available code within a class for a fresh
    /// identity, or nil only if the class is full to the maximum
    /// extension depth (a condition no realistic corpus reaches).
    ///
    /// The walk is a single deterministic order over the class's code
    /// space, returning the first slot not already occupied by the
    /// registry:
    ///
    ///   1. Flat band — NN00 through NN79, the 80 unreserved
    ///      three-digit codes. NN80-NN99 is held for community and
    ///      annex use and is never returned.
    ///   2. Decimal-extension bands — once the flat band is full the
    ///      walk descends into the leaf space the grammar already
    ///      permits (`Code.maxExtensionDigits`, eight digits in v1).
    ///      Shallowest depth first: every one-digit extension
    ///      (NNbb.0 … NNbb.9) across the flat slots, then every
    ///      two-digit extension (NNbb.00 … NNbb.99), and so on. Within
    ///      a depth the unreserved flat slots are visited in ascending
    ///      order, so the first extension code returned is the lowest
    ///      flat slot's NN00.0 — e.g. 500.0 for Natural sciences.
    ///
    /// At every level a candidate whose integer base is reserved is
    /// skipped, so the held-open NN80-NN99 block is never extended
    /// into. New identities fill from the low end; gaps left by retired
    /// codes inside a canon are not filled until the canon's next major
    /// release declares the retirement. Because a code's position in
    /// this walk depends only on which codes are already occupied — not
    /// on input order or build time — a concept that lands on 500.3 in
    /// one run lands on 500.3 in every run with the same registry.
    public func nextFreeCode(in latticeClass: LatticeClass) -> String? {
        // 1. Flat band NN00-NN79. Offsets 0..<80 never reach the
        //    reserved NN80-NN99 block, so no reservation check is
        //    needed here; the depth bands below do check, because their
        //    base loop is the same 0..<80 range and stays unreserved.
        for offset in 0..<80 {
            let code = String(format: "%03d", latticeClass.base + offset)
            if !isOccupied(code) {
                return code
            }
        }
        // 2. Decimal-extension bands, shallowest depth first.
        var slotsAtDepth = 1   // 10^depth, grown one decimal place per depth
        for depth in 1...Code.maxExtensionDigits {
            slotsAtDepth *= 10
            let width = depth   // zero-padded extension width for this depth
            for offset in 0..<80 {
                let base = latticeClass.base + offset
                let baseCode = String(format: "%03d", base)
                // Skip any flat slot whose integer base is reserved so
                // the extension space under a reserved code is never
                // allocated. (For the spine's NN80-NN99 reservation the
                // 0..<80 range is already clear; the check holds the
                // contract if the reservation table ever widens.)
                if ReservedRanges.isReserved(baseCode) { continue }
                for n in 0..<slotsAtDepth {
                    let code = "\(baseCode).\(String(format: "%0\(width)d", n))"
                    if !isOccupied(code) {
                        return code
                    }
                }
            }
        }
        return nil
    }
}
