/// The local provider's availability for the one exact SecretSync suite.
///
/// Availability never selects an alternative suite. Callers must reject
/// `.unavailable` instead of negotiating or falling back.
public enum SecretSyncAlgorithmAvailability: Sendable, Equatable {
    case available
    case unavailable
}

/// Untrusted wire identifiers presented for closed-suite resolution.
///
/// Text identifiers remain UTF-8 bytes so matching cannot trim, case-fold,
/// normalize, coerce, or otherwise transform attacker-controlled input.
public struct SecretSyncAlgorithmSuiteIdentifiers: Sendable, Equatable {
    public let suiteID: UInt16
    public let suiteNameUTF8: [UInt8]
    public let version: UInt16
    public let digestUTF8: [UInt8]
    public let signatureUTF8: [UInt8]
    public let publicKeyEncodingUTF8: [UInt8]
    public let keyEnvelopeUTF8: [UInt8]
    public let payloadUTF8: [UInt8]

    /// Creates an untrusted complete tuple for exact registry resolution.
    public init(
        suiteID: UInt16,
        suiteNameUTF8: [UInt8],
        version: UInt16,
        digestUTF8: [UInt8],
        signatureUTF8: [UInt8],
        publicKeyEncodingUTF8: [UInt8],
        keyEnvelopeUTF8: [UInt8],
        payloadUTF8: [UInt8]
    ) {
        self.suiteID = suiteID
        self.suiteNameUTF8 = suiteNameUTF8
        self.version = version
        self.digestUTF8 = digestUTF8
        self.signatureUTF8 = signatureUTF8
        self.publicKeyEncodingUTF8 = publicKeyEncodingUTF8
        self.keyEnvelopeUTF8 = keyEnvelopeUTF8
        self.payloadUTF8 = payloadUTF8
    }
}

/// The single immutable algorithm suite accepted by this registry.
///
/// The initializer is module-internal so callers cannot manufacture a
/// registry-approved suite from arbitrary identifiers.
public struct SecretSyncAlgorithmSuite: Sendable, Equatable {
    public let suiteID: UInt16
    public let suiteName: String
    public let version: UInt16
    public let digestAlgorithm: String
    public let signatureAlgorithm: String
    public let publicKeyEncoding: String
    public let keyEnvelopeAlgorithm: String
    public let payloadAlgorithm: String

    init(
        suiteID: UInt16,
        suiteName: String,
        version: UInt16,
        digestAlgorithm: String,
        signatureAlgorithm: String,
        publicKeyEncoding: String,
        keyEnvelopeAlgorithm: String,
        payloadAlgorithm: String
    ) {
        self.suiteID = suiteID
        self.suiteName = suiteName
        self.version = version
        self.digestAlgorithm = digestAlgorithm
        self.signatureAlgorithm = signatureAlgorithm
        self.publicKeyEncoding = publicKeyEncoding
        self.keyEnvelopeAlgorithm = keyEnvelopeAlgorithm
        self.payloadAlgorithm = payloadAlgorithm
    }
}

/// Closed registry for the ratified SecretSync v1 algorithm suite.
///
/// The registry performs identification only. It does not hash, sign,
/// encrypt, decrypt, wrap keys, access custody, or choose a provider.
public enum SecretSyncAlgorithmRegistry {
    public static let suiteID: UInt16 = 0x0001
    public static let suiteName =
        "mootx01.secret-sync.hpke-p256-aesgcm-sha256.v1"
    public static let version: UInt16 = 1
    public static let digestAlgorithm = "sha256"
    public static let signatureAlgorithm = "ecdsa-p256-sha256-raw64"
    public static let publicKeyEncoding = "p256-x963-uncompressed"
    public static let keyEnvelopeAlgorithm =
        "hpke-p256-hkdf-sha256-aesgcm256-base"
    public static let payloadAlgorithm = "aes-gcm-256-nonce12-tag16"

    private static let suite = SecretSyncAlgorithmSuite(
        suiteID: suiteID,
        suiteName: suiteName,
        version: version,
        digestAlgorithm: digestAlgorithm,
        signatureAlgorithm: signatureAlgorithm,
        publicKeyEncoding: publicKeyEncoding,
        keyEnvelopeAlgorithm: keyEnvelopeAlgorithm,
        payloadAlgorithm: payloadAlgorithm
    )

    private static let suiteNameUTF8 = Array(suiteName.utf8)
    private static let digestUTF8 = Array(digestAlgorithm.utf8)
    private static let signatureUTF8 = Array(signatureAlgorithm.utf8)
    private static let publicKeyEncodingUTF8 =
        Array(publicKeyEncoding.utf8)
    private static let keyEnvelopeUTF8 =
        Array(keyEnvelopeAlgorithm.utf8)
    private static let payloadUTF8 = Array(payloadAlgorithm.utf8)

    /// Resolves the complete exact tuple when the local suite is available.
    ///
    /// Every numeric and byte identifier must match in one atomic check.
    /// Unknown, malformed, mixed, or unavailable input fails closed.
    public static func resolve(
        _ identifiers: SecretSyncAlgorithmSuiteIdentifiers,
        availability: SecretSyncAlgorithmAvailability
    ) throws -> SecretSyncAlgorithmSuite {
        guard
            identifiers.suiteID == suiteID,
            identifiers.suiteNameUTF8 == suiteNameUTF8,
            identifiers.version == version,
            identifiers.digestUTF8 == digestUTF8,
            identifiers.signatureUTF8 == signatureUTF8,
            identifiers.publicKeyEncodingUTF8 == publicKeyEncodingUTF8,
            identifiers.keyEnvelopeUTF8 == keyEnvelopeUTF8,
            identifiers.payloadUTF8 == payloadUTF8
        else {
            throw SecretSyncAppleSecurityError.unsupportedSuite
        }
        guard availability == .available else {
            throw SecretSyncAppleSecurityError.suiteUnavailable
        }
        return suite
    }
}
