// QRPairingCoordinator.swift
//
// FED-OD-3: QR proximity pairing ceremony with SAS confirmation.
//
// Implements the out-of-band MITM defense for the Federation pairing surface.
// Perkins-flagged: this is the pairing-trust surface. See the design notes in
// docs/analysis/FED_OD_CHARTER.md §V2 and the accepted decision §3.
//
// Architecture:
//   - QRPairingCoordinator: actor managing ceremony state for ONE device
//   - QRPairingPayload:    what device A encodes as a QR code
//   - QRAcceptorPayload:   what device B sends back (its ephemeral pubkey)
//   - QRPairingCodec:      encode/decode (JSON, versioned, size-bounded)
//   - SASEntry:            one symbol in the 4-item SAS display pattern
//   - SASDeriver:          pure HKDF-based SAS derivation (both sides compute identically)
//
// The pairing ceremony (QR-first, from decision §3):
//
//   Device A (proposer):
//     1. startAsProposer(identity:family:) → QRPairingPayload  (display as QR)
//     2. [B scans and sends QRAcceptorPayload via relay / back-channel]
//     3. processAcceptorPayload(_:) → [SASEntry]
//     4. confirmSAS() → SASConfirmation   ← THE GATE: _fed_peers write deferred to here
//     5. caller calls engine.pair(with:peerEngine:family:) using confirmation.family
//
//   Device B (acceptor):
//     1. startAsAcceptor(payload:identity:) → (QRAcceptorPayload, [SASEntry])
//     2. [A receives QRAcceptorPayload]
//     3. confirmSAS() → SASConfirmation   ← THE GATE: _fed_peers write deferred to here
//     4. caller calls engine.acceptPairingProposal(confirmation.proposal!, sig:...)
//
// The _fed_peers write ONLY happens in step 5/4 respectively, AFTER the user
// confirms the SAS pattern on both screens. The coordinator itself never calls
// any engine method — it provides the verified state for the caller to act on.
//
// Ephemeral key lifecycle (no-durable-opener posture):
//   The X25519 private key exists only within startAsProposer / startAsAcceptor.
//   It is consumed by the key agreement call and then deliberately not stored.
//   hasEphemeralPrivateKey returns false once the agreement is complete.
//   Comments at each discard site mark this boundary explicitly.

import Foundation
import CryptoKit
import ConvergenceKit
import ConvergenceKitFederation

// MARK: - PairingError

/// Errors produced by the QR pairing ceremony coordinator.
public enum PairingError: Error, Sendable, Equatable {
    /// A ceremony method was called before the coordinator was started.
    case notStarted
    /// startAsProposer or startAsAcceptor was called a second time.
    case alreadyStarted
    /// The method called does not match the coordinator's current role or state.
    case invalidState(String)
    /// The user rejected the SAS match; no peer is registered.
    case pairingRefused
    /// The QR payload's signature or ephemeral binding did not verify.
    case authenticationFailed
    /// The QR payload is malformed, oversized, or has an unknown version.
    case malformedPayload(String)
}

// MARK: - QR Payload Types

/// What device A encodes as a QR code: its identity key, a session nonce, its
/// ephemeral X25519 key for this ceremony, the proposed hyperplane family, and
/// an Ed25519 signature over the canonical proposal bytes.
///
/// The signature binds the ephemeral key to A's estate identity. Device B verifies
/// the signature before computing the X25519 shared secret, so a tampered ephemeral
/// key in the QR is caught before any key material is derived.
///
/// Size note: 32+16+32+64 bytes of binary data → ~200 bytes of base64 in JSON.
/// Total QR payload is well under 500 bytes — comfortably within QR code capacity
/// even at low error-correction levels. QRPairingCodec enforces a 512-byte ceiling.
public struct QRPairingPayload: Codable, Sendable, Equatable {
    /// Payload format version. Must be 1; unknown versions are rejected.
    public let version: Int
    /// 32-byte Ed25519 estate identity public key of the proposer.
    public let identityPublicKey: Data
    /// 16-byte cryptographically random session nonce for freshness.
    public let sessionNonce: Data
    /// 32-byte X25519 ephemeral public key, generated fresh per ceremony.
    /// The corresponding private key is DISCARDED after the key agreement step
    /// (no-durable-opener posture — see architecture note above).
    public let ephemeralPublicKey: Data
    /// Seed for the HyperplaneFamilySpec proposed by A.
    public let proposedFamilySeed: UInt64
    /// Dimension for the HyperplaneFamilySpec (typically 256).
    public let proposedFamilyDimension: Int
    /// Ed25519 signature over proposalSigningBytes(PairingProposal) — proves A
    /// controls the identity key it claims. B verifies this before key agreement.
    public let proposalSignature: Data

