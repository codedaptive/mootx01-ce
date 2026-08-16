import CryptoKit
import Foundation

// MARK: - First-party authenticated wire — the frozen protocol core
//
// This file is the whole of the language-neutral contract between a first-party
// application and the resident daemon. Everything here is FROZEN: the byte
// encoding, the domain strings, the derivation ladder, and the field orders are
// published as golden vectors in
// `docs/reference/vectors/ARIA_MCP_FIRST_PARTY_AUTH_V1.json` and independently
// recomputed by the Rust vector test. Changing any byte here without bumping
// the descriptor schema breaks every peer that already agreed to it.
//
// WHY A HAND-ROLLED BINARY ENCODING RATHER THAN JSON.
// A MAC is only as good as the agreement on what was MACed. JSON gives no
// canonical byte order (key order is unspecified), no canonical number form,
// and no canonical string escaping, so two conforming serializers can disagree
// on bytes while agreeing on meaning — and a MAC computed over one will fail
// against the other, or worse, two different messages can share a serialization.
// The encoding below is length-prefixed and fixed-order, which makes the byte
// string a total function of the field values and nothing else.
//
// WHY LENGTH PREFIXES RATHER THAN DELIMITERS.
// Delimiter concatenation is ambiguous: "a" ‖ "bc" and "ab" ‖ "c" produce the
// same bytes, so a MAC over the concatenation authenticates neither field
// individually. An attacker who controls two adjacent fields can move the
// boundary between them without changing the MAC input. A UInt32 length before
// every variable-length field removes the boundary from attacker control.
//
// WHY THE DERIVATION LADDER HAS THREE RUNGS.
// K_install is long-lived and lives in the data-protection Keychain. It is never
// used to authenticate a request directly: a long-lived key used per-request is
// a key whose exposure window is the lifetime of the install. Instead
// K_install derives K_descriptor (descriptor integrity), K_auth (handshake
// proofs, salted by the descriptor digest so a proof cannot be replayed against
// a different descriptor), and K_session (per-session request/response MACs,
// salted by the transcript hash so it is unique per handshake). Each rung has a
// distinct HKDF `info` domain, so no two rungs can ever collide.

/// The fixed constants, canonical encodings, and derivations of the first-party
/// authenticated wire.
///
/// A caseless enum: this is a namespace, never a value.
public enum FirstPartyAuthProtocol {

    // MARK: - Endpoint and routing constants

    /// The one endpoint a first-party client will dial. No hostname, no IPv6
    /// alternate, no query, fragment, userinfo, redirect target, or
    /// caller-supplied override is ever accepted — "localhost" resolves through
    /// `/etc/hosts` and the resolver, both of which are writable by an attacker
    /// who has the access this lane is meant to survive.
    public static let endpoint = "http://127.0.0.1:4242/mcp/first-party"

    /// The exact request path. Bound into every request MAC, so a peer cannot
    /// replay a signed body against a different route.
    public static let requestPath = "/mcp/first-party"

    /// Handshake step 1: the client presents a nonce and a descriptor digest.
    public static let challengePath = "/mcp/first-party/session/challenge"

    /// Handshake step 2: the client presents its proof and the server returns
    /// an establishment proof under the derived session key.
    public static let establishPath = "/mcp/first-party/session/establish"

    /// The only media type the lane accepts, after case-insensitive header-name
    /// parsing and media-type normalization. Parameters are refused rather than
    /// ignored: `application/json; charset=utf-8` is a different string, and a
    /// lane that normalizes it has two spellings for one value and therefore two
    /// possible MAC inputs.
    public static let contentType = "application/json"

    /// The only method the lane accepts, compared after uppercasing.
    public static let requestMethod = "POST"

    // MARK: - Identity constants

    /// The installer-owned provider permitted to publish a descriptor.
    public static let providerIdentifier = "com.mootx01.mgr"

    /// The resident daemon service that owns the estate.
    public static let serviceIdentifier = "com.mootx01.daemon"

