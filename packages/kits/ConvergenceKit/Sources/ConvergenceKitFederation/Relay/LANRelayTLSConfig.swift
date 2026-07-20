// LANRelayTLSConfig.swift — ConvergenceKitFederation
//
// Production TLS configuration for identity-pinned LANRelay connections (FED-OD-2).
//
// MECHANISM (Kong review, FED-OD charter V2, 2026-07-18):
//
//   CERTIFICATE SHAPE
//     Each estate uses a self-signed P-256 (ECDSA) certificate whose SubjectAltName
//     extension carries the hex-encoded Ed25519 public key fingerprint from
//     _fed_identity (WC1). Why P-256, not Ed25519: Apple's TLS stack (Network.framework)
//     does not accept Ed25519 as a TLS certificate signing key. P-256 is consistent
//     with the ECDSA P-256 approved-mode policy. The estate identity key and the
//     TLS certificate key are DISTINCT layers: TLS secrecy via P-256 ECDH; identity
//     binding via Ed25519 fingerprint in the SAN extension.
//
//   CUSTOM TLS VERIFIER
//     `sec_protocol_options_set_verify_block` replaces the default chain verifier
//     (which would reject a self-signed cert). The custom block:
//       a. Reads the peer's leaf certificate from the SecTrust object.
//       b. Extracts the SubjectAltName OID 2.5.29.17 extension value.
//       c. Parses the hex-encoded Ed25519 fingerprint from an OtherName entry
//          (OID 1.3.6.1.4.1.99999.1, FED-OD-2 private enterprise OID).
//       d. Checks the fingerprint against the injected `knownPeers` set.
//       e. Returns TRUE (accept) when found; FALSE (reject) when unknown.
//     Unknown peer → TLS handshake refused → SyncError.peerUnreachable.
//
//   SAS TIMING (charter V2 Sequence note)
//     The SAN fingerprint is only writable (and recognized by the verifier) after
//     the SAS ceremony completes and the peer is written to `_fed_peers` (FED-OD-3).
//     First-contact protection: SAS. Recurring-connection protection: pinned cert.
//
//   IDENTITY FACTORY NOTE
//     `LANRelayIdentityFactory.makeEphemeralIdentity(ed25519Fingerprint:)` describes
//     the production path but throws `notImplemented` until the platform-specific
//     cert generation is wired for the target environment. Unit tests do NOT use
//     this file — they inject FakeLANRelayTransport instead.
//
// UNIT TESTS: Tests use FakeLANRelayTransport (in-memory, no sockets). This file
//   is production-only. The pure verification functions `verifyPeerCertificate` and
//   `extractEd25519Fingerprint` CAN be unit-tested independently of Network.framework
//   and are exposed as package-internal functions for that purpose.
//
// OID ASSIGNMENTS (FED-OD-2):
//   SubjectAltName extension OID:  2.5.29.17        (X.509 standard, subjectAltName)
//   OtherName type-id OID:         1.3.6.1.4.1.99999.1  (mootx01 FED-OD-2, private enterprise)
//   Certificate signing algorithm: ecdsa-with-SHA256 (OID 1.2.840.10045.4.3.2)
//   Certificate key type:          id-ecPublicKey   (OID 1.2.840.10045.2.1), P-256 curve
//
// Spec references:
//   - docs/analysis/FED_OD_CHARTER.md §V2 (identity-bound TLS mechanism)
//   - ECDSA P-256 in FIPS approved mode
//   - WC1 (estate Ed25519 identity, _fed_identity), WC6 (_fed_peers)

import Foundation
@preconcurrency import Security
import Network
import os

private let logger = Logger(
    subsystem: "com.mootx01.synckit.federation",
    category: "LANRelayTLS"
)

// MARK: - LANRelayTLSConfig

/// Production TLS configuration for LANRelay.
///
/// Accepts a pre-built `SecIdentity` (P-256 self-signed cert pinned to the local
/// estate's Ed25519 fingerprint) and a set of accepted peer Ed25519 public keys.
/// Configures a custom TLS verifier that refuses connections from unrecognized keys.
///
/// Usage (production):
/// ```swift
/// let identity = try LANRelayIdentityFactory.makeEphemeralIdentity(
///     ed25519Fingerprint: localPublicKey
/// )
/// let config = LANRelayTLSConfig(localIdentity: identity, knownPeers: fedPeerKeys)
/// let transport = LANRelayNWTransport(tlsConfig: config, port: 5090)
/// let relay = LANRelay(transport: transport)
/// ```
///
/// Unit tests inject `FakeLANRelayTransport` and do not use this type.
public struct LANRelayTLSConfig: @unchecked Sendable {

    // MARK: Configuration