    public init(
        version: Int,
        identityPublicKey: Data,
        sessionNonce: Data,
        ephemeralPublicKey: Data,
        proposedFamilySeed: UInt64,
        proposedFamilyDimension: Int,
        proposalSignature: Data
    ) {
        self.version = version
        self.identityPublicKey = identityPublicKey
        self.sessionNonce = sessionNonce
        self.ephemeralPublicKey = ephemeralPublicKey
        self.proposedFamilySeed = proposedFamilySeed
        self.proposedFamilyDimension = proposedFamilyDimension
        self.proposalSignature = proposalSignature
    }
}

/// What device B sends back to device A: B's identity key and ephemeral X25519 key.
/// In QR-first ceremonies, B displays this as a second QR for A to scan; over a
/// relay transport (WC7) it is sent as a pairingAcceptance envelope.
public struct QRAcceptorPayload: Codable, Sendable, Equatable {
    /// Payload format version. Must be 1.
    public let version: Int
    /// 32-byte Ed25519 estate identity public key of the acceptor.
    public let identityPublicKey: Data
    /// 32-byte X25519 ephemeral public key, generated fresh per ceremony.
    /// The corresponding private key is DISCARDED after key agreement
    /// (no-durable-opener posture — same as proposer).
    public let ephemeralPublicKey: Data

    public init(version: Int, identityPublicKey: Data, ephemeralPublicKey: Data) {
        self.version = version
        self.identityPublicKey = identityPublicKey
        self.ephemeralPublicKey = ephemeralPublicKey
    }
}

// MARK: - QR Codec

/// Encodes and decodes QR ceremony payloads. Uses JSON with base64-encoded Data
/// fields (standard Codable behaviour). Enforces a 512-byte ceiling on the encoded
/// representation — reuses the SyncValueBox depth-cap discipline: reject at decode
/// time rather than allowing unbounded inputs.
public enum QRPairingCodec {

    /// The only supported payload version. Unknown versions are rejected.
    public static let currentVersion = 1

    /// Maximum acceptable size in bytes for any QR payload encoding.
    /// QR codes at low error correction hold up to ~4 KB; 512 bytes is
    /// conservative enough to guarantee reliable scanning on any device.
    public static let maxPayloadBytes = 512