    /// The authentication scheme this contract implements. A descriptor naming
    /// any other scheme is refused rather than negotiated: security properties
    /// do not downgrade.
    public static let authProtocolIdentifier = "hmac-sha256-hkdf-v1"

    /// Names which root credential the descriptor was authenticated under. It
    /// selects a key, and is never used to build a Keychain query — see
    /// `keychainAccount`.
    public static let authKeyIdentifier = "installation-root-v1"

    /// The descriptor wire-schema this contract implements.
    public static let descriptorSchemaVersion = 2

    /// The client/daemon contract revision this file implements.
    public static let contractRevision = 2

    /// The MCP protocol version the first-party lane requires exactly.
    public static let mcpProtocolVersion = "2025-11-25"

    // MARK: - Root credential location
    //
    // Both strings are PROTOCOL CONSTANTS, never read from a descriptor. A
    // descriptor is attacker-controlled input until its MAC verifies, and its
    // MAC is taken under a key found at this account — so accepting the account
    // name from the descriptor would let an attacker point the reader at an item
    // they control and then "verify" their own forgery against it.

    /// The Keychain service the installation root lives under.
    public static let keychainService = "com.codedaptive.mootx01.daemon-auth"

    /// The Keychain account the installation root lives under.
    public static let keychainAccount = "installation-root-v1"

    /// The installation root is exactly this many bytes. A shorter item is
    /// malformed and fatal — never padded, never stretched.
    public static let rootKeyByteCount = 32

    // MARK: - Sizes

    /// Handshake nonce width, both directions.
    public static let nonceByteCount = 32

    /// Opaque session identifier width. Random, never a counter: a predictable
    /// identifier lets an attacker name a session it has not observed.
    public static let sessionIdentifierByteCount = 16

    /// Every MAC and proof in this protocol is a full SHA-256 output. Truncation
    /// is not offered — a truncated MAC is a weaker MAC for no wire saving that
    /// matters on loopback.
    public static let macByteCount = 32

    // MARK: - Bounded state
    //
    // These are security limits, not tuning knobs. Every table an unauthenticated
    // peer can grow is a memory-exhaustion primitive, so each has a hard cap and
    // a expiry, and at capacity the server refuses rather than evicting a live
    // entry — eviction would let an attacker flush a legitimate peer's session by
    // flooding.

    /// Maximum simultaneously outstanding challenges.
    public static let maxChallenges = 128

    /// A challenge is single-use and expires this many seconds after issue.
    public static let challengeLifetime: UInt64 = 30

    /// Maximum simultaneously live sessions.
    public static let maxSessions = 64

    /// Idle expiry. Refreshed only by an ACCEPTED authenticated request, so a
    /// stream of rejected requests cannot hold a session open.
    public static let sessionIdleTimeout: UInt64 = 900

    /// Absolute expiry. Never refreshed; an authenticated session has a hard
    /// ceiling regardless of activity.
    public static let sessionAbsoluteTimeout: UInt64 = 28_800

    /// Width of the replay bitmap, in sequences below the highest seen.
    public static let replayWindowWidth: UInt64 = 128

    // MARK: - Header names and the authorization scheme

    /// Carries only the opaque session identifier — never a key, never a proof.
    public static let authorizationHeader = "authorization"

    /// The authorization scheme token preceding the base64url session id.
    public static let authorizationScheme = "Mootx01Session"

    /// Canonical unsigned decimal UInt64.
    public static let sequenceHeader = "mootx01-sequence"

    /// base64url-no-padding 32-byte request MAC.
    public static let requestMACHeader = "mootx01-request-mac"

    /// base64url-no-padding 32-byte response MAC.
    public static let responseMACHeader = "mootx01-response-mac"

    // MARK: - Domain separation strings
    //
    // Every keyed operation is prefixed by a distinct domain, and every derived
    // key by a distinct HKDF `info`. Without this, one construction's output is
    // a valid input to another — which is exactly how a reflection attack works:
    // a peer echoes the server's proof back and it authenticates as the client's.

    /// Descriptor integrity domain — HKDF `info` and MAC prefix.
    public static let descriptorDomain = "MOOTX01-DESCRIPTOR-v1"

