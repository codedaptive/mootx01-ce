import Foundation

/// A wire-stable compatibility outcome shared by provider and client policy.
public enum VersionCompatibilityVerdict: String, Sendable, Equatable, CaseIterable {
    case compatible
    case generationDowngrade
    case keepOwnerNoOverlap
    case candidateCannotReadEstate
    case legacyNotEligibleForAutomatedTakeover
    case updateApp
    case updateCliService
    case updateCliClient
    case repairOwnership
}

/// The schema-3 wire companion for a first-party daemon descriptor.
///
/// This value belongs to the wire layer: both the resident provider and open
/// Community client must be able to encode, decode, and authenticate it without
/// either side importing the other's runtime implementation.
public struct ProviderVersionVector: Sendable, Equatable {
    public static let releaseGeneration: UInt64 = 1

    public let providerReleaseGeneration: UInt64
    public let managementRevisionMinimum: UInt64
    public let managementRevisionMaximum: UInt64
    public let dataPlaneRevisionMinimum: UInt64
    public let dataPlaneRevisionMaximum: UInt64
    public let estateSchemaMinimum: UInt64
    public let estateSchemaMaximum: UInt64
    public let migrationTargetSchema: UInt64?
    public let capabilityRevisions: [String: UInt64]

    public init(
        providerReleaseGeneration: UInt64,
        managementRevisionMinimum: UInt64,
        managementRevisionMaximum: UInt64,
        dataPlaneRevisionMinimum: UInt64,
        dataPlaneRevisionMaximum: UInt64,
        estateSchemaMinimum: UInt64,
        estateSchemaMaximum: UInt64,
        migrationTargetSchema: UInt64?,
        capabilityRevisions: [String: UInt64]
    ) {
        self.providerReleaseGeneration = providerReleaseGeneration
        self.managementRevisionMinimum = managementRevisionMinimum
        self.managementRevisionMaximum = managementRevisionMaximum
        self.dataPlaneRevisionMinimum = dataPlaneRevisionMinimum
        self.dataPlaneRevisionMaximum = dataPlaneRevisionMaximum
        self.estateSchemaMinimum = estateSchemaMinimum
        self.estateSchemaMaximum = estateSchemaMaximum
        self.migrationTargetSchema = migrationTargetSchema
        self.capabilityRevisions = capabilityRevisions
    }

    public static let current = Self(
        providerReleaseGeneration: releaseGeneration,
        managementRevisionMinimum: 1,
        managementRevisionMaximum: 1,
        dataPlaneRevisionMinimum: 2,
        dataPlaneRevisionMaximum: 2,
        estateSchemaMinimum: 1,
        estateSchemaMaximum: 1,
        migrationTargetSchema: nil,
        capabilityRevisions: [:]
    )

    public var hasEncodableFieldWidths: Bool {
        capabilityRevisions.count <= Int(UInt32.max)
    }

    public func appendWire1Fields(_ encoder: inout CanonicalEncoder) {
        encoder.appendUInt64(providerReleaseGeneration)
        encoder.appendUInt64(managementRevisionMinimum)
        encoder.appendUInt64(managementRevisionMaximum)
        encoder.appendUInt64(dataPlaneRevisionMinimum)
        encoder.appendUInt64(dataPlaneRevisionMaximum)
        encoder.appendUInt64(estateSchemaMinimum)
        encoder.appendUInt64(estateSchemaMaximum)
    }

    public static func schema3MAC(
        descriptor: FirstPartyDescriptor,
        vector: Self,
        installationRoot: [UInt8]
    ) -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendBytes(descriptor.macInput())
        vector.appendWire1Fields(&encoder)
        return FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: installationRoot),
            message: encoder.bytes
        )
    }

    public static func verifySchema3MAC(
        descriptor: FirstPartyDescriptor,
        vector: Self,
        installationRoot: [UInt8]
    ) -> Bool {
        guard descriptor.hasEncodableFieldWidths,
              descriptor.descriptorMAC.count == FirstPartyAuthProtocol.macByteCount,
              vector.hasEncodableFieldWidths else { return false }
        return FirstPartyAuthProtocol.constantTimeEquals(
            schema3MAC(
                descriptor: descriptor,
                vector: vector,
                installationRoot: installationRoot
            ),
            descriptor.descriptorMAC
        )
    }
}
