// PairingHandshake.swift
//
// Pairing handshake per cookbook § 12.2 and paper § 9.2.
//
// Establishes a trust relationship between two estates and
// constructs a shared hyperplane family under which their
// fingerprints become comparable. Five-step protocol:
//
//   1. Out-of-band agreement: 32-byte pairing nonce exchanged
//      via QR code, manual code, or OS-mediated key exchange.
//   2. Hyperplane family generation: each estate independently
//      generates the shared family using SplitMix64 seeded by
//      the nonce mixed with the lower estate UUID. The
//      determinism guarantees both estates produce the same
//      family without further coordination.
//   3. Family commit: each estate writes the shared family
//      to its manifest under H_shared_<case>_<peer_uuid>.
//   4. Initial sync: each estate exchanges its scope-shareable
//      audit log with the other, applying G-Set union.
//   5. Handshake audit event: each estate appends an audit
//      event with actor pairing_handshake, mutation kind pair.
//
// Dissolution reverses step 4 (no further sync), retains the
// family (so asOf queries can recompute under it), and emits a
// pairing_handshake unpair audit event.
//
// Used by:
//   § 12.2 cookbook  Pairing handshake definition (this file)
//   § 9.2 paper      Five-step handshake recapitulated
//   § 9.5 paper      Dissolution semantics
//   § 16.1 cookbook  paired_estates table schema

import Foundation

public struct PairingNonce: Sendable, Equatable {
    public let bytes: [UInt8]   // 32 bytes

    public init(bytes: [UInt8]) {
        precondition(bytes.count == 32, "pairing nonce must be 32 bytes")
        self.bytes = bytes
    }

    /// Derive the SplitMix64 seed for shared-family generation.
    /// Mixes the nonce with the lower estate UUID (by sort order)
    /// to produce a 64-bit seed that both estates compute identically.
    public func seedWith(estateA: UUID, estateB: UUID) -> UInt64 {
        // Compare estate UUIDs by raw bytes, not by string form.
        // Swift's `uuidString` is uppercase hex with dashes; under
        // ASCII lexicographic compare, "0F..." sorts AFTER "10..."
        // (because 'F' = 0x46 > '1' = 0x31), but raw byte compare
        // ranks 0x0F before 0x10. The Rust mirror compares raw
        // bytes; Swift must agree byte-for-byte or the two ports
        // would derive different seeds and incompatible shared
        // hyperplane families. Cross-language conformance gate
        // catches this divergence.
        let aBytes = withUnsafeBytes(of: estateA.uuid) { Array($0) }
        let bBytes = withUnsafeBytes(of: estateB.uuid) { Array($0) }
        let lowerBytes: [UInt8]
        if lexLessOrEqual(aBytes, bBytes) {
            lowerBytes = aBytes
        } else {
            lowerBytes = bBytes
        }
        var h: UInt64 = 0xCBF29CE484222325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x100000001B3
        }
        for b in lowerBytes {
            h ^= UInt64(b)
            h = h &* 0x100000001B3
        }
        return h
    }
}

public struct PairingRecord: Sendable, Equatable {
    public let peerEstate: UUID
    public let federationCase: FederationCase
    public let sharedFamilyKey: String     // "H_shared_<case>_<peer_uuid>"
    public let pairedAt: HLC
    public var dissolvedAt: HLC?
    public var lastSyncAt: HLC

    public var isActive: Bool { return dissolvedAt == nil }

    public init(peerEstate: UUID, federationCase: FederationCase,
                sharedFamilyKey: String, pairedAt: HLC,
                dissolvedAt: HLC? = nil, lastSyncAt: HLC) {
        self.peerEstate = peerEstate
        self.federationCase = federationCase
        self.sharedFamilyKey = sharedFamilyKey
        self.pairedAt = pairedAt
        self.dissolvedAt = dissolvedAt
        self.lastSyncAt = lastSyncAt
    }
}

public enum PairingHandshake {