    /// Session transcript prefix.
    public static let sessionDomain = "MOOTX01-DAEMON-SESSION-v1"

    /// Handshake key HKDF `info`.
    public static let authDomain = "MOOTX01-AUTH-v1"

    /// Server proof prefix. Distinct from the client's — see `clientProofDomain`.
    public static let serverProofDomain = "MOOTX01-SERVER-PROOF-v1"

    /// Client proof prefix. Distinct from the server's so a reflected server
    /// proof can never satisfy the client check.
    public static let clientProofDomain = "MOOTX01-CLIENT-PROOF-v1"

    /// Session key HKDF `info`.
    public static let sessionKeyDomain = "MOOTX01-REQUEST-SESSION-v1"

    /// Establishment proof prefix, taken under the session key so verifying it
    /// proves both peers derived the same session key.
    public static let establishedDomain = "MOOTX01-ESTABLISHED-v1"

    /// Request MAC prefix.
    public static let requestDomain = "MOOTX01-REQUEST-v1"

    /// Response MAC prefix. Distinct from the request's so a captured request
    /// MAC cannot be presented as a response MAC for the same session and
    /// sequence.
    public static let responseDomain = "MOOTX01-RESPONSE-v1"

    // MARK: - Primitives

    /// HMAC-SHA256 (RFC 2104).
    ///
    /// - Parameters:
    ///   - key: The MAC key. Callers pass a derived key, never `K_install`.
    ///   - message: The canonical bytes to authenticate.
    /// - Returns: The 32-byte tag.
    public static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(message), using: SymmetricKey(data: Data(key))
        )
        return Array(code)
    }

    /// HKDF-SHA256 extract-and-expand (RFC 5869).
    ///
    /// - Parameters:
    ///   - inputKeyingMaterial: The IKM — `K_install` at every call site here.
    ///   - salt: The salt. RFC 5869 §2.2 defines an omitted salt as HashLen
    ///     zero octets; callers that "omit" it pass 32 zero bytes explicitly so
    ///     the vector file records the value actually used rather than an
    ///     implementation default a Rust peer would have to guess.
    ///   - info: The domain-separating context string.
    ///   - outputByteCount: Length of the derived key.
    /// - Returns: The derived key.
    public static func hkdfSHA256(
        inputKeyingMaterial: [UInt8],
        salt: [UInt8],
        info: [UInt8],
        outputByteCount: Int
    ) -> [UInt8] {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(inputKeyingMaterial)),
            salt: Data(salt),
            info: Data(info),
            outputByteCount: outputByteCount
        )
        return derived.withUnsafeBytes { Array($0) }
    }

    /// SHA-256 of `bytes`.
    public static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(bytes)))
    }

    /// SHA-256 of `data`.
    public static func sha256(_ data: Data) -> [UInt8] {
        Array(SHA256.hash(data: data))
    }

    /// Compare two byte strings without leaking WHERE they differ through timing.
    ///
    /// Lengths are compared first and non-secret: every value compared here has
    /// a length fixed by the protocol, so an unequal length means a malformed
    /// message rather than a partially-guessed secret. The byte comparison
    /// itself accumulates a difference across the whole buffer instead of
    /// returning at the first mismatch — an early return turns a MAC check into
    /// a byte-at-a-time oracle.
    ///
    /// - Returns: `true` when the two are byte-identical.
    public static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    // MARK: - Derivation ladder

    /// `K_descriptor = HKDF-SHA256(K_install, salt = 32 zero octets, info = descriptor domain)`.
    ///
    /// The salt is the RFC 5869 omitted-salt value rather than the descriptor
    /// digest, because this key must be derivable BEFORE any descriptor has been
    /// verified — it is the key that verifies them.
    public static func descriptorKey(installationRoot: [UInt8]) -> [UInt8] {
        hkdfSHA256(
            inputKeyingMaterial: installationRoot,
            salt: [UInt8](repeating: 0, count: 32),
            info: Array(descriptorDomain.utf8),
            outputByteCount: macByteCount
        )
    }

    /// `K_auth = HKDF-SHA256(K_install, salt = descriptor digest, info = auth domain)`.
    ///
    /// Salting with the descriptor digest binds the handshake to one exact
    /// descriptor: a proof produced under one descriptor cannot authenticate a
    /// session against another, so republishing a descriptor invalidates every
    /// proof taken under the previous one.
    public static func authKey(installationRoot: [UInt8], descriptorDigest: [UInt8]) -> [UInt8] {
        hkdfSHA256(
            inputKeyingMaterial: installationRoot,
            salt: descriptorDigest,
            info: Array(authDomain.utf8),
            outputByteCount: macByteCount
        )
    }

    /// `K_session = HKDF-SHA256(K_install, salt = SHA-256(transcript), info = session domain)`.
    ///
    /// Salting with the transcript hash makes the session key a function of
    /// every negotiated value including both nonces, so two handshakes never
    /// share a session key even against an identical descriptor.
    public static func sessionKey(installationRoot: [UInt8], transcript: [UInt8]) -> [UInt8] {
        hkdfSHA256(
            inputKeyingMaterial: installationRoot,
            salt: sha256(transcript),
            info: Array(sessionKeyDomain.utf8),
            outputByteCount: macByteCount
        )
    }

    // MARK: - Proofs

    /// `serverProof = HMAC(K_auth, canonical(server domain) ‖ transcript)`.
    public static func serverProof(authKey: [UInt8], transcript: [UInt8]) -> [UInt8] {
        hmacSHA256(key: authKey, message: domainPrefixed(serverProofDomain, transcript))
    }

    /// `clientProof = HMAC(K_auth, canonical(client domain) ‖ transcript)`.
    public static func clientProof(authKey: [UInt8], transcript: [UInt8]) -> [UInt8] {
        hmacSHA256(key: authKey, message: domainPrefixed(clientProofDomain, transcript))
    }

    /// `establishmentProof = HMAC(K_session, canonical(established domain) ‖ transcript)`.
    ///
    /// Taken under the SESSION key rather than the auth key: verifying it is how
    /// the client learns the server derived the same `K_session` it did, which
    /// is the precondition for creating an authenticated transport.
    public static func establishmentProof(sessionKey: [UInt8], transcript: [UInt8]) -> [UInt8] {
        hmacSHA256(key: sessionKey, message: domainPrefixed(establishedDomain, transcript))
    }

    /// Prefix `body` with a canonically-encoded domain string.
    private static func domainPrefixed(_ domain: String, _ body: [UInt8]) -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(domain)
        return encoder.bytes + body
    }

    // MARK: - Session transcript

    /// The canonical transcript both peers hash and MAC over.
    ///
    /// Field order is fixed and exhaustive: every value either peer relies on
    /// appears exactly once, so neither can be induced to accept a session
    /// negotiated under terms it did not see. `descriptorGeneration` and
    /// `credentialGeneration` are included so a stale descriptor or a rotated
    /// credential cannot be replayed into a fresh session.
    public static func sessionTranscript(
        descriptorDigest: [UInt8],
        providerIdentifier: String,
        serviceIdentifier: String,
        endpoint: String,
        instanceIdentifier: UUID,
        estateIdentifier: UUID,
        binaryVersion: String,
        descriptorSchemaVersion: Int,
        contractRevision: Int,
        mcpProtocolVersion: String,
        credentialGeneration: UInt64,
        descriptorGeneration: UInt64,
        clientNonce: [UInt8],
        serverNonce: [UInt8],
        sessionIdentifier: [UInt8],
        issuedAt: UInt64,
        idleExpiry: UInt64,
        absoluteExpiry: UInt64
    ) -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(sessionDomain)                       // 1
        encoder.appendBytes(descriptorDigest)                     // 2
        encoder.appendString(providerIdentifier)                  // 3
        encoder.appendString(serviceIdentifier)                   // 4
        encoder.appendString(endpoint)                            // 5
        encoder.appendUUID(instanceIdentifier)                    // 6
        encoder.appendUUID(estateIdentifier)                      // 7
        encoder.appendString(binaryVersion)                       // 8
        encoder.appendUInt64(UInt64(descriptorSchemaVersion))     // 9
        encoder.appendUInt64(UInt64(contractRevision))            // 10
        encoder.appendString(mcpProtocolVersion)                  // 11
        encoder.appendUInt64(credentialGeneration)                // 12
        encoder.appendUInt64(descriptorGeneration)                // 13
        encoder.appendBytes(clientNonce)                          // 14
        encoder.appendBytes(serverNonce)                          // 15
        encoder.appendBytes(sessionIdentifier)                    // 16
        encoder.appendUInt64(issuedAt)                            // 17
        encoder.appendUInt64(idleExpiry)                          // 18
        encoder.appendUInt64(absoluteExpiry)                      // 19
        return encoder.bytes
    }

    // MARK: - Request and response authentication

    /// The request MAC.
    ///
    /// Covers the method, the exact path, and the content type as well as the
    /// body — a MAC over the body alone authenticates the payload but not the
    /// operation, so a signed body could be replayed against a different route
    /// or verb. The body is included by SHA-256 rather than inline so the MAC
    /// input stays bounded regardless of payload size.
    public static func requestMAC(
        sessionKey: [UInt8],
        sessionIdentifier: [UInt8],
        sequence: UInt64,
        method: String,
        path: String,
        contentType: String,
        body: Data
    ) -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(requestDomain)      // 1
        encoder.appendBytes(sessionIdentifier)   // 2
        encoder.appendUInt64(sequence)           // 3
        encoder.appendString(method)             // 4
        encoder.appendString(path)               // 5
        encoder.appendString(contentType)        // 6
        encoder.appendBytes(sha256(body))        // 7
        return hmacSHA256(key: sessionKey, message: encoder.bytes)
    }

    /// The response MAC.
    ///
    /// Binds the answer to the question by including the REQUEST's sequence, so
    /// a response captured for one request cannot be replayed as the answer to
    /// another. The status is covered so a peer cannot downgrade a 200 to a 401
    /// (or forge the reverse) without detection, and an empty 204 acknowledgement
    /// is authenticated exactly like a body-bearing 200 — an unauthenticated
    /// "nothing happened" is as useful to an attacker as a forged result.
    public static func responseMAC(
        sessionKey: [UInt8],
        sessionIdentifier: [UInt8],
        sequence: UInt64,
        status: UInt16,
        contentType: String,
        body: Data
    ) -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(responseDomain)     // 1
        encoder.appendBytes(sessionIdentifier)   // 2
        encoder.appendUInt64(sequence)           // 3
        encoder.appendUInt16(status)             // 4
        encoder.appendString(contentType)        // 5
        encoder.appendBytes(sha256(body))        // 6
        return hmacSHA256(key: sessionKey, message: encoder.bytes)
    }

    // MARK: - Wire encodings

    /// base64url without padding (RFC 4648 §5).
    ///
    /// Unpadded because the decoded length is fixed by the protocol at every
    /// call site, so padding carries no information and a padded spelling would
    /// be a second encoding of the same value.
    public static func base64URLEncode(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Decode base64url-no-padding, STRICTLY.
    ///
    /// Rejects padding, the standard alphabet's `+` and `/`, whitespace, and any
    /// other non-alphabet byte, rather than tolerating them. Tolerance would
    /// give one byte string several spellings, and a value that can be spelled
    /// two ways is a value two peers can disagree about while both believing
    /// they agree.
    ///
    /// - Returns: The decoded bytes, or `nil` if the input is not canonical.
    public static func base64URLDecode(_ string: String) -> [UInt8]? {
        guard !string.isEmpty else { return nil }
        for character in string.unicodeScalars {
            let isAlphabet = (character >= "A" && character <= "Z")
                || (character >= "a" && character <= "z")
                || (character >= "0" && character <= "9")
                || character == "-" || character == "_"
            guard isAlphabet else { return nil }
        }
        // A base64 quantum is 4 characters; a remainder of 1 encodes no whole
        // byte and is therefore not a valid unpadded encoding of anything.
        let remainder = string.count % 4
        guard remainder != 1 else { return nil }
        var standard = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        if remainder != 0 {
            standard += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: standard) else { return nil }
        return Array(data)
    }

    /// Parse the sequence header as canonical unsigned decimal.
    ///
    /// Accepts exactly one spelling per value: no sign, no whitespace, no
    /// leading zero, and never the value zero (sequences start at 1, so a
    /// received 0 is either a bug or a probe). `UInt64(_:)` returns nil on
    /// overflow, so an out-of-range sequence is refused rather than truncated
    /// into a valid-looking one.
    ///
    /// - Returns: The sequence, or `nil` when the spelling is not canonical.
    public static func parseSequenceHeader(_ raw: String) -> UInt64? {
        guard !raw.isEmpty else { return nil }
        guard raw.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        // Rejects both "0" and any leading-zero spelling such as "01".
        guard raw.first != "0" else { return nil }
        return UInt64(raw)
    }

    /// Render a sequence in the one canonical spelling the parser accepts.
    public static func formatSequenceHeader(_ sequence: UInt64) -> String {
        String(sequence)
    }
}