    /// Pre-built SecIdentity: P-256 private key + self-signed cert with Ed25519
    /// fingerprint in the SubjectAltName extension. Presented to peers during TLS.
    /// @unchecked Sendable: SecIdentity is an immutable CF object; safe to share.
    private let localIdentity: SecIdentity

    /// Ed25519 public keys of accepted peers (from _fed_peers, WC6).
    /// The custom TLS verifier refuses connections from fingerprints not in this set.
    public let knownPeers: Set<Data>

    // MARK: Init

    /// Create TLS configuration from a pre-built identity and known peer set.
    ///
    /// - Parameters:
    ///   - localIdentity: Self-signed P-256 SecIdentity with Ed25519 fingerprint in SAN.
    ///     Obtain via `LANRelayIdentityFactory.makeEphemeralIdentity(ed25519Fingerprint:)`.
    ///   - knownPeers: Set of 32-byte Ed25519 public keys from `_fed_peers` (WC6).
    ///     Connections from fingerprints not in this set are refused at TLS.
    public init(localIdentity: SecIdentity, knownPeers: Set<Data>) {
        self.localIdentity = localIdentity
        self.knownPeers = knownPeers
    }

    // MARK: NWParameters

    /// Build `NWParameters` for use with NWListener and NWConnection.
    ///
    /// Configures:
    ///   - TLS using the self-signed P-256 identity (presented to peers on connect).
    ///   - A custom `sec_protocol_options_set_verify_block` that:
    ///       1. Extracts the peer's leaf certificate from SecTrust.
    ///       2. Parses the Ed25519 fingerprint from the certificate's SAN extension.
    ///       3. Accepts the connection iff the fingerprint is in `knownPeers`.
    ///
    /// The verify block fires on BOTH sides (listener verifies connector; connector
    /// verifies listener). Both directions are identity-pinned.
    public func makeNWParameters() -> NWParameters {
        let peers = knownPeers
        let capturedIdentity = localIdentity

        let tlsOptions = NWProtocolTLS.Options()

        // 1. Present the local P-256 identity to the peer during TLS handshake.
        guard let secIdentityRef = sec_identity_create(capturedIdentity) else {
            logger.error("lan-relay-tls: sec_identity_create returned nil — identity may be incomplete")
            return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        }
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions,
            secIdentityRef
        )

        // 2. Custom verify block — accept only peers in _fed_peers.
        //    The block replaces the default chain verifier (self-signed certs would
        //    otherwise be rejected). It extracts the Ed25519 fingerprint from the
        //    peer's SAN extension and checks it against `knownPeers`.
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions,
            { _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                complete(verifyPeerCertificate(secTrust, against: peers))
            },
            .global(qos: .userInitiated)
        )

        return NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    }
}

// MARK: - LANRelayIdentityFactory

/// Factory for generating the self-signed P-256 `SecIdentity` used by LANRelay.
///
/// The identity is ephemeral (new private key on every process start) and NOT
/// added to the user's persistent keychain. The TLS session's confidentiality
/// derives from the ephemeral P-256 key; the estate identity binding derives from
/// the Ed25519 fingerprint embedded in the certificate's SubjectAltName extension.
///
/// PRODUCTION IMPLEMENTATION NOTE:
///   The full production path requires:
///     1. `SecKeyCreateRandomKey` → P-256 private key
///     2. Build DER certificate (self-signed, SAN with Ed25519 fingerprint)
///        per X.509 RFC 5280 structure described in the file header.
///        SAN OtherName type-id: 1.3.6.1.4.1.99999.1, value: UTF8String(hexFingerprint).
///     3. `SecCertificateCreateWithData` → SecCertificate from DER bytes
///     4. Form SecIdentity via temporary keychain import (macOS) or PKCS12 import (iOS):
///        - macOS: `SecKeychainCreate` temporary keychain + `SecItemAdd` + identity query
///        - iOS/macOS: build minimal PKCS12 container, `SecPKCS12Import` to extract identity
///        Platform-specific wiring belongs in the LANRelayNWTransport setup code.
///   Blocked on: platform-specific identity assembly (FED-OD-2 follow-up wiring task).
public enum LANRelayIdentityFactory {

