import Testing
import Foundation
import CryptoKit
@testable import AriaMCP

// MARK: - First-party authenticated wire — protocol core
//
// These tests pin the FROZEN half of the first-party contract: the canonical
// byte encoding, the HKDF domain separation, the transcript, the request and
// response MAC field coverage, and the replay window arithmetic. Everything
// here is language-neutral by construction — the same inputs and the same
// expected bytes are published in
// `docs/reference/vectors/ARIA_MCP_FIRST_PARTY_AUTH_V1.json` and independently
// recomputed by `packages/kits/AriaMcpKit/rust/tests/first_party_auth_vectors.rs`.
// A Swift/Rust byte disagreement fails the mission, so these assertions are
// written against explicit bytes rather than against "whatever the encoder
// produces".
//
// The suite deliberately contains no networking and no Keychain access. It
// tests the algebra; `FirstPartyAuthServerTests` and the HTTP suites test the
// lane.

@Suite("First-party auth protocol — canonical bytes and derivation")
struct FirstPartyAuthProtocolTests {

    // A fixed, non-secret 32-byte root used by every vector. Test-only: the
    // production root is minted by MACD-2c behind the provider lock and never
    // appears in source.
    static let fixedRoot: [UInt8] = (0..<32).map { UInt8($0) }

    static let instanceUUID = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
    static let estateUUID = UUID(uuidString: "0A5B9C3D-7E21-4F6A-8B4C-1D2E3F4A5B6C")!

    /// The descriptor every vector in this suite derives from.
    static func vectorDescriptor(mac: [UInt8] = []) -> FirstPartyDescriptor {
        FirstPartyDescriptor(
            schemaVersion: 2,
            providerIdentifier: "com.mootx01.mgr",
            serviceIdentifier: "com.mootx01.daemon",
            endpoint: "http://127.0.0.1:4242/mcp/first-party",
            authProtocol: "hmac-sha256-hkdf-v1",
            authKeyIdentifier: "installation-root-v1",
            publishedAt: 1_766_000_000,
            instanceIdentifier: instanceUUID,
            estateIdentifier: estateUUID,
            binaryVersion: "1.1.0",
            contractRevision: 2,
            mcpProtocolVersion: "2025-11-25",
            capabilities: ["authenticated-first-party", "resident-estate", "tool-surface"],
            credentialGeneration: 1,
            descriptorGeneration: 1,
            descriptorMAC: mac
        )
    }

    // MARK: Constants

    @Test("Protocol constants are exactly the contracted spellings")
    func constantsAreExact() {
        #expect(FirstPartyAuthProtocol.endpoint == "http://127.0.0.1:4242/mcp/first-party")
        #expect(FirstPartyAuthProtocol.requestPath == "/mcp/first-party")
        #expect(FirstPartyAuthProtocol.challengePath == "/mcp/first-party/session/challenge")
        #expect(FirstPartyAuthProtocol.establishPath == "/mcp/first-party/session/establish")
        #expect(FirstPartyAuthProtocol.authProtocolIdentifier == "hmac-sha256-hkdf-v1")
        #expect(FirstPartyAuthProtocol.authKeyIdentifier == "installation-root-v1")
        #expect(FirstPartyAuthProtocol.descriptorSchemaVersion == 2)
        #expect(FirstPartyAuthProtocol.contractRevision == 2)
        #expect(FirstPartyAuthProtocol.mcpProtocolVersion == "2025-11-25")
        #expect(FirstPartyAuthProtocol.contentType == "application/json")
        #expect(FirstPartyAuthProtocol.keychainService == "com.codedaptive.mootx01.daemon-auth")
        #expect(FirstPartyAuthProtocol.keychainAccount == "installation-root-v1")
        // Bounded state. These are security limits, not tuning knobs.
        #expect(FirstPartyAuthProtocol.maxChallenges == 128)
        #expect(FirstPartyAuthProtocol.maxSessions == 64)
        #expect(FirstPartyAuthProtocol.replayWindowWidth == 128)
        #expect(FirstPartyAuthProtocol.challengeLifetime == 30)
        #expect(FirstPartyAuthProtocol.sessionIdleTimeout == 900)
        #expect(FirstPartyAuthProtocol.sessionAbsoluteTimeout == 28_800)
    }