// MARK: - Canonical encoder

/// The length-prefixed, fixed-order binary encoder every MAC input is built with.
///
/// Deliberately minimal: it offers exactly the six field kinds the protocol
/// uses and no general-purpose "append arbitrary bytes" escape hatch, because
/// an unprefixed append is precisely the ambiguity the encoder exists to
/// prevent. Multi-byte integers are big-endian — network byte order, and
/// independent of whatever the host happens to be.
public struct CanonicalEncoder: Sendable {

    /// The accumulated canonical bytes.
    public private(set) var bytes: [UInt8] = []

    public init() {}

    /// UTF-8 bytes preceded by their UInt32 big-endian length.
    public mutating func appendString(_ value: String) {
        appendBytes(Array(value.utf8))
    }

    /// A byte string preceded by its UInt32 big-endian length.
    public mutating func appendBytes(_ value: [UInt8]) {
        appendUInt32(UInt32(value.count))
        bytes.append(contentsOf: value)
    }

    /// A UInt64 as 8 big-endian bytes. Timestamps use this form.
    public mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    /// A UInt32 as 4 big-endian bytes.
    public mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    /// A UInt16 as 2 big-endian bytes. HTTP status codes use this form.
    public mutating func appendUInt16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value))
    }

    /// A UUID as its 16 RFC 4122 bytes.
    ///
    /// The raw bytes rather than the string form: the string has case and
    /// hyphenation variants, so two peers could spell one identifier two ways
    /// and produce two MAC inputs for one value.
    public mutating func appendUUID(_ value: UUID) {
        let u = value.uuid
        bytes.append(contentsOf: [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ])
    }

    /// A capability set: sorted by wire spelling, counted, then each entry
    /// length-prefixed.
    ///
    /// Sorting is what makes the encoding independent of the order the daemon
    /// happened to build its set in — two daemons advertising the same
    /// capabilities must produce identical bytes, or the descriptor MAC would
    /// depend on `Set` iteration order.
    public mutating func appendCapabilities(_ values: [String]) {
        let sorted = values.sorted()
        appendUInt32(UInt32(sorted.count))
        for value in sorted {
            appendString(value)
        }
    }
}