    /// Generate an ephemeral self-signed P-256 SecIdentity embedding the given
    /// Ed25519 public key fingerprint in the certificate's SubjectAltName extension.
    ///
    /// - Parameter ed25519Fingerprint: 32-byte Ed25519 public key (from _fed_identity, WC1).
    ///   Hex-encoded (64 chars) in the SAN OtherName value.
    /// - Returns: An ephemeral SecIdentity for use with `LANRelayTLSConfig`.
    /// - Throws: `LANRelayTLSError.notImplemented` until the platform-specific
    ///   cert assembly is wired. See the production note above.
    public static func makeEphemeralIdentity(ed25519Fingerprint: Data) throws -> SecIdentity {
        // PRODUCTION TODO (FED-OD-2 wiring task):
        //   1. SecKeyCreateRandomKey(kSecAttrKeyTypeECSecPrimeRandom, 256-bit) → P-256 key
        //   2. Build DER certificate with Ed25519 fingerprint in SAN OtherName (see file header)
        //   3. SecCertificateCreateWithData → SecCertificate
        //   4. Form SecIdentity via platform-appropriate import path (see factory note above)
        //
        // The custom verifier (verifyPeerCertificate + extractEd25519Fingerprint) is
        // implemented and unit-testable. The identity generation is the remaining piece.
        throw LANRelayTLSError.notImplemented
    }
}

// MARK: - Peer certificate verifier (pure functions, testable without Network.framework)

/// Verify that a peer TLS certificate's Ed25519 fingerprint appears in `knownPeers`.
///
/// This is the core of the custom `sec_protocol_options_set_verify_block`. It is a
/// pure function (no I/O, no Network.framework) and can be unit-tested directly.
///
/// Returns `true` (accept) when the fingerprint is in `knownPeers`.
/// Returns `false` (reject) for: cert unavailable, extension missing, fingerprint
/// malformed, or fingerprint not in `knownPeers`.
func verifyPeerCertificate(_ trust: SecTrust, against knownPeers: Set<Data>) -> Bool {
    // Extract leaf certificate from trust chain.
    // SecTrustCopyCertificateChain is the macOS 12+ replacement for the deprecated
    // SecTrustGetCertificateAtIndex. Our floor is macOS 26 so this is always available.
    guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let leafCert = chain.first else {
        logger.warning("lan-relay-tls: peer trust chain is empty — rejecting")
        return false
    }

    // Export certificate as DER to parse its extensions.
    let certDER = SecCertificateCopyData(leafCert) as Data

    // Parse the Ed25519 fingerprint from the SubjectAltName extension.
    guard let fingerprint = extractEd25519Fingerprint(fromCertDER: certDER) else {
        logger.warning("lan-relay-tls: peer certificate has no FED-OD-2 fingerprint extension — rejecting")
        return false
    }

    guard knownPeers.contains(fingerprint) else {
        logger.warning("lan-relay-tls: peer fingerprint \(fingerprint.prefix(4).hex, privacy: .public)… not in _fed_peers — rejecting (unpaired peer)")
        return false
    }

    logger.debug("lan-relay-tls: accepted peer with fingerprint \(fingerprint.prefix(4).hex, privacy: .public)…")
    return true
}

/// Extract the 32-byte Ed25519 public key from the FED-OD-2 SubjectAltName extension
/// of a DER-encoded X.509 certificate.
///
/// Looks for an OtherName GeneralName with type-id OID 1.3.6.1.4.1.99999.1
/// (mootx01 FED-OD-2 private enterprise OID) whose value is a UTF8String
/// containing the 64-character lowercase hex representation of the 32-byte key.
///
/// Returns `nil` if: extension absent, OtherName OID not found, hex invalid.
/// This function is the pure testable core of the TLS verifier.
func extractEd25519Fingerprint(fromCertDER certDER: Data) -> Data? {
    // SubjectAltName OID 2.5.29.17 DER: 55 1d 11
    let sanOIDBytes: [UInt8] = [0x55, 0x1d, 0x11]
    // FED-OD-2 OtherName type-id OID 1.3.6.1.4.1.99999.1 DER:
    //   2b 06 01 04 01 86 8d 1f 01
    let fedOIDBytes: [UInt8] = [0x2b, 0x06, 0x01, 0x04, 0x01, 0x86, 0x8d, 0x1f, 0x01]

    let sanOID = Data(sanOIDBytes)
    let fedOID = Data(fedOIDBytes)

    // 1. Locate the SubjectAltName extension OCTET STRING content.
    guard let sanContent = findExtensionOctetContent(inDER: certDER, oidValue: sanOID) else {
        return nil
    }
    // 2. Locate the OtherName UTF8String value for the FED-OD-2 OID.
    guard let hexString = findOtherNameUTF8(inSANContent: sanContent, oidValue: fedOID) else {
        return nil
    }
    // 3. Decode hex → 32-byte Ed25519 public key.
    guard hexString.count == 64 else { return nil }
    return Data(hexEncoded: hexString)
}

// MARK: - Minimal DER walker helpers