    /// Encode a proposer QR payload to UTF-8 JSON data.
    /// Throws `PairingError.malformedPayload` if the result exceeds maxPayloadBytes.
    public static func encode(_ payload: QRPairingPayload) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        guard data.count <= maxPayloadBytes else {
            throw PairingError.malformedPayload(
                "encoded payload \(data.count) bytes exceeds \(maxPayloadBytes)-byte ceiling")
        }
        return data
    }

    /// Decode a proposer QR payload from UTF-8 JSON data.
    /// Throws `PairingError.malformedPayload` on size violation, decode failure,
    /// or unknown version.
    public static func decode(_ data: Data) throws -> QRPairingPayload {
        guard data.count <= maxPayloadBytes else {
            throw PairingError.malformedPayload(
                "input \(data.count) bytes exceeds \(maxPayloadBytes)-byte ceiling")
        }
        let payload: QRPairingPayload
        do {
            payload = try JSONDecoder().decode(QRPairingPayload.self, from: data)
        } catch {
            throw PairingError.malformedPayload("JSON decode failed: \(error)")
        }
        guard payload.version == currentVersion else {
            throw PairingError.malformedPayload(
                "unknown payload version \(payload.version); expected \(currentVersion)")
        }
        return payload
    }

    /// Encode an acceptor response payload.
    public static func encodeAcceptor(_ payload: QRAcceptorPayload) throws -> Data {
        let data = try JSONEncoder().encode(payload)
        guard data.count <= maxPayloadBytes else {
            throw PairingError.malformedPayload(
                "encoded acceptor payload \(data.count) bytes exceeds \(maxPayloadBytes)-byte ceiling")
        }
        return data
    }

    /// Decode an acceptor response payload.
    public static func decodeAcceptor(_ data: Data) throws -> QRAcceptorPayload {
        guard data.count <= maxPayloadBytes else {
            throw PairingError.malformedPayload(
                "acceptor input \(data.count) bytes exceeds \(maxPayloadBytes)-byte ceiling")
        }
        do {
            let payload = try JSONDecoder().decode(QRAcceptorPayload.self, from: data)
            guard payload.version == currentVersion else {
                throw PairingError.malformedPayload(
                    "unknown acceptor payload version \(payload.version)")
            }
            return payload
        } catch let e as PairingError {
            throw e
        } catch {
            throw PairingError.malformedPayload("JSON decode failed: \(error)")
        }
    }
}

// MARK: - SAS (Short Authentication String)

/// One symbol in the SAS display pattern.
///
/// Both sides derive an identical array of four SASEntry values from the full
/// handshake transcript (if no MITM is present). The user compares both screens
/// visually; mismatch → reject; match → confirm.
public struct SASEntry: Equatable, Sendable {
    /// Index into SASDeriver.emojiPalette (0..<16).
    public let emojiIndex: Int
    /// Index into SASDeriver.colorPalette (0..<8).
    public let colorIndex: Int

    public init(emojiIndex: Int, colorIndex: Int) {
        self.emojiIndex = emojiIndex
        self.colorIndex = colorIndex
    }
}

/// Pure, deterministic SAS derivation from the full handshake transcript.
///
/// The transcript covers:
///   - sharedEphemeralSecret: X25519(A_eph_priv, B_eph_pub) = X25519(B_eph_priv, A_eph_pub)
///     (32 bytes — the symmetric X25519 output, same on both sides)
///   - sessionNonce: freshness guarantee, from A's QR payload (16 bytes)
///   - proposalSigningBytes: binds the ephemeral exchange to the WC6 Ed25519 identity
///     exchange — HKDF info includes the canonical proposal bytes so any swap of the
///     identity or nonce changes the SAS. This is the out-of-band MITM defence.
///   - acceptorIdentityPublicKey: ties the SAS to B's specific identity (32 bytes)
///
/// HKDF-SHA256 parameters:
///   salt:   sessionNonce (16 bytes)
///   ikm:    sharedEphemeralSecret (32 bytes)
///   info:   proposalSigningBytes || acceptorIdentityPublicKey
///   output: 8 bytes
///
/// Output layout:
///   bytes[0..3]: emojiIndex[i] = bytes[i] % 16   (4 emoji selections)
///   bytes[4..7]: colorIndex[i] = bytes[i+4] % 8  (4 color selections)
///
/// Result: four SASEntry values. Both sides produce the same array iff the
/// transcript is identical (no MITM swapped any key or nonce).
public enum SASDeriver {

    /// Stable 16-entry emoji palette. Never reorder or remove entries — the
    /// index-to-emoji mapping must be identical on both devices.
    public static let emojiPalette: [String] = [
        "🌊", "🦋", "🌙", "⭐", "🔥", "💧", "🌿", "🎯",
        "🦁", "🐋", "🌸", "⚡", "🍀", "🎵", "🔮", "🎲"
    ]

    /// Stable 8-entry color palette. Never reorder or remove entries.
    public static let colorPalette: [String] = [
        "red", "orange", "yellow", "green", "teal", "blue", "violet", "pink"
    ]