// MARK: - Descriptor v2

/// What a resident daemon publishes about itself, schema 2.
///
/// A descriptor is a CLAIM until `descriptorMAC` verifies under a key derived
/// from the installation root. Every field is attacker-controlled input before
/// that point, which is why the client canonicalizes and verifies the MAC
/// before it uses any field to build a network request — including the endpoint.
///
/// It carries no estate path, no estate key, no authentication root, no session
/// key, no nonce, no bearer token, no install path, and no PID. A descriptor
/// tells a client how to ASK; it never tells it how to OPEN.
public struct FirstPartyDescriptor: Sendable, Equatable {

    /// Wire-schema. Checked before any other field is given weight.
    public var schemaVersion: Int

    /// The provider that published this descriptor.
    public var providerIdentifier: String

    /// The daemon service described.
    public var serviceIdentifier: String

    /// Where the daemon listens. Compared against the exact contracted endpoint.
    public var endpoint: String

    /// The authentication scheme. Must match exactly; never negotiated down.
    public var authProtocol: String

    /// Which root credential authenticated this descriptor.
    public var authKeyIdentifier: String

    /// Publication time, seconds since the Unix epoch.
    public var publishedAt: UInt64

    /// Identifies this particular running daemon process.
    public var instanceIdentifier: UUID