    // MARK: Canonical encoding

    @Test("Strings are UInt32 big-endian length followed by UTF-8")
    func canonicalStringShape() {
        var encoder = CanonicalEncoder()
        encoder.appendString("AB")
        #expect(encoder.bytes == [0x00, 0x00, 0x00, 0x02, 0x41, 0x42])
    }

    @Test("Integers are unsigned big-endian, never platform-native")
    func canonicalIntegerShape() {
        var encoder = CanonicalEncoder()
        encoder.appendUInt64(1)
        #expect(encoder.bytes == [0, 0, 0, 0, 0, 0, 0, 1])

        var status = CanonicalEncoder()
        status.appendUInt16(401)
        #expect(status.bytes == [0x01, 0x91])
    }

    @Test("UUIDs are their 16 RFC 4122 bytes, not their string form")
    func canonicalUUIDShape() {
        var encoder = CanonicalEncoder()
        encoder.appendUUID(Self.instanceUUID)
        #expect(encoder.bytes == [0x3F, 0x25, 0x04, 0xE0, 0x4F, 0x89, 0x11, 0xD3,
                                  0x9A, 0x0C, 0x03, 0x05, 0xE8, 0x2C, 0x33, 0x01])
    }

    @Test("Byte arrays carry a UInt32 length prefix")
    func canonicalBytesShape() {
        var encoder = CanonicalEncoder()
        encoder.appendBytes([0xAA, 0xBB])
        #expect(encoder.bytes == [0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB])
    }

    @Test("Capabilities are sorted by wire spelling, counted, then length-prefixed")
    func canonicalCapabilitiesAreOrderIndependent() {
        var forward = CanonicalEncoder()
        forward.appendCapabilities(["tool-surface", "authenticated-first-party"])
        var reverse = CanonicalEncoder()
        reverse.appendCapabilities(["authenticated-first-party", "tool-surface"])
        #expect(forward.bytes == reverse.bytes)
        // UInt32 count precedes the entries.
        #expect(Array(forward.bytes.prefix(4)) == [0x00, 0x00, 0x00, 0x02])
    }

    @Test("Length prefixing is unambiguous where delimiter concatenation is not")
    func canonicalEncodingIsUnambiguous() {
        // The classic delimiter failure: "a" + "bc" and "ab" + "c" collide when
        // fields are concatenated. Length prefixes must separate them.
        var first = CanonicalEncoder()
        first.appendString("a")
        first.appendString("bc")
        var second = CanonicalEncoder()
        second.appendString("ab")
        second.appendString("c")
        #expect(first.bytes != second.bytes)
    }

    // MARK: Descriptor MAC

    @Test("Descriptor key is HKDF-SHA256 with the omitted-salt value and descriptor domain")
    func descriptorKeyDerivation() {
        let derived = FirstPartyAuthProtocol.descriptorKey(installationRoot: Self.fixedRoot)
        // RFC 5869: an omitted salt is HashLen zero octets.
        let expected = FirstPartyAuthProtocol.hkdfSHA256(
            inputKeyingMaterial: Self.fixedRoot,
            salt: [UInt8](repeating: 0, count: 32),
            info: Array("MOOTX01-DESCRIPTOR-v1".utf8),
            outputByteCount: 32
        )
        #expect(derived == expected)
        #expect(derived.count == 32)
    }

    @Test("Descriptor MAC input excludes descriptorMAC and is domain-separated")
    func descriptorMACInputExcludesTheMAC() {
        let withoutMAC = Self.vectorDescriptor(mac: [])
        let withMAC = Self.vectorDescriptor(mac: [UInt8](repeating: 0xFF, count: 32))
        #expect(withoutMAC.macInput() == withMAC.macInput())
        // The domain prefix is present and is the first canonical field.
        var domain = CanonicalEncoder()
        domain.appendString("MOOTX01-DESCRIPTOR-v1")
        #expect(withoutMAC.macInput().starts(with: domain.bytes))
    }

    @Test("A one-bit mutation in any descriptor field changes the MAC")
    func descriptorMACDetectsMutation() {
        let key = FirstPartyAuthProtocol.descriptorKey(installationRoot: Self.fixedRoot)
        let base = Self.vectorDescriptor()
        let baseMAC = FirstPartyAuthProtocol.hmacSHA256(key: key, message: base.macInput())

        var mutated = base
        mutated.credentialGeneration = 2
        #expect(FirstPartyAuthProtocol.hmacSHA256(key: key, message: mutated.macInput()) != baseMAC)

        var reendpointed = base
        reendpointed.endpoint = "http://127.0.0.1:4243/mcp/first-party"
        #expect(FirstPartyAuthProtocol.hmacSHA256(key: key, message: reendpointed.macInput()) != baseMAC)
    }

    @Test("Descriptor digest covers the full descriptor including its MAC")
    func descriptorDigestIncludesTheMAC() {
        let signed = Self.vectorDescriptor(mac: [UInt8](repeating: 0x11, count: 32))
        let forged = Self.vectorDescriptor(mac: [UInt8](repeating: 0x22, count: 32))
        #expect(signed.digest() != forged.digest())
        #expect(signed.digest().count == 32)
    }

    // MARK: Transcript and mutual proofs

    @Test("Server and client proofs are distinct over an identical transcript")
    func proofsAreDomainSeparated() {
        let transcript = Self.sampleTranscript()
        let authKey = FirstPartyAuthProtocol.authKey(
            installationRoot: Self.fixedRoot,
            descriptorDigest: Self.vectorDescriptor(mac: [UInt8](repeating: 0x11, count: 32)).digest()
        )
        let server = FirstPartyAuthProtocol.serverProof(authKey: authKey, transcript: transcript)
        let client = FirstPartyAuthProtocol.clientProof(authKey: authKey, transcript: transcript)
        // Reflection defence: a peer that echoes the server's proof back as a
        // client proof must not authenticate.
        #expect(server != client)
        #expect(server.count == 32)
        #expect(client.count == 32)
    }

    @Test("Session key is derived from SHA-256 of the transcript, not the transcript")
    func sessionKeyDerivation() {
        let transcript = Self.sampleTranscript()
        let sessionKey = FirstPartyAuthProtocol.sessionKey(
            installationRoot: Self.fixedRoot, transcript: transcript
        )
        let expected = FirstPartyAuthProtocol.hkdfSHA256(
            inputKeyingMaterial: Self.fixedRoot,
            salt: Array(SHA256.hash(data: Data(transcript))),
            info: Array("MOOTX01-REQUEST-SESSION-v1".utf8),
            outputByteCount: 32
        )
        #expect(sessionKey == expected)
        // The session key must not equal the auth key: a single compromised
        // derivation must not yield both.
        let authKey = FirstPartyAuthProtocol.authKey(
            installationRoot: Self.fixedRoot,
            descriptorDigest: Self.vectorDescriptor(mac: [UInt8](repeating: 0x11, count: 32)).digest()
        )
        #expect(sessionKey != authKey)
    }

    @Test("Establishment proof is taken under the session key, not the auth key")
    func establishmentProofUsesSessionKey() {
        let transcript = Self.sampleTranscript()
        let sessionKey = FirstPartyAuthProtocol.sessionKey(
            installationRoot: Self.fixedRoot, transcript: transcript
        )
        let proof = FirstPartyAuthProtocol.establishmentProof(
            sessionKey: sessionKey, transcript: transcript
        )
        let authKey = FirstPartyAuthProtocol.authKey(
            installationRoot: Self.fixedRoot,
            descriptorDigest: Self.vectorDescriptor(mac: [UInt8](repeating: 0x11, count: 32)).digest()
        )
        #expect(proof != FirstPartyAuthProtocol.establishmentProof(sessionKey: authKey, transcript: transcript))
    }

    // MARK: Request and response MACs

    @Test("Request MAC covers method, path, content type, and body — not just the body")
    func requestMACFieldCoverage() {
        let key = [UInt8](repeating: 0x5A, count: 32)
        let session = [UInt8](repeating: 0x07, count: 16)
        let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

        let base = FirstPartyAuthProtocol.requestMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: body
        )
        // Each covered field, mutated one at a time, must change the MAC.
        #expect(base != FirstPartyAuthProtocol.requestMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 2,
            method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: body))
        #expect(base != FirstPartyAuthProtocol.requestMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            method: "PUT", path: "/mcp/first-party",
            contentType: "application/json", body: body))
        #expect(base != FirstPartyAuthProtocol.requestMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            method: "POST", path: "/mcp/first-party/session/challenge",
            contentType: "application/json", body: body))
        #expect(base != FirstPartyAuthProtocol.requestMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            method: "POST", path: "/mcp/first-party",
            contentType: "text/plain", body: body))
        #expect(base != FirstPartyAuthProtocol.requestMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8)))
        #expect(base != FirstPartyAuthProtocol.requestMAC(
            sessionKey: key, sessionIdentifier: [UInt8](repeating: 0x08, count: 16), sequence: 1,
            method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: body))
    }

    @Test("Response MAC covers status, content type, sequence, and body")
    func responseMACFieldCoverage() {
        let key = [UInt8](repeating: 0x5A, count: 32)
        let session = [UInt8](repeating: 0x07, count: 16)
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)

        let base = FirstPartyAuthProtocol.responseMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            status: 200, contentType: "application/json", body: body
        )
        #expect(base != FirstPartyAuthProtocol.responseMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            status: 401, contentType: "application/json", body: body))
        #expect(base != FirstPartyAuthProtocol.responseMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 2,
            status: 200, contentType: "application/json", body: body))
        #expect(base != FirstPartyAuthProtocol.responseMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            status: 200, contentType: "", body: body))
        #expect(base != FirstPartyAuthProtocol.responseMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            status: 200, contentType: "application/json", body: Data()))
    }

    @Test("Request and response MACs over identical material are distinct")
    func requestAndResponseAreDomainSeparated() {
        let key = [UInt8](repeating: 0x5A, count: 32)
        let session = [UInt8](repeating: 0x07, count: 16)
        let request = FirstPartyAuthProtocol.requestMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            method: "POST", path: "/mcp/first-party",
            contentType: "application/json", body: Data()
        )
        let response = FirstPartyAuthProtocol.responseMAC(
            sessionKey: key, sessionIdentifier: session, sequence: 1,
            status: 200, contentType: "application/json", body: Data()
        )
        #expect(request != response)
    }

    // MARK: Replay window

    @Test("Sequence 0 is rejected outright")
    func sequenceZeroRejected() {
        var window = ReplayWindow()
        #expect(window.admit(0) == false)
    }

    @Test("In-order sequences are admitted exactly once")
    func inOrderAdmission() {
        var window = ReplayWindow()
        #expect(window.admit(1))
        #expect(window.admit(2))
        #expect(window.admit(3))
        // Replays of each are refused.
        #expect(window.admit(1) == false)
        #expect(window.admit(2) == false)
        #expect(window.admit(3) == false)
    }

    @Test("Out-of-order arrivals inside the window are admitted, then refused")
    func outOfOrderAdmission() {
        var window = ReplayWindow()
        #expect(window.admit(5))
        #expect(window.admit(3))   // late but inside the window
        #expect(window.admit(4))
        #expect(window.admit(3) == false)  // duplicate of a late arrival
        #expect(window.admit(5) == false)
    }

    @Test("The window is exactly 128 wide at both edges")
    func windowEdges() {
        var window = ReplayWindow()
        #expect(window.admit(200))
        // delta 127 is the oldest still representable.
        #expect(window.admit(200 - 127))
        // delta 128 has fallen out of the window and must be refused.
        #expect(window.admit(200 - 128) == false)
        #expect(window.admit(1) == false)
    }

    @Test("A jump of 128 or more clears the window rather than shifting stale bits in")
    func largeJumpClearsWindow() {
        var window = ReplayWindow()
        #expect(window.admit(1))
        #expect(window.admit(1_000))
        // Everything below the new window is gone, including the admitted 1.
        #expect(window.admit(1) == false)
        #expect(window.admit(999))
        #expect(window.admit(1_000) == false)
    }

    @Test("Sequence overflow is refused rather than wrapping")
    func overflowRefused() {
        var window = ReplayWindow()
        #expect(window.admit(UInt64.max))
        #expect(window.isExhausted)
    }

    // MARK: Encodings

    @Test("Base64url is unpadded and uses the URL alphabet")
    func base64urlShape() {
        let bytes: [UInt8] = [0xFB, 0xEF, 0xBE]
        let encoded = FirstPartyAuthProtocol.base64URLEncode(bytes)
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(FirstPartyAuthProtocol.base64URLDecode(encoded) == bytes)
    }

    @Test("Base64url decoding refuses padded and non-alphabet input")
    func base64urlRejectsMalformed() {
        #expect(FirstPartyAuthProtocol.base64URLDecode("QUJD=") == nil)
        #expect(FirstPartyAuthProtocol.base64URLDecode("QU+D") == nil)
        #expect(FirstPartyAuthProtocol.base64URLDecode("QU/D") == nil)
        #expect(FirstPartyAuthProtocol.base64URLDecode(" QUJD") == nil)
    }

    @Test("The sequence header is canonical unsigned decimal only")
    func sequenceHeaderIsCanonical() {
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("1") == 1)
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("18446744073709551615") == UInt64.max)
        // Every non-canonical spelling is refused rather than normalized.
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("0") == nil)
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("01") == nil)
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("+1") == nil)
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("-1") == nil)
        #expect(FirstPartyAuthProtocol.parseSequenceHeader(" 1") == nil)
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("1 ") == nil)
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("") == nil)
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("1.0") == nil)
        // Overflow of UInt64 is refused, not truncated.
        #expect(FirstPartyAuthProtocol.parseSequenceHeader("18446744073709551616") == nil)
    }

    // MARK: Constant-time comparison

    @Test("Constant-time comparison is correct on equal and unequal lengths and bytes")
    func constantTimeComparison() {
        #expect(FirstPartyAuthProtocol.constantTimeEquals([1, 2, 3], [1, 2, 3]))
        #expect(!FirstPartyAuthProtocol.constantTimeEquals([1, 2, 3], [1, 2, 4]))
        #expect(!FirstPartyAuthProtocol.constantTimeEquals([1, 2, 3], [1, 2]))
        #expect(!FirstPartyAuthProtocol.constantTimeEquals([], [1]))
        #expect(FirstPartyAuthProtocol.constantTimeEquals([], []))
        // A difference in the first byte and a difference in the last must both
        // be detected — a short-circuiting comparison would pass one and leak
        // position through timing.
        let a = [UInt8](repeating: 0, count: 32)
        var firstDiffers = a; firstDiffers[0] = 1
        var lastDiffers = a; lastDiffers[31] = 1
        #expect(!FirstPartyAuthProtocol.constantTimeEquals(a, firstDiffers))
        #expect(!FirstPartyAuthProtocol.constantTimeEquals(a, lastDiffers))
    }

    // MARK: Helpers

    /// A transcript built from the vector descriptor and fixed nonces.
    static func sampleTranscript() -> [UInt8] {
        let descriptor = vectorDescriptor(mac: [UInt8](repeating: 0x11, count: 32))
        return FirstPartyAuthProtocol.sessionTranscript(
            descriptorDigest: descriptor.digest(),
            providerIdentifier: descriptor.providerIdentifier,
            serviceIdentifier: descriptor.serviceIdentifier,
            endpoint: descriptor.endpoint,
            instanceIdentifier: descriptor.instanceIdentifier,
            estateIdentifier: descriptor.estateIdentifier,
            binaryVersion: descriptor.binaryVersion,
            descriptorSchemaVersion: descriptor.schemaVersion,
            contractRevision: descriptor.contractRevision,
            mcpProtocolVersion: descriptor.mcpProtocolVersion,
            credentialGeneration: descriptor.credentialGeneration,
            descriptorGeneration: descriptor.descriptorGeneration,
            clientNonce: [UInt8](repeating: 0xC1, count: 32),
            serverNonce: [UInt8](repeating: 0x53, count: 32),
            sessionIdentifier: [UInt8](repeating: 0x07, count: 16),
            issuedAt: 1_766_000_100,
            idleExpiry: 1_766_000_100 + 900,
            absoluteExpiry: 1_766_000_100 + 28_800
        )
    }
}