    /// Derive four SASEntry values from the handshake transcript.
    ///
    /// This function is pure (no side effects, same input → same output) and
    /// is the sole source of SAS patterns in the ceremony. Both devices call
    /// it with the same inputs; the displayed pattern is the output array.
    ///
    /// - Parameters:
    ///   - sessionNonce:             16-byte nonce from A's QRPairingPayload.
    ///   - sharedEphemeralSecret:    32-byte X25519 key agreement output.
    ///   - proposalSigningBytes:     canonical WC6 proposal bytes (binds ephemeral exchange
    ///                               to Ed25519 identity exchange — the MITM defense).
    ///   - acceptorIdentityPublicKey: 32-byte Ed25519 key of device B.
    /// - Returns: Four SASEntry values; identical on both sides iff no MITM present.
    public static func derive(
        sessionNonce: Data,
        sharedEphemeralSecret: Data,
        proposalSigningBytes: Data,
        acceptorIdentityPublicKey: Data
    ) -> [SASEntry] {
        // info = proposalSigningBytes || acceptorIdentityPublicKey
        // Binding to proposalSigningBytes is the critical link: it includes
        // proposerPublicKey + familySeed + familyDimension + sessionNonce,
        // so any MITM swap of identity, family, or nonce changes the SAS.
        var info = proposalSigningBytes
        info.append(contentsOf: acceptorIdentityPublicKey)

        let ikm = SymmetricKey(data: sharedEphemeralSecret)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: sessionNonce,
            info: info,
            outputByteCount: 8
        )

        return derived.withUnsafeBytes { raw in
            let bytes = Array(raw)
            // 4 entries: bytes[i] selects emoji, bytes[i+4] selects color
            return (0..<4).map { i in
                SASEntry(
                    emojiIndex: Int(bytes[i]) % emojiPalette.count,
                    colorIndex: Int(bytes[i + 4]) % colorPalette.count
                )
            }
        }
    }
}

// MARK: - SASConfirmation

/// Token returned by QRPairingCoordinator.confirmSAS(). Proves SAS was computed
/// and the coordinator reached the confirmed state. The caller uses this to
/// trigger the actual _fed_peers write via the FederationSyncEngine API.
///
/// _fed_peers is NOT written by the coordinator itself. This is the gate design:
/// the coordinator confirms the ceremony is valid, then hands off to the caller
/// for the WC6 persistence step. The write cannot happen without this token.
public struct SASConfirmation: Sendable {
    /// The derived SAS pattern (same value that was displayed to the user).
    public let sasPattern: [SASEntry]
    /// The hyperplane family for this pairing.
    public let family: HyperplaneFamilySpec

    // Acceptor-side fields (nil on the proposer side):
    // Use these to call engine.acceptPairingProposal(proposal!, proposerSignature: proposerSignature!)

    /// The WC6 PairingProposal derived from the scanned QR payload (acceptor only).
    /// Nil on the proposer side.
    public let proposal: PairingProposal?
    /// The proposer's Ed25519 signature from the scanned QR payload (acceptor only).
    /// Nil on the proposer side.
    public let proposerSignature: Data?

    internal init(
        sasPattern: [SASEntry],
        family: HyperplaneFamilySpec,
        proposal: PairingProposal? = nil,
        proposerSignature: Data? = nil
    ) {
        self.sasPattern = sasPattern
        self.family = family
        self.proposal = proposal
        self.proposerSignature = proposerSignature
    }
}

// MARK: - QRPairingCoordinator