    /// Identifies the estate the daemon owns. An identifier only.
    public var estateIdentifier: UUID

    /// The daemon binary's marketing version. Must equal the authenticated
    /// `serverInfo.version` — descriptor-to-running-server, not app-to-server.
    public var binaryVersion: String

    /// The client/daemon contract revision the daemon implements.
    public var contractRevision: Int

    /// The MCP protocol version the daemon negotiates.
    public var mcpProtocolVersion: String

    /// What the daemon advertises it can do, in stable wire spelling.
    public var capabilities: [String]

    /// Monotonic. Bumped by an explicit root rotation, which invalidates every
    /// session derived under the previous root.
    public var credentialGeneration: UInt64

    /// Monotonic. Bumped whenever the descriptor is republished, so a stale
    /// descriptor cannot be replayed as current.
    public var descriptorGeneration: UInt64

    /// `HMAC-SHA256(K_descriptor, macInput())`. Excluded from its own input.
    public var descriptorMAC: [UInt8]

    /// Memberwise initializer, spelled out so the v2 field list is a documented
    /// public surface rather than a synthesized accident — and so that adding a
    /// field is a compile-time break at every construction site rather than a
    /// silent default.
    public init(
        schemaVersion: Int,
        providerIdentifier: String,
        serviceIdentifier: String,
        endpoint: String,
        authProtocol: String,
        authKeyIdentifier: String,
        publishedAt: UInt64,
        instanceIdentifier: UUID,
        estateIdentifier: UUID,
        binaryVersion: String,
        contractRevision: Int,
        mcpProtocolVersion: String,
        capabilities: [String],
        credentialGeneration: UInt64,
        descriptorGeneration: UInt64,
        descriptorMAC: [UInt8]
    ) {
        self.schemaVersion = schemaVersion
        self.providerIdentifier = providerIdentifier
        self.serviceIdentifier = serviceIdentifier
        self.endpoint = endpoint
        self.authProtocol = authProtocol
        self.authKeyIdentifier = authKeyIdentifier
        self.publishedAt = publishedAt
        self.instanceIdentifier = instanceIdentifier
        self.estateIdentifier = estateIdentifier
        self.binaryVersion = binaryVersion
        self.contractRevision = contractRevision
        self.mcpProtocolVersion = mcpProtocolVersion
        self.capabilities = capabilities
        self.credentialGeneration = credentialGeneration
        self.descriptorGeneration = descriptorGeneration
        self.descriptorMAC = descriptorMAC
    }