    /// Generate the shared 4-block hyperplane family set
    /// deterministically from the pairing nonce. Cookbook § 12.2:
    /// both estates derive identical families from the same nonce
    /// + estate-UUID pair, so federation OR-reductions across the
    /// pair are bit-comparable. Parallels the Rust port's
    /// `PairingHandshake::generate_shared_family`.
    public static func generateSharedFamily(nonce: PairingNonce,
                                            estateA: UUID,
                                            estateB: UUID,
                                            inputBitLength: Int = 64,
                                            density: Double = 1.0) -> [HyperplaneFamily] {
        let seedU64 = nonce.seedWith(estateA: estateA, estateB: estateB)
        let seedBytes = Self.expandSeedTo32(seedU64)
        return [
            HyperplaneFamily.generate(seed: seedBytes, blockIndex: 0,
                                       inputBitLength: inputBitLength, density: density),
            HyperplaneFamily.generate(seed: seedBytes, blockIndex: 1,
                                       inputBitLength: inputBitLength, density: density),
            HyperplaneFamily.generate(seed: seedBytes, blockIndex: 2,
                                       inputBitLength: inputBitLength, density: density),
            HyperplaneFamily.generate(seed: seedBytes, blockIndex: 3,
                                       inputBitLength: inputBitLength, density: density),
        ]
    }

    /// Expand a 64-bit seed to 32 bytes via 4 rounds of
    /// SplitMix64-style avalanche. Deterministic; matches the
    /// Rust mirror so both ports produce identical families.
    private static func expandSeedTo32(_ seed: UInt64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        var s = seed
        for i in 0..<4 {
            s = s &+ 0x9E3779B97F4A7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            for j in 0..<8 {
                out[i * 8 + j] = UInt8((z >> (j * 8)) & 0xFF)
            }
        }
        return out
    }

    /// Compute the canonical manifest key for storing a shared
    /// hyperplane family. Format: H_shared_<case>_<peer_uuid_short>.
    public static func sharedFamilyKey(case federationCase: FederationCase,
                                       peerEstate: UUID) -> String {
        let caseName: String
        switch federationCase {
        case .household: caseName = "household"
        case .fleet:     caseName = "fleet"
        case .industry:  caseName = "industry"
        }
        let peerShort = String(peerEstate.uuidString.prefix(8))
        return "H_shared_\(caseName)_\(peerShort)"
    }

    /// Build the audit event recording a new pairing. The substrate
    /// appends this to the G-Set so the pairing is reconstructible.
    public struct PairingAuditPayload: Sendable, Equatable {
        public let mutationKind: String          // "pair" | "unpair"
        public let peerEstate: UUID
        public let federationCase: FederationCase
        public let sharedFamilyHash: UInt64
        public let hlc: HLC

        public init(mutationKind: String, peerEstate: UUID,
                    federationCase: FederationCase,
                    sharedFamilyHash: UInt64, hlc: HLC) {
            self.mutationKind = mutationKind
            self.peerEstate = peerEstate
            self.federationCase = federationCase
            self.sharedFamilyHash = sharedFamilyHash
            self.hlc = hlc
        }
    }

    public static func buildPairEvent(peerEstate: UUID,
                                      federationCase: FederationCase,
                                      families: [HyperplaneFamily],
                                      hlc: HLC) -> PairingAuditPayload {
        return PairingAuditPayload(mutationKind: "pair",
                                   peerEstate: peerEstate,
                                   federationCase: federationCase,
                                   sharedFamilyHash: combinedFamilyHash(families),
                                   hlc: hlc)
    }

    public static func buildUnpairEvent(peerEstate: UUID,
                                        federationCase: FederationCase,
                                        families: [HyperplaneFamily],
                                        hlc: HLC) -> PairingAuditPayload {
        return PairingAuditPayload(mutationKind: "unpair",
                                   peerEstate: peerEstate,
                                   federationCase: federationCase,
                                   sharedFamilyHash: combinedFamilyHash(families),
                                   hlc: hlc)
    }

    /// FNV-1a-mix the per-family `canonicalHash()` outputs in
    /// block_index order. Parallels Rust's combined_family_hash.
    private static func combinedFamilyHash(_ families: [HyperplaneFamily]) -> UInt64 {
        var h: UInt64 = 0xCBF29CE484222325
        for f in families {
            let part = f.canonicalHash()
            for shift in stride(from: 56, through: 0, by: -8) {
                h ^= UInt64((part >> shift) & 0xFF)
                h = h &* 0x100000001B3
            }
        }
        return h
    }
}

/// Lexicographic compare on byte arrays, file-scoped helper used
/// by PairingNonce.seedWith. Returns true when `a <= b` under raw
/// byte order (Rust default semantics for fixed-length byte
/// arrays).
fileprivate func lexLessOrEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    let n = Swift.min(a.count, b.count)
    for i in 0..<n {
        if a[i] != b[i] { return a[i] < b[i] }
    }
    return a.count <= b.count
}