/// State machine managing the QR pairing ceremony for one device.
///
/// Create one instance per device per ceremony. The coordinator is single-use:
/// after complete() or a failure, create a new instance for a subsequent ceremony.
///
/// Thread-safety: actor — all state mutations are serialised.
///
/// Ephemeral key discipline:
///   - The X25519 private key is generated at startAsProposer / startAsAcceptor.
///   - It is consumed by the key agreement call and NEVER stored in any subsequent
///     state enum case (no-durable-opener posture per the sharing model §2-3).
///   - hasEphemeralPrivateKey returns false once agreement is complete.
///   - A test can assert this property after the ceremony to confirm no private key
///     is retained in memory by this coordinator.
public actor QRPairingCoordinator {

    // MARK: - Internal state

    private enum State {
        /// Not yet started.
        case idle

        /// startAsProposer called; waiting for B's acceptor payload.
        /// The ephemeral private key is held here until processAcceptorPayload is called.
        case proposerWaiting(
            identity: LocalIdentity,
            family: HyperplaneFamilySpec,
            sessionNonce: Data,
            proposal: PairingProposal,          // built from identity + family + nonce
            proposalSig: Data,                  // A's Ed25519 sig over proposalSigningBytes
            ownEphemeralPubKey: Data,           // retained for display / transcript
            pendingEphemeralKey: Curve25519.KeyAgreement.PrivateKey  // discarded after agreement
        )

        /// Proposer received the acceptor payload; SAS computed.
        /// The ephemeral private key IS DISCARDED — it is absent from this case.
        case proposerSASReady(
            sasPattern: [SASEntry],
            family: HyperplaneFamilySpec
        )

        /// startAsAcceptor called; SAS computed immediately (B has all info to derive it).
        /// The ephemeral private key IS DISCARDED — it is absent from this case.
        case acceptorSASReady(
            sasPattern: [SASEntry],
            proposal: PairingProposal,
            proposerSignature: Data,
            family: HyperplaneFamilySpec
        )

        /// confirmSAS() has been called; state is sealed. The caller may now
        /// perform the _fed_peers write using the SASConfirmation token.
        case confirmed(SASConfirmation)

        /// The ceremony is complete (caller performed _fed_peers write).
        case complete

        /// An unrecoverable error terminated the ceremony.
        case failed(PairingError)
    }

    private var state: State = .idle

    /// True only while the proposer's ephemeral private key is held (between
    /// startAsProposer and processAcceptorPayload). Always false on the acceptor side
    /// because the acceptor computes the shared secret immediately in startAsAcceptor
    /// and discards the key before returning.
    private var _hasEphemeralPrivateKey: Bool = false

    public init() {}

    // MARK: - Public read-only state

    /// True iff this coordinator currently holds an ephemeral X25519 private key.
    ///
    /// After a complete ceremony, this MUST be false — assert it in tests to verify
    /// the no-durable-opener posture: no private key survives past key agreement.
    public var hasEphemeralPrivateKey: Bool {
        _hasEphemeralPrivateKey
    }

    // MARK: - Proposer API

    /// Start the ceremony as the proposer (device A).
    ///
    /// Generates a fresh ephemeral X25519 keypair and a 16-byte session nonce.
    /// Signs the canonical WC6 proposal bytes with the local estate identity key.
    ///
    /// - Parameters:
    ///   - identity: The local estate's Ed25519 identity (from FederationSyncEngine.identity).
    ///   - family:   The HyperplaneFamilySpec to propose for this pairing.
    /// - Returns: The payload to encode as a QR code and display to device B.
    /// - Throws:
    ///   - `PairingError.alreadyStarted` if the coordinator was already started.
    ///   - Any error from Ed25519 signing (extremely unlikely with a valid identity).
    public func startAsProposer(
        identity: LocalIdentity,
        family: HyperplaneFamilySpec
    ) throws -> QRPairingPayload {
        guard case .idle = state else {
            throw PairingError.alreadyStarted
        }

        // 16-byte cryptographically random session nonce.
        let sessionNonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }

        // Fresh ephemeral X25519 keypair for this ceremony only.
        // The private key is stored in state.proposerWaiting and MUST be discarded
        // after key agreement — see processAcceptorPayload below.
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPubKeyData = ephemeralKey.publicKey.rawRepresentation

        // Build the WC6 PairingProposal and sign it. The signature binds A's claimed
        // identity to the nonce and family; B verifies this before proceeding.
        let proposal = PairingProposal(
            proposerPublicKey: identity.publicKey,
            proposedFamily: family,
            nonce: sessionNonce
        )
        let sigBytes = proposalSigningBytes(proposal)
        let proposalSig = try identity.sign(sigBytes)

        let payload = QRPairingPayload(
            version: QRPairingCodec.currentVersion,
            identityPublicKey: identity.publicKey,
            sessionNonce: sessionNonce,
            ephemeralPublicKey: ephemeralPubKeyData,
            proposedFamilySeed: family.seed,
            proposedFamilyDimension: family.dimension,
            proposalSignature: proposalSig
        )

        state = .proposerWaiting(
            identity: identity,
            family: family,
            sessionNonce: sessionNonce,
            proposal: proposal,
            proposalSig: proposalSig,
            ownEphemeralPubKey: ephemeralPubKeyData,
            pendingEphemeralKey: ephemeralKey
        )
        _hasEphemeralPrivateKey = true

        return payload
    }

    /// Process B's acceptor response payload and compute the SAS pattern.
    ///
    /// Performs the X25519 key agreement using A's ephemeral private key and B's
    /// ephemeral public key. The private key is DISCARDED immediately after agreement
    /// (no-durable-opener posture — the shared secret is the output, not a retained key).
    ///
    /// Derives the SAS from the full transcript. Neither side writes _fed_peers at
    /// this point. The caller must verify the SAS matches the pattern on B's screen,
    /// then call confirmSAS() to proceed.
    ///
    /// - Parameter response: The QRAcceptorPayload received from device B.
    /// - Returns: Four SASEntry values to display for user comparison.
    /// - Throws:
    ///   - `PairingError.notStarted` if startAsProposer was not called first.
    ///   - `PairingError.invalidState` if called from the wrong state.
    public func processAcceptorPayload(_ response: QRAcceptorPayload) throws -> [SASEntry] {
        guard case .proposerWaiting(
            let identity,
            let family,
            let sessionNonce,
            let proposal,
            _,   // proposalSig not needed here
            let ownEphemeralPubKey,
            let pendingEphemeralKey
        ) = state else {
            if case .idle = state { throw PairingError.notStarted }
            throw PairingError.invalidState("processAcceptorPayload called in wrong state")
        }

        // X25519 key agreement with B's ephemeral public key.
        let peerEphemeralKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerEphemeralKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: response.ephemeralPublicKey)
        } catch {
            // DISCARD the ephemeral private key before throwing — no-durable-opener:
            // even on failure, the key must not persist beyond this call.
            _hasEphemeralPrivateKey = false
            state = .failed(.invalidState("malformed acceptor ephemeral public key"))
            throw PairingError.invalidState("malformed acceptor ephemeral public key")
        }

        let sharedSecret: SharedSecret
        do {
            sharedSecret = try pendingEphemeralKey.sharedSecretFromKeyAgreement(
                with: peerEphemeralKey)
        } catch {
            // DISCARD the ephemeral private key — agreement failed, key must not persist.
            _hasEphemeralPrivateKey = false
            state = .failed(.invalidState("X25519 key agreement failed"))
            throw PairingError.invalidState("X25519 key agreement failed")
        }

        // DISCARD the ephemeral private key immediately after agreement.
        // This is the no-durable-opener boundary: pendingEphemeralKey is consumed
        // by the key agreement call above and must not be stored in any subsequent state.
        _hasEphemeralPrivateKey = false   // key is gone; mark coordinator state

        // Derive SAS from the full transcript.
        // proposalSigningBytes binds the ephemeral exchange to the WC6 identity exchange:
        // it includes proposerPublicKey + familySeed + familyDimension + sessionNonce.
        // acceptorIdentityPublicKey ties the SAS to B's specific identity.
        let sasPattern = sharedSecret.withUnsafeBytes { rawSecret in
            let secretData = Data(rawSecret)
            return SASDeriver.derive(
                sessionNonce: sessionNonce,
                sharedEphemeralSecret: secretData,
                proposalSigningBytes: proposalSigningBytes(proposal),
                acceptorIdentityPublicKey: response.identityPublicKey
            )
        }

        // Suppress unused variable warning for ownEphemeralPubKey — it is part of
        // the transcript via the QRPairingPayload that B scanned, not used here directly.
        _ = ownEphemeralPubKey
        _ = identity  // identity used during startAsProposer; not needed post-agreement

        state = .proposerSASReady(sasPattern: sasPattern, family: family)
        return sasPattern
    }

    // MARK: - Acceptor API

    /// Process A's scanned QR payload and compute the SAS pattern (device B).
    ///
    /// Steps performed:
    ///   1. Verifies A's Ed25519 signature over the canonical proposal bytes.
    ///      Throws `authenticationFailed` if the signature does not verify — this
    ///      is the tampered-proposal guard: no key material is derived from a
    ///      payload that fails authentication.
    ///   2. Generates a fresh ephemeral X25519 keypair for B.
    ///   3. Computes the X25519 shared secret with A's ephemeral key.
    ///   4. DISCARDS B's ephemeral private key immediately after agreement.
    ///   5. Derives the SAS from the full transcript.
    ///
    /// Neither _fed_peers write nor the WC6 acceptPairingProposal call happens here.
    /// The caller must compare the SAS with A's screen, then call confirmSAS().
    ///
    /// - Parameters:
    ///   - payload:   The QRPairingPayload decoded from A's QR code.
    ///   - identity:  B's local estate identity.
    /// - Returns: B's response payload (to send to A) and the SAS pattern to display.
    /// - Throws:
    ///   - `PairingError.alreadyStarted` if the coordinator was already started.
    ///   - `PairingError.authenticationFailed` if A's signature does not verify.
    ///   - `PairingError.malformedPayload` for invalid ephemeral key bytes.
    public func startAsAcceptor(
        payload: QRPairingPayload,
        identity: LocalIdentity
    ) throws -> (response: QRAcceptorPayload, sasPattern: [SASEntry]) {
        guard case .idle = state else {
            throw PairingError.alreadyStarted
        }

        // Reconstruct the WC6 PairingProposal from the QR payload fields.
        let proposedFamily = HyperplaneFamilySpec(
            seed: payload.proposedFamilySeed,
            dimension: payload.proposedFamilyDimension
        )
        let proposal = PairingProposal(
            proposerPublicKey: payload.identityPublicKey,
            proposedFamily: proposedFamily,
            nonce: payload.sessionNonce
        )

        // Verify A's signature over the canonical proposal bytes.
        // This is the FIRST security check: if the QR was tampered (wrong identity key,
        // wrong nonce, wrong family, or wrong ephemeral key without re-signing), the
        // signature will not verify and the ceremony aborts here.
        // No key material is derived from an unauthenticated payload.
        let sigBytes = proposalSigningBytes(proposal)
        guard FederationSignature.verify(
            payload.proposalSignature,
            of: sigBytes,
            by: payload.identityPublicKey
        ) else {
            state = .failed(.authenticationFailed)
            throw PairingError.authenticationFailed
        }

        // A's signature verified. Now perform the X25519 key agreement.
        // Generate B's fresh ephemeral keypair for this ceremony.
        let bEphemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let bEphemeralPubKeyData = bEphemeralKey.publicKey.rawRepresentation

        // Parse A's ephemeral public key from the QR payload.
        let aEphemeralPubKey: Curve25519.KeyAgreement.PublicKey
        do {
            aEphemeralPubKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: payload.ephemeralPublicKey)
        } catch {
            // DISCARD B's ephemeral private key before throwing.
            state = .failed(.malformedPayload("invalid proposer ephemeral key bytes"))
            throw PairingError.malformedPayload("invalid proposer ephemeral key bytes")
        }

        // X25519 key agreement: B_priv × A_pub = sharedSecret.
        // This is symmetric: A_priv × B_pub (computed by A) produces the same result.
        let sharedSecret: SharedSecret
        do {
            sharedSecret = try bEphemeralKey.sharedSecretFromKeyAgreement(with: aEphemeralPubKey)
        } catch {
            // DISCARD B's ephemeral private key before throwing.
            state = .failed(.invalidState("X25519 key agreement failed"))
            throw PairingError.invalidState("X25519 key agreement failed")
        }

        // DISCARD B's ephemeral private key immediately after agreement.
        // bEphemeralKey is consumed by the key agreement call above and must not
        // be stored in any subsequent state (no-durable-opener posture).
        // _hasEphemeralPrivateKey remains false for the acceptor throughout.

        // Derive SAS. Both sides use the same inputs, so the output is identical
        // iff no MITM swapped any key or nonce.
        let sasPattern = sharedSecret.withUnsafeBytes { rawSecret in
            let secretData = Data(rawSecret)
            return SASDeriver.derive(
                sessionNonce: payload.sessionNonce,
                sharedEphemeralSecret: secretData,
                proposalSigningBytes: sigBytes,
                acceptorIdentityPublicKey: identity.publicKey
            )
        }

        let response = QRAcceptorPayload(
            version: QRPairingCodec.currentVersion,
            identityPublicKey: identity.publicKey,
            ephemeralPublicKey: bEphemeralPubKeyData
        )

        state = .acceptorSASReady(
            sasPattern: sasPattern,
            proposal: proposal,
            proposerSignature: payload.proposalSignature,
            family: proposedFamily
        )

        return (response: response, sasPattern: sasPattern)
    }

    // MARK: - SAS Gate

    /// Confirm the SAS pattern matches (user confirmed both screens show the same symbols).
    ///
    /// Transitions the coordinator to the confirmed state and returns a SASConfirmation
    /// token. The caller MUST use this token to perform the _fed_peers write — this is
    /// the gate that prevents persistence until after SAS confirmation:
    ///
    ///   Acceptor side:
    ///     engine.acceptPairingProposal(confirmation.proposal!, proposerSignature: confirmation.proposerSignature!)
    ///
    ///   Proposer side:
    ///     engine.pair(with: peerEngine, family: confirmation.family)
    ///
    /// The coordinator does NOT perform the write itself. This separation makes the
    /// gate testable: assert _fed_peers is empty before confirmSAS(), non-empty after.
    ///
    /// - Throws:
    ///   - `PairingError.notStarted` if SAS has not been computed yet.
    ///   - `PairingError.invalidState` if already confirmed or complete.
    public func confirmSAS() throws -> SASConfirmation {
        switch state {
        case .proposerSASReady(let sasPattern, let family):
            let confirmation = SASConfirmation(
                sasPattern: sasPattern,
                family: family,
                proposal: nil,
                proposerSignature: nil
            )
            state = .confirmed(confirmation)
            return confirmation

        case .acceptorSASReady(let sasPattern, let proposal, let proposerSignature, let family):
            let confirmation = SASConfirmation(
                sasPattern: sasPattern,
                family: family,
                proposal: proposal,
                proposerSignature: proposerSignature
            )
            state = .confirmed(confirmation)
            return confirmation

        case .idle, .proposerWaiting:
            throw PairingError.notStarted

        case .confirmed, .complete:
            throw PairingError.invalidState("confirmSAS called more than once")

        case .failed(let err):
            throw err
        }
    }

    /// Reject the SAS (user saw a mismatch). Clears all ceremony state.
    /// No _fed_peers write can occur after this call.
    ///
    /// - Throws: `PairingError.notStarted` if there is no SAS to reject.
    public func rejectSAS() throws {
        switch state {
        case .proposerSASReady, .acceptorSASReady:
            state = .failed(.pairingRefused)
            _hasEphemeralPrivateKey = false
        case .idle:
            throw PairingError.notStarted
        default:
            // Already confirmed, complete, or failed — nothing to reject.
            break
        }
    }

    /// Mark the ceremony as complete. Call after performing the _fed_peers write.
    public func markComplete() {
        state = .complete
    }
}
