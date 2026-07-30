import Foundation

/// Fail-closed errors shared by SecretSync wire contracts and pure validators.
public enum SecretSyncContractError: Error, Sendable, Equatable {
    case invalidDigestLength(actual: Int)
    case emptyValue(field: String)
    case valueTooLarge(field: String)
    case invalidCredentialVersion
    case keyRoleReuse
    case selfAuthorizedEnrollment
    case invalidCanonicalMagic
    case unsupportedSchemaVersion(UInt16)
    case invalidFieldTag
    case duplicateField(tag: UInt16)
    case nonCanonicalFieldOrder
    case invalidCanonicalDomain
    case domainMismatch
    case tooManyFields
    case fieldTooLarge
    case messageTooLarge
    case truncatedCanonicalBytes
    case trailingCanonicalBytes
}

/// Domain labels prevent a valid byte sequence for one SecretSync record kind
/// from being interpreted as another signed or content-addressed record kind.
public enum SecretSyncCanonicalDomain: String, Sendable, Codable, CaseIterable {
    case trustedDeviceCredential = "secret-sync/trusted-device-credential"
    case deviceEnrollmentProof = "secret-sync/device-enrollment-proof"
    case deviceTrustRecord = "secret-sync/device-trust-record"
    case secretScopeSnapshot = "secret-sync/secret-scope-snapshot"
    case secretPolicyEpoch = "secret-sync/secret-policy-epoch"
    case signedSecretPolicyEpoch = "secret-sync/signed-secret-policy-epoch"
    case sealedPayload = "secret-sync/sealed-payload"
    case recipientKeyEnvelope = "secret-sync/recipient-key-envelope"
    case recoveryEnvelope = "secret-sync/recovery-envelope"
    case purgeRequirement = "secret-sync/purge-requirement"
    case purgeReceipt = "secret-sync/purge-receipt"
    case secretTransitionCommit = "secret-sync/secret-transition-commit"
    case secretControlRecords = "secret-sync/secret-control-records"
    case bootstrapFreshnessCommitment = "secret-sync/bootstrap-freshness-commitment"
}

/// One typed field in the deterministic SecretSync canonical frame.
public struct SecretSyncCanonicalField: Sendable, Equatable {
    public let tag: UInt16
    public let value: Data

    public init(tag: UInt16, value: Data) {
        self.tag = tag
        self.value = value
    }
}

/// A strictly parsed canonical document.
public struct SecretSyncCanonicalDocument: Sendable, Equatable {
    public let schemaVersion: UInt16
    public let domain: SecretSyncCanonicalDomain
    public let fields: [SecretSyncCanonicalField]
}

/// A model that supplies explicitly tagged values for canonical encoding.
public protocol SecretSyncCanonicalEncodable: Sendable {
    var canonicalDomain: SecretSyncCanonicalDomain { get }
    func canonicalFields() throws -> [SecretSyncCanonicalField]
}

public extension SecretSyncCanonicalEncodable {
    /// Produce the schema-versioned, domain-separated bytes used for signing
    /// or content addressing. This function performs no digest or signature.
    func canonicalBytes() throws -> Data {
        try SecretSyncCanonicalEncoding.encode(
            domain: canonicalDomain,
            fields: canonicalFields()
        )
    }
}

/// Future digest implementations receive canonical bytes through this seam.
/// ConvergenceKit deliberately does not select or implement a hash here.
public protocol SecretSyncDigesting: Sendable {
    func digest(canonicalBytes: Data) throws -> SecretRecordDigest
}

/// Deterministic framing for every SecretSync signed or digested input.
///
/// Frame layout, all big-endian:
/// `magic[4] | version:u16 | domainLength:u16 | domain | fieldCount:u16 |
/// repeated(tag:u16 | length:u32 | value)`.
///
/// Tags are encoded in ascending order. An absent tag and a present zero-byte
/// value are distinct, preserving nil-versus-empty semantics.
public enum SecretSyncCanonicalEncoding {
    public static let schemaVersion: UInt16 = 1
    public static let maximumDomainByteCount = 64
    public static let maximumFieldCount = 64
    public static let maximumFieldByteCount = 1_048_576
    public static let maximumMessageByteCount = 4_194_304

    private static let magic = Data([0x53, 0x53, 0x43, 0x50]) // "SSCP"

    public static func encode(
        domain: SecretSyncCanonicalDomain,
        fields: [SecretSyncCanonicalField]
    ) throws -> Data {
        guard fields.count <= maximumFieldCount else {
            throw SecretSyncContractError.tooManyFields
        }

        let domainBytes = Data(domain.rawValue.utf8)
        guard !domainBytes.isEmpty, domainBytes.count <= maximumDomainByteCount else {
            throw SecretSyncContractError.invalidCanonicalDomain
        }

        let sortedFields = fields.sorted { $0.tag < $1.tag }
        var previousTag: UInt16?
        for field in sortedFields {
            guard field.tag != 0 else {
                throw SecretSyncContractError.invalidFieldTag
            }
            if previousTag == field.tag {
                throw SecretSyncContractError.duplicateField(tag: field.tag)
            }
            guard field.value.count <= maximumFieldByteCount else {
                throw SecretSyncContractError.fieldTooLarge
            }
            previousTag = field.tag
        }

        var output = Data()
        output.append(magic)
        output.appendBigEndian(schemaVersion)
        output.appendBigEndian(UInt16(domainBytes.count))
        output.append(domainBytes)
        output.appendBigEndian(UInt16(sortedFields.count))

        for field in sortedFields {
            output.appendBigEndian(field.tag)
            output.appendBigEndian(UInt32(field.value.count))
            output.append(field.value)
            guard output.count <= maximumMessageByteCount else {
                throw SecretSyncContractError.messageTooLarge
            }
        }
        return output
    }