    /// The canonical bytes the descriptor MAC is taken over: the descriptor
    /// domain followed by every field EXCEPT `descriptorMAC`.
    ///
    /// Excluding the MAC from its own input is not a convention — a MAC that
    /// covered itself would have no fixed point to compute.
    public func macInput() -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendString(FirstPartyAuthProtocol.descriptorDomain)
        encoder.appendUInt64(UInt64(schemaVersion))
        encoder.appendString(providerIdentifier)
        encoder.appendString(serviceIdentifier)
        encoder.appendString(endpoint)
        encoder.appendString(authProtocol)
        encoder.appendString(authKeyIdentifier)
        encoder.appendUInt64(publishedAt)
        encoder.appendUUID(instanceIdentifier)
        encoder.appendUUID(estateIdentifier)
        encoder.appendString(binaryVersion)
        encoder.appendUInt64(UInt64(contractRevision))
        encoder.appendString(mcpProtocolVersion)
        encoder.appendCapabilities(capabilities)
        encoder.appendUInt64(credentialGeneration)
        encoder.appendUInt64(descriptorGeneration)
        return encoder.bytes
    }

    /// The canonical bytes of the FULL descriptor, MAC included.
    public func canonicalBytes() -> [UInt8] {
        var encoder = CanonicalEncoder()
        encoder.appendBytes(macInput())
        encoder.appendBytes(descriptorMAC)
        return encoder.bytes
    }

    /// `SHA-256(canonicalBytes())` — the digest that salts `K_auth` and that the
    /// client presents at the challenge step.
    ///
    /// It covers the MAC as well as the fields, so two descriptors differing
    /// only in their MAC have different digests and therefore different session
    /// keys. That is what stops a forged descriptor from riding a legitimate
    /// descriptor's handshake.
    public func digest() -> [UInt8] {
        FirstPartyAuthProtocol.sha256(canonicalBytes())
    }

    /// Recompute the MAC under `installationRoot` and compare it in constant
    /// time against the published one.
    ///
    /// - Returns: `true` only when the descriptor is authentic.
    public func verifyMAC(installationRoot: [UInt8]) -> Bool {
        guard descriptorMAC.count == FirstPartyAuthProtocol.macByteCount else { return false }
        let expected = FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: installationRoot),
            message: macInput()
        )
        return FirstPartyAuthProtocol.constantTimeEquals(expected, descriptorMAC)
    }
}