/// Locate a certificate extension's OCTET STRING content by OID value bytes.
/// Returns the raw content inside the OCTET STRING (the extension extnValue), or nil.
private func findExtensionOctetContent(inDER der: Data, oidValue: Data) -> Data? {
    // Build the DER OID TLV: 0x06 <length> <value bytes>
    var oidTLV = Data([0x06])
    oidTLV.append(contentsOf: derMinimalLength(oidValue.count))
    oidTLV.append(oidValue)

    guard let oidRange = der.range(of: oidTLV) else { return nil }
    var cursor = oidRange.upperBound

    // After the OID in an Extension: optional BOOLEAN critical flag, then OCTET STRING.
    // Skip optional BOOLEAN (tag 0x01).
    guard cursor < der.count else { return nil }
    if der[cursor] == 0x01 {
        cursor += 1
        guard cursor < der.count else { return nil }
        let boolLen = Int(der[cursor]); cursor += 1
        cursor += boolLen
    }

    // Expect OCTET STRING (tag 0x04).
    guard cursor < der.count, der[cursor] == 0x04 else { return nil }
    cursor += 1
    let (octetLen, consumed) = parseDERLength(der, at: cursor)
    cursor += consumed
    guard cursor + octetLen <= der.count else { return nil }
    return der[cursor ..< cursor + octetLen]
}

/// Locate an OtherName GeneralName's UTF8String value within SAN SEQUENCE content.
private func findOtherNameUTF8(inSANContent san: Data, oidValue: Data) -> String? {
    // SAN extnValue content is a SEQUENCE of GeneralName choices.
    // OtherName [0] ::= SEQUENCE { type-id OID, value [0] EXPLICIT OPEN TYPE }
    var oidTLV = Data([0x06])
    oidTLV.append(contentsOf: derMinimalLength(oidValue.count))
    oidTLV.append(oidValue)

    guard let oidRange = san.range(of: oidTLV) else { return nil }
    var cursor = oidRange.upperBound

    // After the type-id OID: [0] EXPLICIT tag (0xa0) wrapping the value.
    guard cursor < san.count, san[cursor] == 0xa0 else { return nil }
    cursor += 1
    let (ctxLen, ctxConsumed) = parseDERLength(san, at: cursor)
    cursor += ctxConsumed
    guard cursor + ctxLen <= san.count else { return nil }

    // Inside [0]: expect UTF8String (tag 0x0c).
    guard cursor < san.count, san[cursor] == 0x0c else { return nil }
    cursor += 1
    let (strLen, strConsumed) = parseDERLength(san, at: cursor)
    cursor += strConsumed
    guard cursor + strLen <= san.count else { return nil }
    return String(data: san[cursor ..< cursor + strLen], encoding: .utf8)
}

// MARK: - DER length helpers

/// Encode a length value in minimal DER form (1, 2, or 3 bytes).
func derMinimalLength(_ length: Int) -> [UInt8] {
    if length < 0x80 {
        return [UInt8(length)]
    } else if length <= 0xFF {
        return [0x81, UInt8(length)]
    } else {
        return [0x82, UInt8(length >> 8), UInt8(length & 0xFF)]
    }
}

/// Parse a DER length field starting at `index` in `data`.
/// Returns `(length, bytesConsumed)`.
func parseDERLength(_ data: Data, at index: Int) -> (Int, Int) {
    guard index < data.count else { return (0, 0) }
    let first = data[index]
    if first < 0x80 {
        return (Int(first), 1)
    }
    let numBytes = Int(first & 0x7f)
    var length = 0
    for i in 1 ... numBytes {
        guard index + i < data.count else { return (0, numBytes + 1) }
        length = (length << 8) | Int(data[index + i])
    }
    return (length, numBytes + 1)
}

// MARK: - LANRelayTLSError

/// Errors produced by LANRelayTLSConfig and LANRelayIdentityFactory.
public enum LANRelayTLSError: Error {
    /// The ephemeral identity factory is not yet wired for the target platform.
    /// See `LANRelayIdentityFactory.makeEphemeralIdentity(ed25519Fingerprint:)`.
    case notImplemented
    /// P-256 key generation failed (SecKeyCreateRandomKey returned nil).
    case keyGenerationFailed(underlying: CFError?)
    /// Certificate creation from DER bytes failed (SecCertificateCreateWithData returned nil).
    case certificateCreationFailed
    /// SecIdentity could not be formed from the private key + certificate.
    case identityCreationFailed
    /// Cannot export the public key for embedding in the certificate.
    case keyExportFailed
    /// Certificate signing failed.
    case signingFailed(underlying: CFError?)
}

// MARK: - Data hex decode helper

private extension Data {
    /// Initialize from a lowercase hex string. Returns nil if the string is not valid hex
    /// or has an odd number of characters.
    init?(hexEncoded: String) {
        guard hexEncoded.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexEncoded.count / 2)
        var index = hexEncoded.startIndex
        while index < hexEncoded.endIndex {
            let next = hexEncoded.index(index, offsetBy: 2)
            guard let byte = UInt8(hexEncoded[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