    public static func decode(
        _ bytes: Data,
        expectedDomain: SecretSyncCanonicalDomain
    ) throws -> SecretSyncCanonicalDocument {
        guard bytes.count <= maximumMessageByteCount else {
            throw SecretSyncContractError.messageTooLarge
        }

        var cursor = CanonicalCursor(bytes)
        guard try cursor.read(count: magic.count) == magic else {
            throw SecretSyncContractError.invalidCanonicalMagic
        }

        let version = try cursor.readUInt16()
        guard version == schemaVersion else {
            throw SecretSyncContractError.unsupportedSchemaVersion(version)
        }

        let domainLength = Int(try cursor.readUInt16())
        guard domainLength > 0, domainLength <= maximumDomainByteCount else {
            throw SecretSyncContractError.invalidCanonicalDomain
        }
        let domainBytes = try cursor.read(count: domainLength)
        guard
            let domainText = String(data: domainBytes, encoding: .utf8),
            let domain = SecretSyncCanonicalDomain(rawValue: domainText)
        else {
            throw SecretSyncContractError.invalidCanonicalDomain
        }
        guard domain == expectedDomain else {
            throw SecretSyncContractError.domainMismatch
        }

        let fieldCount = Int(try cursor.readUInt16())
        guard fieldCount <= maximumFieldCount else {
            throw SecretSyncContractError.tooManyFields
        }

        var fields: [SecretSyncCanonicalField] = []
        fields.reserveCapacity(fieldCount)
        var previousTag: UInt16?
        for _ in 0..<fieldCount {
            let tag = try cursor.readUInt16()
            guard tag != 0 else {
                throw SecretSyncContractError.invalidFieldTag
            }
            if let previousTag {
                guard tag > previousTag else {
                    if tag == previousTag {
                        throw SecretSyncContractError.duplicateField(tag: tag)
                    }
                    throw SecretSyncContractError.nonCanonicalFieldOrder
                }
            }

            let length = Int(try cursor.readUInt32())
            guard length <= maximumFieldByteCount else {
                throw SecretSyncContractError.fieldTooLarge
            }
            fields.append(
                SecretSyncCanonicalField(
                    tag: tag,
                    value: try cursor.read(count: length)
                )
            )
            previousTag = tag
        }

        guard cursor.isAtEnd else {
            throw SecretSyncContractError.trailingCanonicalBytes
        }
        return SecretSyncCanonicalDocument(
            schemaVersion: version,
            domain: domain,
            fields: fields
        )
    }
}

enum SecretSyncCanonicalValue {
    static func uuid(_ value: UUID) -> Data {
        Data(value.uuidString.lowercased().utf8)
    }

    static func uint16(_ value: UInt16) -> Data {
        var data = Data()
        data.appendBigEndian(value)
        return data
    }

    static func uint64(_ value: UInt64) -> Data {
        var data = Data()
        data.appendBigEndian(value)
        return data
    }

    static func string(_ value: String) -> Data {
        Data(value.utf8)
    }

    static func sequence(_ values: [Data]) throws -> Data {
        guard values.count <= SecretSyncCanonicalEncoding.maximumFieldCount else {
            throw SecretSyncContractError.tooManyFields
        }
        var output = Data()
        output.appendBigEndian(UInt16(values.count))
        for value in values {
            guard value.count <= SecretSyncCanonicalEncoding.maximumFieldByteCount else {
                throw SecretSyncContractError.fieldTooLarge
            }
            output.appendBigEndian(UInt32(value.count))
            output.append(value)
        }
        guard output.count <= SecretSyncCanonicalEncoding.maximumFieldByteCount else {
            throw SecretSyncContractError.fieldTooLarge
        }
        return output
    }
}

enum SecretSyncContractBounds {
    static let maximumAlgorithmIdentifierBytes = 128
    static let maximumOpaqueValueBytes = 65_536

    static func requireOpaqueBytes(_ value: Data, field: String) throws {
        guard !value.isEmpty else {
            throw SecretSyncContractError.emptyValue(field: field)
        }
        guard value.count <= maximumOpaqueValueBytes else {
            throw SecretSyncContractError.valueTooLarge(field: field)
        }
    }

    static func requireAlgorithmIdentifier(_ value: String) throws {
        let bytes = Data(value.utf8)
        guard !bytes.isEmpty else {
            throw SecretSyncContractError.emptyValue(field: "algorithmIdentifier")
        }
        guard bytes.count <= maximumAlgorithmIdentifierBytes else {
            throw SecretSyncContractError.valueTooLarge(field: "algorithmIdentifier")
        }
    }
}

private struct CanonicalCursor {
    private let bytes: Data
    private var offset = 0

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    var isAtEnd: Bool {
        offset == bytes.count
    }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - offset else {
            throw SecretSyncContractError.truncatedCanonicalBytes
        }
        let end = offset + count
        defer { offset = end }
        return bytes.subdata(in: offset..<end)
    }

    mutating func readUInt16() throws -> UInt16 {
        let value = try read(count: MemoryLayout<UInt16>.size)
        return value.reduce(UInt16.zero) { ($0 << 8) | UInt16($1) }
    }

    mutating func readUInt32() throws -> UInt32 {
        let value = try read(count: MemoryLayout<UInt32>.size)
        return value.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value >> 56))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