// MARK: - Replay window

/// The per-session replay guard: a highest-seen sequence plus a 128-bit history
/// of the sequences below it.
///
/// A strict "must be greater than the last" counter would be simpler, but it
/// cannot tolerate concurrent requests: two requests issued in order can arrive
/// out of order, and the later-arriving earlier sequence would be refused as a
/// replay. The window admits genuine out-of-order arrivals inside a bounded
/// history while still refusing duplicates and anything too old to judge.
///
/// Bit `i` means "the sequence `highestSeen - i` has been admitted", so bit 0 is
/// always `highestSeen` itself.
///
/// State is committed by the caller ONLY after the request MAC verifies —
/// admitting on an unverified sequence would let an unauthenticated peer burn a
/// legitimate client's sequence numbers.
public struct ReplayWindow: Sendable, Equatable {

    /// The largest sequence admitted so far. Zero before the first admission,
    /// which is safe because sequence 0 is not a legal sequence.
    public private(set) var highestSeen: UInt64 = 0

    /// History bitmap for the `replayWindowWidth` sequences at and below
    /// `highestSeen`.
    public private(set) var bitmap: UInt128 = 0

    /// True once the sequence space is exhausted. The session must be revoked:
    /// wrapping would restart the sequence at a value already inside the window
    /// and make every subsequent request look like a replay.
    public var isExhausted: Bool { highestSeen == UInt64.max }

    public init() {}

    /// Judge one sequence and, if it is admissible, record it.
    ///
    /// - Parameter sequence: The sequence from the request header.
    /// - Returns: `true` when the sequence is fresh and has been recorded;
    ///   `false` for sequence 0, a duplicate, or a sequence older than the
    ///   window can adjudicate.
    public mutating func admit(_ sequence: UInt64) -> Bool {
        // Sequences start at 1. Zero is never legal, so it is refused before it
        // can interact with the window at all.
        guard sequence != 0 else { return false }

        if sequence > highestSeen {
            let delta = sequence - highestSeen
            if delta >= FirstPartyAuthProtocol.replayWindowWidth {
                // The jump clears the window: every sequence still recorded is
                // now older than the window can represent. Shifting instead
                // would slide stale bits into positions that mean different
                // sequences.
                bitmap = 0
            } else {
                bitmap <<= UInt128(delta)
            }
            bitmap |= 1                       // bit 0 is the new highest
            highestSeen = sequence
            return true
        }

        // At or below the highest seen: admissible only if it is still inside
        // the window AND has not already been recorded.
        let delta = highestSeen - sequence
        guard delta < FirstPartyAuthProtocol.replayWindowWidth else { return false }
        let mask = UInt128(1) << UInt128(delta)
        guard bitmap & mask == 0 else { return false }
        bitmap |= mask
        return true
    }
}
