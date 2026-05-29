// TierContributionFingerprint.swift
//
// Tier contribution fingerprint per cookbook § 12.3.
//
// When an estate participates in a federation tier (household,
// fleet-aggregate, industry-aggregate), each estate emits a
// tier-contribution fingerprint: the OR-reduction of all
// shareable rows' fingerprints, computed under the shared
// hyperplane family from the pairing handshake.
//
// The contribution is what gets passed up the tier-ascending
// query protocol. Differential privacy and k-anonymity (§ 12.6)
// are applied AT the aggregator, not by the contributor; the
// contributor sends its exact contribution under the trust
// boundary established by the handshake.
//
// Contribution layout (canonical binary):
//
//   bytes 0..15      contributing estate UUID (16 bytes)
//   bytes 16..19     pairing case (UInt32 BE)
//   bytes 20..23     row count (UInt32 BE)
//   bytes 24..55     OR-reduced Fingerprint256 (32 bytes)
//   bytes 56..63     HLC of the contribution (8 bytes BE)
//
// Total: 64 bytes per contribution. CRC32 over the 64 bytes
// provides integrity; the handshake-established shared key
// signs the contribution against tampering.
//
// Used by:
//   § 12.3    Tier contribution definition (this file)
//   § 12.4    Tier-ascending query protocol (consumer)
//   § 12.6    DP OR-reduction at aggregation point
//   § 9.3 of paper  Tier-ascending query protocol

import Foundation
import SubstrateTypes
import SubstrateKernel

public enum FederationCase: UInt32, Sendable {
    case household = 1
    case fleet     = 2
    case industry  = 3
}

public struct TierContribution: Sendable, Equatable {
    public let estateUUID: UUID
    public let federationCase: FederationCase
    public let rowCount: UInt32
    public let aggregate: Fingerprint256
    public let hlc: HLC

    public init(estateUUID: UUID, federationCase: FederationCase,
                rowCount: UInt32, aggregate: Fingerprint256, hlc: HLC) {
        self.estateUUID = estateUUID
        self.federationCase = federationCase
        self.rowCount = rowCount
        self.aggregate = aggregate
        self.hlc = hlc
    }
}

public enum TierContributionFingerprint {

    /// Build a tier contribution from a set of shareable row
    /// fingerprints. Caller is responsible for ensuring the
    /// fingerprints were computed under the shared hyperplane
    /// family (handshake-established).
    ///
    /// Routes the OR-reduction through `PortableKernel.kernelForCurrentPlatform()`
    /// so that runtime federation work amortizes through the
    /// platform's best available SIMD backend. The cookbook
    /// §12.3 mathematical definition is preserved (commutative,
    /// associative, idempotent OR over the input cohort); the
    /// kernel layer just chooses how to execute it.
    public static func build(estateUUID: UUID,
                             case federationCase: FederationCase,
                             shareableFingerprints: [Fingerprint256],
                             hlc: HLC) -> TierContribution {
        let kernel = PortableKernel.kernelForCurrentPlatform()
        let aggregate = kernel.orReduce256(shareableFingerprints)
        return TierContribution(estateUUID: estateUUID,
                                federationCase: federationCase,
                                rowCount: UInt32(shareableFingerprints.count),
                                aggregate: aggregate,
                                hlc: hlc)
    }

    /// Serialize to the 64-byte canonical wire format.
    public static func encode(_ contrib: TierContribution) -> Data {
        var out = Data(capacity: 64)
        var uuidBytes = withUnsafeBytes(of: contrib.estateUUID.uuid) { Data($0) }
        if uuidBytes.count > 16 { uuidBytes = uuidBytes.prefix(16) }
        out.append(uuidBytes)
        out.append(UInt32BE(contrib.federationCase.rawValue))
        out.append(UInt32BE(contrib.rowCount))
        // Aggregate fingerprint as 4 BE u64s, matching the Rust
        // mirror. The 64-byte wire format is BE-uniform; an
        // earlier draft mistakenly used the LE Fingerprint256
        // wire-bytes here, which diverged from Rust by 32 bytes
        // (the aggregate field). Cross-language conformance gates
        // catch this; we use BE consistently throughout encode.
        out.append(UInt64BE(contrib.aggregate.block0))
        out.append(UInt64BE(contrib.aggregate.block1))
        out.append(UInt64BE(contrib.aggregate.block2))
        out.append(UInt64BE(contrib.aggregate.block3))
        out.append(UInt64BE(contrib.hlc.packed))
        return out
    }

    /// Deserialize from the 64-byte canonical wire format.
    public static func decode(_ data: Data) -> TierContribution? {
        guard data.count == 64 else { return nil }
        let uuidBytes = data.prefix(16)
        let uuid = uuidBytes.withUnsafeBytes { ptr -> UUID in
            let tuple = ptr.bindMemory(to: UInt8.self)
            return UUID(uuid: (tuple[0], tuple[1], tuple[2], tuple[3],
                               tuple[4], tuple[5], tuple[6], tuple[7],
                               tuple[8], tuple[9], tuple[10], tuple[11],
                               tuple[12], tuple[13], tuple[14], tuple[15]))
        }
        let caseRaw = readUInt32BE(data, offset: 16)
        let rowCount = readUInt32BE(data, offset: 20)
        let b0 = readUInt64BE(data, offset: 24)
        let b1 = readUInt64BE(data, offset: 32)
        let b2 = readUInt64BE(data, offset: 40)
        let b3 = readUInt64BE(data, offset: 48)
        let aggregate = Fingerprint256(block0: b0, block1: b1,
                                        block2: b2, block3: b3)
        let hlcPacked = readUInt64BE(data, offset: 56)
        guard let fc = FederationCase(rawValue: caseRaw) else { return nil }
        return TierContribution(estateUUID: uuid,
                                federationCase: fc,
                                rowCount: rowCount,
                                aggregate: aggregate,
                                hlc: HLC(packed: hlcPacked))
    }
}

// MARK: - Endian helpers

@inlinable
func UInt32BE(_ v: UInt32) -> Data {
    var be = v.bigEndian
    return Data(bytes: &be, count: 4)
}

@inlinable
func UInt64BE(_ v: UInt64) -> Data {
    var be = v.bigEndian
    return Data(bytes: &be, count: 8)
}

@inlinable
func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
    return data.subdata(in: offset..<offset+4)
        .withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
}

@inlinable
func readUInt64BE(_ data: Data, offset: Int) -> UInt64 {
    return data.subdata(in: offset..<offset+8)
        .withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
}
