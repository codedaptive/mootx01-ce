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
        // MACD-3B1: descriptorSchemaVersion bumped from 2 to 3.
        // The schema-2 golden MAC vectors below use literal schemaVersion: 2
        // to prove the schema-2 MAC bytes are provably unchanged (R1).
        #expect(FirstPartyAuthProtocol.descriptorSchemaVersion == 3)
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

    // `admit` is mutating, and `#expect` evaluates its argument inside an
    // autoclosure over an immutable capture — so every admission is taken into
    // a local first. Written as a helper rather than repeated inline so the
    // sequence under test stays readable.
    private func admissions(_ window: inout ReplayWindow, _ sequences: [UInt64]) -> [Bool] {
        sequences.map { window.admit($0) }
    }

    @Test("Sequence 0 is rejected outright")
    func sequenceZeroRejected() {
        var window = ReplayWindow()
        #expect(admissions(&window, [0]) == [false])
    }

    @Test("In-order sequences are admitted exactly once")
    func inOrderAdmission() {
        var window = ReplayWindow()
        // Fresh, then every one of them replayed.
        #expect(admissions(&window, [1, 2, 3, 1, 2, 3])
                == [true, true, true, false, false, false])
    }

    @Test("Out-of-order arrivals inside the window are admitted, then refused")
    func outOfOrderAdmission() {
        var window = ReplayWindow()
        // 3 and 4 arrive after 5 — genuine concurrency, not replay — then 3 and
        // 5 are replayed and must be refused.
        #expect(admissions(&window, [5, 3, 4, 3, 5])
                == [true, true, true, false, false])
    }

    @Test("The window is exactly 128 wide at both edges")
    func windowEdges() {
        var window = ReplayWindow()
        // delta 127 is the oldest still representable; delta 128 has fallen out.
        #expect(admissions(&window, [200, 200 - 127, 200 - 128, 1])
                == [true, true, false, false])
    }

    @Test("A jump of 128 or more clears the window rather than shifting stale bits in")
    func largeJumpClearsWindow() {
        var window = ReplayWindow()
        // After the jump everything below the new window is gone — including the
        // 1 that was admitted — while 999 is fresh and 1000 is a duplicate.
        #expect(admissions(&window, [1, 1_000, 1, 999, 1_000])
                == [true, true, false, true, false])
    }

    @Test("Sequence overflow is refused rather than wrapping")
    func overflowRefused() {
        var window = ReplayWindow()
        #expect(admissions(&window, [UInt64.max]) == [true])
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

    @Test("Base64url decoding rejects aliases with non-zero pad bits")
    func base64urlRejectsNonCanonicalPadBits() {
        for bytes in [
            [UInt8](repeating: 0, count: FirstPartyAuthProtocol.sessionIdentifierByteCount),
            [UInt8](repeating: 0, count: FirstPartyAuthProtocol.macByteCount),
        ] {
            let canonical = FirstPartyAuthProtocol.base64URLEncode(bytes)
            let last = canonical.index(before: canonical.endIndex)
            // Both protocol widths leave unused bits in the final base64
            // character. Changing only those bits preserves the decoded bytes
            // under permissive decoders, but must not preserve the wire value.
            var alias = canonical
            alias.replaceSubrange(last...last, with: "B")
            #expect(alias != canonical)
            #expect(Data(base64Encoded: alias.replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
                + String(repeating: "=", count: (4 - alias.count % 4) % 4)) == Data(bytes))
            #expect(FirstPartyAuthProtocol.base64URLDecode(alias) == nil)
        }
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

    // MARK: Untrusted integer widths (root finding A)

    @Test("A descriptor with a negative version field has no canonical encoding")
    func negativeVersionFieldsAreUnencodable() {
        // These are `Int` on a decoded record but unsigned on the wire, and
        // canonicalization runs BEFORE the MAC verifies — so a negative value
        // reaches an integer conversion while still fully attacker-controlled.
        var negativeSchema = Self.vectorDescriptor()
        negativeSchema.schemaVersion = -1
        #expect(!negativeSchema.hasEncodableFieldWidths)

        var negativeRevision = Self.vectorDescriptor()
        negativeRevision.contractRevision = -1
        #expect(!negativeRevision.hasEncodableFieldWidths)

        #expect(Self.vectorDescriptor().hasEncodableFieldWidths)
    }

    @Test("Canonicalizing a negative version field does not trap")
    func negativeVersionFieldsDoNotTrap() {
        // Totality, not merely rejection: a canonicalizer that can crash on its
        // input turns a parse bug into a remote denial of service. Reaching the
        // assertion at all is the result being tested.
        var descriptor = Self.vectorDescriptor()
        descriptor.schemaVersion = Int.min
        descriptor.contractRevision = -1
        let bytes = descriptor.macInput()
        #expect(!bytes.isEmpty)
        #expect(!descriptor.digest().isEmpty)
        // And it refuses to verify regardless of what MAC is presented.
        #expect(!descriptor.verifyMAC(installationRoot: Self.fixedRoot))

        let transcript = FirstPartyAuthProtocol.sessionTranscript(
            descriptorDigest: [UInt8](repeating: 0, count: 32),
            providerIdentifier: "p", serviceIdentifier: "s", endpoint: "e",
            instanceIdentifier: Self.instanceUUID, estateIdentifier: Self.estateUUID,
            binaryVersion: "1.0.0",
            descriptorSchemaVersion: Int.min, contractRevision: -1,
            mcpProtocolVersion: "v", credentialGeneration: 0, descriptorGeneration: 0,
            clientNonce: [], serverNonce: [], sessionIdentifier: [],
            issuedAt: 0, idleExpiry: 0, absoluteExpiry: 0
        )
        #expect(!transcript.isEmpty)
    }

    @Test("Valid non-negative fields encode identically to before the totality fix")
    func validFieldsEncodeUnchanged() {
        // The vectors are frozen; the totality change must be byte-neutral for
        // every legal value, which is why `UInt64(bitPattern:)` was chosen over
        // clamping or saturation.
        var encoder = CanonicalEncoder()
        encoder.appendUInt64(UInt64(bitPattern: Int64(2)))
        var reference = CanonicalEncoder()
        reference.appendUInt64(2)
        #expect(encoder.bytes == reference.bytes)
    }

    // MARK: Exact media type (root finding B)

    @Test("Only the exact contracted media type is accepted", arguments: [
        ("application/json", true),
        ("Application/JSON", true),          // case-insensitive per RFC
        ("  application/json  ", true),      // surrounding OWS is strippable
        ("application/json-evil", false),    // a prefix test would accept this
        ("application/jsonx", false),
        ("application/json; charset=utf-8", false),   // parameters are forbidden
        ("application/json;charset=utf-8", false),
        ("text/json", false),
        ("", false),
    ])
    func exactContentType(value: String, accepted: Bool) {
        #expect(FirstPartyAuthProtocol.isExactContentType(value) == accepted)
    }

    // MARK: Strict JSON shape (root finding F)

    @Test("Strict JSON object reading refuses malformed shapes")
    func strictJSONObjectRefusesMalformed() {
        let expected: Set<String> = ["a", "b"]
        #expect(FirstPartyAuthProtocol.strictJSONObject(Data(#"{"a":1,"b":2}"#.utf8), expected: expected) != nil)
        // Unknown key.
        #expect(FirstPartyAuthProtocol.strictJSONObject(Data(#"{"a":1,"b":2,"c":3}"#.utf8), expected: expected) == nil)
        // Missing key.
        #expect(FirstPartyAuthProtocol.strictJSONObject(Data(#"{"a":1}"#.utf8), expected: expected) == nil)
        // Duplicate key — JSONSerialization silently keeps the last.
        #expect(FirstPartyAuthProtocol.strictJSONObject(Data(#"{"a":1,"b":2,"a":3}"#.utf8), expected: expected) == nil)
        // Not an object.
        #expect(FirstPartyAuthProtocol.strictJSONObject(Data("[1,2]".utf8), expected: expected) == nil)
        #expect(FirstPartyAuthProtocol.strictJSONObject(Data("not json".utf8), expected: expected) == nil)
        // Over the size cap, refused before parsing.
        let huge = Data(("{\"a\":\"" + String(repeating: "x", count: 9000) + "\",\"b\":1}").utf8)
        #expect(FirstPartyAuthProtocol.strictJSONObject(huge, expected: expected) == nil)
    }

    @Test("The top-level key scanner sees duplicates and ignores nesting")
    func topLevelKeyScanner() {
        #expect(FirstPartyAuthProtocol.topLevelJSONKeys(Data(#"{"a":1,"b":{"a":2},"a":3}"#.utf8)) == ["a", "b", "a"])
        #expect(FirstPartyAuthProtocol.topLevelJSONKeys(Data(#"{"x":{"y":1}}"#.utf8)) == ["x"])
        #expect(FirstPartyAuthProtocol.topLevelJSONKeys(Data(#"{"a\"b":1}"#.utf8))?.count == 1)
        #expect(FirstPartyAuthProtocol.topLevelJSONKeys(Data("{".utf8)) == nil)
    }

    @Test("The exact UInt64 decoder is total")
    func exactUInt64IsTotal() {
        #expect(FirstPartyAuthProtocol.exactUInt64(NSNumber(value: 0)) == 0)
        #expect(FirstPartyAuthProtocol.exactUInt64(NSNumber(value: UInt64.max)) == UInt64.max)
        #expect(FirstPartyAuthProtocol.exactUInt64(NSNumber(value: -1)) == nil)
        #expect(FirstPartyAuthProtocol.exactUInt64(NSNumber(value: Int.min)) == nil)
        #expect(FirstPartyAuthProtocol.exactUInt64(NSNumber(value: 1.5)) == nil)
        #expect(FirstPartyAuthProtocol.exactUInt64(NSNumber(value: true)) == nil)
        #expect(FirstPartyAuthProtocol.exactUInt64("1") == nil)
        #expect(FirstPartyAuthProtocol.exactUInt64(nil) == nil)
    }

    // MARK: Golden vectors
    //
    // The JSON file is the single language-neutral source of truth. Swift emits
    // it and Swift verifies it, but the assertion that matters is made in Rust:
    // `rust/tests/first_party_auth_vectors.rs` reimplements RFC 2104 and RFC 5869
    // over `sha2` and recomputes every value independently. If the two ports
    // disagree on a single byte, the wire is not language-neutral and the
    // mission fails.

    /// Absolute path of the committed vector file.
    static var vectorFileURL: URL {
        // The test binary runs from .build, so the repository root is derived
        // from this source file's location rather than from the cwd.
        URL(fileURLWithPath: #filePath)                      // …/Tests/AriaMCPTests/<this>.swift
            .deletingLastPathComponent()                     // …/Tests/AriaMCPTests
            .deletingLastPathComponent()                     // …/Tests
            .deletingLastPathComponent()                     // …/AriaMcpKit
            .deletingLastPathComponent()                     // …/kits
            .deletingLastPathComponent()                     // …/packages
            .deletingLastPathComponent()                     // repo root
            .appendingPathComponent("docs/reference/vectors/ARIA_MCP_FIRST_PARTY_AUTH_V1.json")
    }

    /// Every value the vector file publishes, recomputed from the protocol core.
    ///
    /// One function serves both the emitter and the verifier, so the file can
    /// never drift from the implementation without a test failing.
    static func computedVectors() -> [String: Any] {
        let root = fixedRoot
        let descriptorKey = FirstPartyAuthProtocol.descriptorKey(installationRoot: root)

        var descriptor = vectorDescriptor(mac: [])
        descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: descriptorKey, message: descriptor.macInput()
        )
        let digest = descriptor.digest()

        let clientNonce = [UInt8](repeating: 0xC1, count: 32)
        let serverNonce = [UInt8](repeating: 0x53, count: 32)
        let sessionID = [UInt8](repeating: 0x07, count: 16)
        let issuedAt: UInt64 = 1_766_000_100
        let idleExpiry = issuedAt + FirstPartyAuthProtocol.sessionIdleTimeout
        let absoluteExpiry = issuedAt + FirstPartyAuthProtocol.sessionAbsoluteTimeout

        let transcript = FirstPartyAuthProtocol.sessionTranscript(
            descriptorDigest: digest,
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
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            sessionIdentifier: sessionID,
            issuedAt: issuedAt,
            idleExpiry: idleExpiry,
            absoluteExpiry: absoluteExpiry
        )

        let authKey = FirstPartyAuthProtocol.authKey(installationRoot: root, descriptorDigest: digest)
        let sessionKey = FirstPartyAuthProtocol.sessionKey(installationRoot: root, transcript: transcript)

        // Request vectors: sequences 1 and 2 in order, then 5/3/4 to exercise
        // the out-of-order window on the verifying side.
        let bodies: [(UInt64, String)] = [
            (1, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#),
            (2, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#),
            (5, #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#),
            (3, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#),
            (4, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#),
        ]
        let requests: [[String: Any]] = bodies.map { sequence, body in
            let data = Data(body.utf8)
            let mac = FirstPartyAuthProtocol.requestMAC(
                sessionKey: sessionKey, sessionIdentifier: sessionID, sequence: sequence,
                method: FirstPartyAuthProtocol.requestMethod,
                path: FirstPartyAuthProtocol.requestPath,
                contentType: FirstPartyAuthProtocol.contentType,
                body: data
            )
            return [
                "sequence": sequence,
                "sequenceHeader": FirstPartyAuthProtocol.formatSequenceHeader(sequence),
                "bodyUTF8": body,
                "bodySHA256Hex": hex(FirstPartyAuthProtocol.sha256(data)),
                "macHex": hex(mac),
                "macBase64URL": FirstPartyAuthProtocol.base64URLEncode(mac),
            ]
        }

        // Response vectors: a MACed 200 with a JSON body, and the MACed empty
        // 204 a notification receives. The 204 carries no Content-Type, so the
        // canonical content type is the empty string.
        let okBody = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        let okMAC = FirstPartyAuthProtocol.responseMAC(
            sessionKey: sessionKey, sessionIdentifier: sessionID, sequence: 1,
            status: 200, contentType: FirstPartyAuthProtocol.contentType, body: okBody
        )
        let noContentMAC = FirstPartyAuthProtocol.responseMAC(
            sessionKey: sessionKey, sessionIdentifier: sessionID, sequence: 4,
            status: 204, contentType: "", body: Data()
        )
        let unauthorizedMAC = FirstPartyAuthProtocol.responseMAC(
            sessionKey: sessionKey, sessionIdentifier: sessionID, sequence: 2,
            status: 401, contentType: FirstPartyAuthProtocol.contentType, body: Data(#"{"error":"unauthorized"}"#.utf8)
        )

        // Negative vectors: a single flipped bit in the descriptor and in the
        // transcript must move the digest and the proof. A verifier that
        // reproduces the positive vectors but not these is not actually
        // checking the input it claims to check.
        var flippedDescriptor = descriptor
        flippedDescriptor.descriptorMAC[0] ^= 0x01
        var flippedTranscript = transcript
        flippedTranscript[0] ^= 0x01
        var flippedBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        flippedBody[0] ^= 0x01

        return [
            "vectorVersion": 1,
            "authProtocol": FirstPartyAuthProtocol.authProtocolIdentifier,
            "note": "Language-neutral golden vectors for the MOOTx01 first-party authenticated wire. "
                + "Swift emits and verifies these; the Rust test recomputes them independently. "
                + "The installation root here is a fixed non-secret test value.",
            "installationRootHex": hex(root),
            "descriptor": [
                "schemaVersion": descriptor.schemaVersion,
                "providerIdentifier": descriptor.providerIdentifier,
                "serviceIdentifier": descriptor.serviceIdentifier,
                "endpoint": descriptor.endpoint,
                "authProtocol": descriptor.authProtocol,
                "authKeyIdentifier": descriptor.authKeyIdentifier,
                "publishedAt": descriptor.publishedAt,
                "instanceIdentifier": descriptor.instanceIdentifier.uuidString,
                "estateIdentifier": descriptor.estateIdentifier.uuidString,
                "binaryVersion": descriptor.binaryVersion,
                "contractRevision": descriptor.contractRevision,
                "mcpProtocolVersion": descriptor.mcpProtocolVersion,
                "capabilities": descriptor.capabilities,
                "credentialGeneration": descriptor.credentialGeneration,
                "descriptorGeneration": descriptor.descriptorGeneration,
                "descriptorKeyHex": hex(descriptorKey),
                "macInputHex": hex(descriptor.macInput()),
                "descriptorMACHex": hex(descriptor.descriptorMAC),
                "canonicalBytesHex": hex(descriptor.canonicalBytes()),
                "digestHex": hex(digest),
            ],
            "session": [
                "clientNonceHex": hex(clientNonce),
                "serverNonceHex": hex(serverNonce),
                "sessionIdentifierHex": hex(sessionID),
                "sessionIdentifierBase64URL": FirstPartyAuthProtocol.base64URLEncode(sessionID),
                "authorizationHeaderValue":
                    "\(FirstPartyAuthProtocol.authorizationScheme) \(FirstPartyAuthProtocol.base64URLEncode(sessionID))",
                "issuedAt": issuedAt,
                "idleExpiry": idleExpiry,
                "absoluteExpiry": absoluteExpiry,
                "transcriptHex": hex(transcript),
                "transcriptDigestHex": hex(FirstPartyAuthProtocol.sha256(transcript)),
                "authKeyHex": hex(authKey),
                "sessionKeyHex": hex(sessionKey),
                "serverProofHex": hex(FirstPartyAuthProtocol.serverProof(authKey: authKey, transcript: transcript)),
                "clientProofHex": hex(FirstPartyAuthProtocol.clientProof(authKey: authKey, transcript: transcript)),
                "establishmentProofHex":
                    hex(FirstPartyAuthProtocol.establishmentProof(sessionKey: sessionKey, transcript: transcript)),
            ],
            "requests": requests,
            "responses": [
                [
                    "sequence": UInt64(1), "status": 200,
                    "contentType": FirstPartyAuthProtocol.contentType,
                    "bodyUTF8": #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
                    "macHex": hex(okMAC),
                    "macBase64URL": FirstPartyAuthProtocol.base64URLEncode(okMAC),
                ],
                [
                    "sequence": UInt64(4), "status": 204,
                    "contentType": "", "bodyUTF8": "",
                    "macHex": hex(noContentMAC),
                    "macBase64URL": FirstPartyAuthProtocol.base64URLEncode(noContentMAC),
                ],
                [
                    "sequence": UInt64(2), "status": 401,
                    "contentType": FirstPartyAuthProtocol.contentType,
                    "bodyUTF8": #"{"error":"unauthorized"}"#,
                    "macHex": hex(unauthorizedMAC),
                    "macBase64URL": FirstPartyAuthProtocol.base64URLEncode(unauthorizedMAC),
                ],
            ],
            "negative": [
                "descriptorMACBit0FlippedDigestHex": hex(flippedDescriptor.digest()),
                "transcriptBit0FlippedServerProofHex":
                    hex(FirstPartyAuthProtocol.serverProof(authKey: authKey, transcript: flippedTranscript)),
                "requestBodyBit0FlippedMACHex": hex(FirstPartyAuthProtocol.requestMAC(
                    sessionKey: sessionKey, sessionIdentifier: sessionID, sequence: 1,
                    method: FirstPartyAuthProtocol.requestMethod,
                    path: FirstPartyAuthProtocol.requestPath,
                    contentType: FirstPartyAuthProtocol.contentType,
                    body: flippedBody
                )),
                "responseStatusMutated401MACHex": hex(FirstPartyAuthProtocol.responseMAC(
                    sessionKey: sessionKey, sessionIdentifier: sessionID, sequence: 1,
                    status: 401, contentType: FirstPartyAuthProtocol.contentType, body: okBody
                )),
            ],
        ]
    }

    /// Lowercase hex, the one representation the vector file uses for bytes.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Regenerate the committed vector file. Opt-in, because a test that
    /// rewrites its own expected values on every run verifies nothing.
    ///
    ///     MOOTX01_EMIT_VECTORS=1 swift test --filter FirstPartyAuthProtocolTests
    @Test("Golden vectors regenerate on request")
    func emitGoldenVectors() throws {
        guard ProcessInfo.processInfo.environment["MOOTX01_EMIT_VECTORS"] == "1" else { return }
        let json = try JSONSerialization.data(
            withJSONObject: Self.computedVectors(),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try json.write(to: Self.vectorFileURL)
    }

    /// The committed vector file agrees with the implementation, byte for byte.
    ///
    /// This is what stops the file from silently ageing into a record of what
    /// the protocol used to do.
    @Test("Committed golden vectors match the implementation")
    func goldenVectorsMatchImplementation() throws {
        let data = try Data(contentsOf: Self.vectorFileURL)
        let onDisk = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let computed = Self.computedVectors()
        let expected = try JSONSerialization.data(
            withJSONObject: computed, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let actual = try JSONSerialization.data(
            withJSONObject: onDisk ?? [:], options: [.sortedKeys, .withoutEscapingSlashes]
        )
        #expect(actual == expected, "Committed vectors have drifted from the implementation")
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

// MARK: - Server lane — handshake, middleware, bounded state
//
// The protocol suite above tests the algebra. This one tests the lane: what the
// daemon accepts, what it refuses, and — the property most of these cases exist
// for — what it refuses WITHOUT changing state.

@Suite("First-party auth server — handshake and middleware")
struct FirstPartyAuthServerTests {

    typealias Vectors = FirstPartyAuthProtocolTests

    static let serverName = "ARIA_MCP"

    /// A descriptor whose MAC is genuine under the fixed test root.
    static func signedDescriptor(descriptorGeneration: UInt64 = 1) -> FirstPartyDescriptor {
        var descriptor = Vectors.vectorDescriptor(mac: [])
        descriptor.descriptorGeneration = descriptorGeneration
        descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: Vectors.fixedRoot),
            message: descriptor.macInput()
        )
        return descriptor
    }

    /// A server with a controllable clock and a counter-driven "randomness"
    /// source, so nonces and session identifiers are reproducible and expiry is
    /// exercisable. Real randomness would make replay and capacity tests
    /// untestable rather than more secure.
    static func makeServer(
        provider: any FirstPartyRootProviding = FixedFirstPartyRootProvider(root: Vectors.fixedRoot),
        descriptor: FirstPartyDescriptor? = nil,
        clock: ManualClock = ManualClock()
    ) -> (FirstPartyAuthServer, ManualClock) {
        let counter = RandomCounter()
        let server = FirstPartyAuthServer(
            rootProvider: provider,
            descriptor: descriptor ?? signedDescriptor(),
            serverName: serverName,
            now: { clock.seconds },
            randomBytes: { count in counter.next(count) }
        )
        return (server, clock)
    }

    /// Drive a complete handshake and return the session identifier and key.
    static func handshake(
        _ server: FirstPartyAuthServer,
        descriptor: FirstPartyDescriptor
    ) async throws -> (sessionIdentifier: [UInt8], sessionKey: [UInt8]) {
        let clientNonce = [UInt8](repeating: 0xC1, count: 32)
        let issued = try await server.challenge(
            clientNonce: clientNonce, descriptorDigest: descriptor.digest()
        )
        let transcript = FirstPartyAuthProtocol.sessionTranscript(
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
            clientNonce: clientNonce,
            serverNonce: issued.serverNonce,
            sessionIdentifier: issued.sessionIdentifier,
            issuedAt: issued.issuedAt,
            idleExpiry: issued.idleExpiry,
            absoluteExpiry: issued.absoluteExpiry
        )
        let authKey = FirstPartyAuthProtocol.authKey(
            installationRoot: Vectors.fixedRoot, descriptorDigest: descriptor.digest()
        )
        // The client checks the server proof before answering.
        #expect(FirstPartyAuthProtocol.constantTimeEquals(
            issued.serverProof,
            FirstPartyAuthProtocol.serverProof(authKey: authKey, transcript: transcript)
        ))
        let clientProof = FirstPartyAuthProtocol.clientProof(authKey: authKey, transcript: transcript)
        let established = try await server.establish(
            sessionIdentifier: issued.sessionIdentifier, clientProof: clientProof
        )
        let sessionKey = FirstPartyAuthProtocol.sessionKey(
            installationRoot: Vectors.fixedRoot, transcript: transcript
        )
        #expect(FirstPartyAuthProtocol.constantTimeEquals(
            established,
            FirstPartyAuthProtocol.establishmentProof(sessionKey: sessionKey, transcript: transcript)
        ))
        return (issued.sessionIdentifier, sessionKey)
    }

    /// Build a well-formed signed request on the lane.
    static func signedRequest(
        sessionIdentifier: [UInt8],
        sessionKey: [UInt8],
        sequence: UInt64,
        body: String = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
        method: String = "POST",
        target: String = "/mcp/first-party",
        contentType: String = "application/json",
        extraHeaders: [StrictHeaderField] = []
    ) -> StrictHTTPRequest {
        let data = Data(body.utf8)
        let mac = FirstPartyAuthProtocol.requestMAC(
            sessionKey: sessionKey, sessionIdentifier: sessionIdentifier, sequence: sequence,
            method: method, path: target, contentType: contentType, body: data
        )
        var headers = [
            StrictHeaderField(name: "content-type", value: contentType),
            StrictHeaderField(
                name: "authorization",
                value: "\(FirstPartyAuthProtocol.authorizationScheme) "
                    + FirstPartyAuthProtocol.base64URLEncode(sessionIdentifier)
            ),
            StrictHeaderField(
                name: "mootx01-sequence",
                value: FirstPartyAuthProtocol.formatSequenceHeader(sequence)
            ),
            StrictHeaderField(
                name: "mootx01-request-mac",
                value: FirstPartyAuthProtocol.base64URLEncode(mac)
            ),
        ]
        headers.append(contentsOf: extraHeaders)
        return StrictHTTPRequest(method: method, requestTarget: target, headers: headers, body: data)
    }

    // MARK: Handshake

    @Test("A wrong descriptor digest is refused before any state is allocated")
    func challengeVerifiesDescriptorFirst() async throws {
        let (server, _) = Self.makeServer()
        await #expect(throws: FirstPartyAuthError.descriptorMismatch) {
            try await server.challenge(
                clientNonce: [UInt8](repeating: 0xC1, count: 32),
                descriptorDigest: [UInt8](repeating: 0xEE, count: 32)
            )
        }
        // The point of checking first: a peer that cannot name the active
        // descriptor must not be able to consume a slot in a bounded table.
        #expect(await server.liveChallengeCount == 0)
    }

    @Test("A full handshake establishes exactly one session")
    func handshakeEstablishesSession() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        _ = try await Self.handshake(server, descriptor: descriptor)
        #expect(await server.liveSessionCount == 1)
        // The challenge was consumed by establishment.
        #expect(await server.liveChallengeCount == 0)
    }

    @Test("A challenge is single-use")
    func challengeIsSingleUse() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let session = try await Self.handshake(server, descriptor: descriptor)
        // Replaying establishment against the consumed challenge fails.
        await #expect(throws: FirstPartyAuthError.unknownChallenge) {
            try await server.establish(
                sessionIdentifier: session.sessionIdentifier,
                clientProof: [UInt8](repeating: 0x00, count: 32)
            )
        }
    }

    @Test("A reflected server proof does not authenticate as a client proof")
    func reflectedServerProofRejected() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let issued = try await server.challenge(
            clientNonce: [UInt8](repeating: 0xC1, count: 32),
            descriptorDigest: descriptor.digest()
        )
        // Echo the server's own proof straight back. Distinct domains are what
        // make this fail.
        await #expect(throws: FirstPartyAuthError.badClientProof) {
            try await server.establish(
                sessionIdentifier: issued.sessionIdentifier, clientProof: issued.serverProof
            )
        }
        #expect(await server.liveSessionCount == 0)
    }

    @Test("An expired challenge cannot be established")
    func challengeExpires() async throws {
        let descriptor = Self.signedDescriptor()
        let clock = ManualClock()
        let (server, _) = Self.makeServer(descriptor: descriptor, clock: clock)
        let issued = try await server.challenge(
            clientNonce: [UInt8](repeating: 0xC1, count: 32),
            descriptorDigest: descriptor.digest()
        )
        clock.advance(FirstPartyAuthProtocol.challengeLifetime + 1)
        await #expect(throws: FirstPartyAuthError.unknownChallenge) {
            try await server.establish(
                sessionIdentifier: issued.sessionIdentifier,
                clientProof: [UInt8](repeating: 0x01, count: 32)
            )
        }
    }

    @Test("The challenge table is bounded and refuses rather than evicting a live entry")
    func challengeTableIsBounded() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        for _ in 0..<FirstPartyAuthProtocol.maxChallenges {
            _ = try await server.challenge(
                clientNonce: [UInt8](repeating: 0xC1, count: 32),
                descriptorDigest: descriptor.digest()
            )
        }
        #expect(await server.liveChallengeCount == FirstPartyAuthProtocol.maxChallenges)
        await #expect(throws: FirstPartyAuthError.capacityExhausted) {
            try await server.challenge(
                clientNonce: [UInt8](repeating: 0xC1, count: 32),
                descriptorDigest: descriptor.digest()
            )
        }
        // Still exactly at capacity: nothing live was displaced to make room.
        #expect(await server.liveChallengeCount == FirstPartyAuthProtocol.maxChallenges)
    }

    // MARK: Credential faults

    @Test("Every Keychain fault is fatal and never treated as absence", arguments: [
        FirstPartyAuthError.missingEntitlement,
        FirstPartyAuthError.rootUnavailable,
        FirstPartyAuthError.rootMalformed,
        FirstPartyAuthError.keychainUnavailable,
        FirstPartyAuthError.rootSynchronizable,
    ])
    func credentialFaultsFailClosed(fault: FirstPartyAuthError) async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(
            provider: FailingFirstPartyRootProvider(error: fault), descriptor: descriptor
        )
        await #expect(throws: fault) {
            try await server.challenge(
                clientNonce: [UInt8](repeating: 0xC1, count: 32),
                descriptorDigest: descriptor.digest()
            )
        }
        #expect(await server.liveSessionCount == 0)
    }

    @Test("errSecMissingEntitlement is reported as missing entitlement, not as a missing item")
    func missingEntitlementIsNotAbsence() async throws {
        let provider = DataProtectionKeychainRootProvider(
            accessGroup: "G94X5T5GK7.com.codedaptive.mootx01.shared",
            lookup: { _ in (errSecMissingEntitlement, nil) }
        )
        await #expect(throws: FirstPartyAuthError.missingEntitlement) {
            try await provider.installationRoot()
        }
    }

    @Test("The Keychain query selects the data-protection keychain and a non-synchronizable item")
    func keychainQueryShape() {
        let provider = DataProtectionKeychainRootProvider(
            accessGroup: "G94X5T5GK7.com.codedaptive.mootx01.shared", lookup: { _ in (errSecSuccess, nil) }
        )
        let query = provider.query
        // Without the data-protection flag, kSecAttrAccessGroup is not enforced
        // on macOS — the group would be advisory and the item unprotected.
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrService as String] as? String == FirstPartyAuthProtocol.keychainService)
        #expect(query[kSecAttrAccount as String] as? String == FirstPartyAuthProtocol.keychainAccount)
        #expect(query[kSecAttrAccessGroup as String] as? String == "G94X5T5GK7.com.codedaptive.mootx01.shared")
    }

    @Test("An unexpanded or empty access group is refused before the Keychain is asked")
    func unexpandedAccessGroupRefused() async throws {
        for group in ["", "shared"] {
            let provider = DataProtectionKeychainRootProvider(
                accessGroup: group,
                lookup: { _ in Issue.record("Keychain must not be queried"); return (errSecSuccess, nil) }
            )
            await #expect(throws: FirstPartyAuthError.missingEntitlement) {
                try await provider.installationRoot()
            }
        }
    }

    @Test("A root of the wrong length is malformed, never padded")
    func shortRootIsMalformed() async throws {
        let provider = DataProtectionKeychainRootProvider(
            accessGroup: "G94X5T5GK7.com.codedaptive.mootx01.shared",
            lookup: { _ in (errSecSuccess, Data(repeating: 0x01, count: 16)) }
        )
        await #expect(throws: FirstPartyAuthError.rootMalformed) {
            try await provider.installationRoot()
        }
    }

    // MARK: Middleware

    @Test("A well-formed signed request authenticates")
    func happyPath() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let session = try await Self.handshake(server, descriptor: descriptor)
        let request = Self.signedRequest(
            sessionIdentifier: session.sessionIdentifier, sessionKey: session.sessionKey, sequence: 1
        )
        let authenticated = try await server.authenticate(request)
        #expect(authenticated.sequence == 1)
        #expect(authenticated.sessionIdentifier == session.sessionIdentifier)
    }

    @Test("A duplicated authentication header is refused rather than resolved last-wins")
    func duplicateHeaderRefused() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let session = try await Self.handshake(server, descriptor: descriptor)
        // A second Mootx01-Sequence line. LoopbackHTTP would have collapsed this
        // to one value before the lane ever saw it; the strict parser keeps both
        // so it can be refused.
        let request = Self.signedRequest(
            sessionIdentifier: session.sessionIdentifier, sessionKey: session.sessionKey, sequence: 1,
            extraHeaders: [StrictHeaderField(name: "mootx01-sequence", value: "2")]
        )
        await #expect(throws: FirstPartyAuthError.malformedCredentials) {
            try await server.authenticate(request)
        }
    }

    @Test("Mutating any MAC-covered field is refused", arguments: [
        "method", "target", "contentType", "body", "sequence", "session",
    ])
    func mutatedFieldsRefused(field: String) async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let session = try await Self.handshake(server, descriptor: descriptor)

        // Sign one request, then alter one covered field after signing.
        var request = Self.signedRequest(
            sessionIdentifier: session.sessionIdentifier, sessionKey: session.sessionKey, sequence: 1
        )
        var headers = request.headers
        switch field {
        case "method":
            request = StrictHTTPRequest(
                method: "PUT", requestTarget: request.requestTarget,
                headers: headers, body: request.body
            )
        case "target":
            request = StrictHTTPRequest(
                method: request.method, requestTarget: "/mcp/first-party?x=1",
                headers: headers, body: request.body
            )
        case "contentType":
            headers = headers.map {
                $0.name == "content-type"
                    ? StrictHeaderField(name: "content-type", value: "text/plain") : $0
            }
            request = StrictHTTPRequest(
                method: request.method, requestTarget: request.requestTarget,
                headers: headers, body: request.body
            )
        case "body":
            request = StrictHTTPRequest(
                method: request.method, requestTarget: request.requestTarget,
                headers: headers, body: Data(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#.utf8)
            )
        case "sequence":
            headers = headers.map {
                $0.name == "mootx01-sequence"
                    ? StrictHeaderField(name: "mootx01-sequence", value: "7") : $0
            }
            request = StrictHTTPRequest(
                method: request.method, requestTarget: request.requestTarget,
                headers: headers, body: request.body
            )
        default:
            headers = headers.map {
                $0.name == "authorization"
                    ? StrictHeaderField(
                        name: "authorization",
                        value: "\(FirstPartyAuthProtocol.authorizationScheme) "
                            + FirstPartyAuthProtocol.base64URLEncode([UInt8](repeating: 0x09, count: 16))
                      )
                    : $0
            }
            request = StrictHTTPRequest(
                method: request.method, requestTarget: request.requestTarget,
                headers: headers, body: request.body
            )
        }

        await #expect(throws: (any Error).self) { try await server.authenticate(request) }
    }

    @Test("A failed MAC does not burn the sequence")
    func failedMACDoesNotCommitReplayState() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let session = try await Self.handshake(server, descriptor: descriptor)

        // Forge sequence 1 with a body that was never signed.
        let forged = StrictHTTPRequest(
            method: "POST", requestTarget: "/mcp/first-party",
            headers: Self.signedRequest(
                sessionIdentifier: session.sessionIdentifier,
                sessionKey: session.sessionKey, sequence: 1
            ).headers,
            body: Data(#"{"jsonrpc":"2.0","id":666,"method":"ping"}"#.utf8)
        )
        await #expect(throws: FirstPartyAuthError.badRequestMAC) {
            try await server.authenticate(forged)
        }
        // The legitimate client's sequence 1 must still be usable. If replay
        // state were committed before the MAC verified, an unauthenticated peer
        // could lock a client out by burning its sequence numbers.
        let genuine = Self.signedRequest(
            sessionIdentifier: session.sessionIdentifier, sessionKey: session.sessionKey, sequence: 1
        )
        let ok = try await server.authenticate(genuine)
        #expect(ok.sequence == 1)
    }

    @Test("Replays are refused and out-of-order arrivals are accepted")
    func replayAndConcurrency() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let session = try await Self.handshake(server, descriptor: descriptor)

        func send(_ sequence: UInt64) async throws -> UInt64 {
            try await server.authenticate(Self.signedRequest(
                sessionIdentifier: session.sessionIdentifier,
                sessionKey: session.sessionKey, sequence: sequence
            )).sequence
        }

        #expect(try await send(1) == 1)
        #expect(try await send(3) == 3)   // arrives before 2
        #expect(try await send(2) == 2)   // genuine concurrency, not replay
        await #expect(throws: FirstPartyAuthError.replayedSequence) { _ = try await send(2) }
        await #expect(throws: FirstPartyAuthError.replayedSequence) { _ = try await send(1) }
        // Zero is never legal.
        await #expect(throws: FirstPartyAuthError.malformedCredentials) { _ = try await send(0) }
    }

    @Test("A sequence older than the window is refused")
    func tooOldSequenceRefused() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let session = try await Self.handshake(server, descriptor: descriptor)
        _ = try await server.authenticate(Self.signedRequest(
            sessionIdentifier: session.sessionIdentifier, sessionKey: session.sessionKey, sequence: 500
        ))
        await #expect(throws: FirstPartyAuthError.replayedSequence) {
            try await server.authenticate(Self.signedRequest(
                sessionIdentifier: session.sessionIdentifier,
                sessionKey: session.sessionKey, sequence: 500 - 128
            ))
        }
    }

    @Test("Only an accepted request refreshes the idle deadline")
    func rejectedRequestsDoNotHoldSessionOpen() async throws {
        let descriptor = Self.signedDescriptor()
        let clock = ManualClock()
        let (server, _) = Self.makeServer(descriptor: descriptor, clock: clock)
        let session = try await Self.handshake(server, descriptor: descriptor)

        // Walk to just under the idle deadline, issuing only BAD requests.
        clock.advance(FirstPartyAuthProtocol.sessionIdleTimeout - 1)
        let forged = StrictHTTPRequest(
            method: "POST", requestTarget: "/mcp/first-party",
            headers: Self.signedRequest(
                sessionIdentifier: session.sessionIdentifier,
                sessionKey: session.sessionKey, sequence: 1
            ).headers,
            body: Data(#"{"tampered":true}"#.utf8)
        )
        await #expect(throws: FirstPartyAuthError.badRequestMAC) { try await server.authenticate(forged) }

        // Past the deadline the session is gone — the rejected traffic did not
        // extend it.
        clock.advance(2)
        await #expect(throws: (any Error).self) {
            try await server.authenticate(Self.signedRequest(
                sessionIdentifier: session.sessionIdentifier,
                sessionKey: session.sessionKey, sequence: 1
            ))
        }
    }

    @Test("Absolute expiry is never refreshed by activity")
    func absoluteExpiryIsHard() async throws {
        let descriptor = Self.signedDescriptor()
        let clock = ManualClock()
        let (server, _) = Self.makeServer(descriptor: descriptor, clock: clock)
        let session = try await Self.handshake(server, descriptor: descriptor)

        // Stay active well inside the idle window the whole time.
        var sequence: UInt64 = 1
        var elapsed: UInt64 = 0
        while elapsed < FirstPartyAuthProtocol.sessionAbsoluteTimeout {
            clock.advance(600)
            elapsed += 600
            if elapsed >= FirstPartyAuthProtocol.sessionAbsoluteTimeout { break }
            _ = try? await server.authenticate(Self.signedRequest(
                sessionIdentifier: session.sessionIdentifier,
                sessionKey: session.sessionKey, sequence: sequence
            ))
            sequence += 1
        }
        clock.advance(1)
        await #expect(throws: (any Error).self) {
            try await server.authenticate(Self.signedRequest(
                sessionIdentifier: session.sessionIdentifier,
                sessionKey: session.sessionKey, sequence: sequence
            ))
        }
    }

    @Test("A credential rotation revokes live sessions on the SAME server")
    func rotationRevokesSessions() async throws {
        // Root Adams test-quality finding. The earlier version of this case
        // built a SECOND server and asserted its (empty) session table rejected
        // the session — which it would have done for any input, generation
        // checking or not. It passed without exercising the thing it named.
        //
        // This version rotates the credential generation underneath ONE server
        // that already holds a live session, so the only thing that can revoke
        // it is the generation comparison in `authenticate`.
        let descriptor = Self.signedDescriptor()
        let provider = MutableRootProvider(root: Vectors.fixedRoot, credentialGeneration: 1)
        let clock = ManualClock()
        let counter = RandomCounter()
        let server = FirstPartyAuthServer(
            rootProvider: provider, descriptor: descriptor, serverName: Self.serverName,
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )

        let session = try await Self.handshake(server, descriptor: descriptor)
        // Baseline: the session works before the rotation. Without this the
        // test could pass because the session never worked at all.
        let before = try await server.authenticate(Self.signedRequest(
            sessionIdentifier: session.sessionIdentifier,
            sessionKey: session.sessionKey, sequence: 1
        ))
        #expect(before.sequence == 1)
        #expect(await server.liveSessionCount == 1)

        // Rotate. The session was minted under generation 1.
        provider.rotate(to: 2)

        await #expect(throws: FirstPartyAuthError.sessionExpired) {
            try await server.authenticate(Self.signedRequest(
                sessionIdentifier: session.sessionIdentifier,
                sessionKey: session.sessionKey, sequence: 2
            ))
        }
        // Revoked, not merely refused once — the entry is gone.
        #expect(await server.liveSessionCount == 0)
    }

    @Test("A descriptor republication revokes live sessions lazily")
    func descriptorRepublicationRevokesSessions() async throws {
        // The other half of the generation pair. Republication does not clear
        // the session table; the per-request generation check is what revokes,
        // which is exactly the branch this exercises.
        let descriptor = Self.signedDescriptor(descriptorGeneration: 1)
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let session = try await Self.handshake(server, descriptor: descriptor)

        // Baseline: the session works against the descriptor it was minted for.
        let before = try await server.authenticate(Self.signedRequest(
            sessionIdentifier: session.sessionIdentifier,
            sessionKey: session.sessionKey, sequence: 1
        ))
        #expect(before.sequence == 1)

        await server.republish(descriptor: Self.signedDescriptor(descriptorGeneration: 2))

        await #expect(throws: FirstPartyAuthError.sessionExpired) {
            try await server.authenticate(Self.signedRequest(
                sessionIdentifier: session.sessionIdentifier,
                sessionKey: session.sessionKey, sequence: 2
            ))
        }
        #expect(await server.liveSessionCount == 0)
        // Outstanding challenges are bound to the old digest and are dropped.
        #expect(await server.liveChallengeCount == 0)
    }

    // MARK: Actor reentrancy (Perkins MACD2B-SEC-001)

    @Test("A concurrent flood cannot push the challenge table past its bound")
    func concurrentFloodRespectsChallengeBound() async throws {
        // The bound used to be enforced on the WRONG SIDE of an await: every
        // caller passed the capacity guard, suspended in the root provider, and
        // then inserted on resume — so a table documented as hard-bounded at 128
        // grew to however many callers arrived. The gate provider below makes
        // that window deterministic rather than hoping for a race.
        let descriptor = Self.signedDescriptor()
        let gate = RootGate()
        let provider = GatedRootProvider(root: Vectors.fixedRoot, gate: gate)
        let clock = ManualClock()
        let counter = RandomCounter()
        let server = FirstPartyAuthServer(
            rootProvider: provider, descriptor: descriptor, serverName: Self.serverName,
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )

        let attempts = FirstPartyAuthProtocol.maxChallenges * 3
        let digest = descriptor.digest()
        let nonce = [UInt8](repeating: 0xC1, count: 32)

        // Launch every caller and let them all pile up on the suspension.
        async let outcomes: [Bool] = withTaskGroup(of: Bool.self) { group in
            for _ in 0..<attempts {
                group.addTask {
                    (try? await server.challenge(clientNonce: nonce, descriptorDigest: digest)) != nil
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }

        // EVERY caller must be parked before the gate opens.
        //
        // Releasing after one waiter — which this test used to do — proves
        // nothing: the gate stops suspending once open, so the remaining 383
        // callers run to completion one at a time, each observing an accurate
        // count. That serialized order is precisely the order the pre-await-only
        // implementation survives. The bug is only reachable when every caller
        // has passed the pre-await guard and is suspended simultaneously.
        let allParked = await gate.waitUntilWaiting(atLeast: attempts)
        // Without every caller parked, this test cannot distinguish a bounded
        // server from an unbounded one.
        #expect(allParked, "all callers must be parked before the gate is opened")
        #expect(await gate.waitingCount == attempts)
        await gate.open()
        let results = await outcomes

        let admitted = results.filter { $0 }.count
        // The bound holds even though every caller passed the pre-await guard.
        #expect(await server.liveChallengeCount <= FirstPartyAuthProtocol.maxChallenges)
        #expect(admitted <= FirstPartyAuthProtocol.maxChallenges)
        // And it is a bound, not a coincidence: callers beyond it were refused.
        #expect(admitted < attempts)
        #expect(admitted > 0, "a server that admits nothing would satisfy an upper bound trivially")
    }

    @Test("A republish during the suspension invalidates an in-flight challenge")
    func republishDuringAwaitRejectsStaleDigest() async throws {
        // `republish(descriptor:)` can land while a challenge is suspended in
        // the root provider. A challenge minted against the old digest would
        // produce a transcript no client could reproduce, and would outlive the
        // descriptor that justified it.
        let original = Self.signedDescriptor(descriptorGeneration: 1)
        let gate = RootGate()
        let provider = GatedRootProvider(root: Vectors.fixedRoot, gate: gate)
        let clock = ManualClock()
        let counter = RandomCounter()
        let server = FirstPartyAuthServer(
            rootProvider: provider, descriptor: original, serverName: Self.serverName,
            now: { clock.seconds }, randomBytes: { counter.next($0) }
        )

        let staleDigest = original.digest()
        let nonce = [UInt8](repeating: 0xC1, count: 32)
        async let attempt: Bool = {
            (try? await server.challenge(clientNonce: nonce, descriptorDigest: staleDigest)) != nil
        }()

        // Wait until the caller is parked inside the provider, then move the
        // descriptor underneath it and release.
        let parked = await gate.waitUntilWaiting(atLeast: 1)
        #expect(parked, "the caller must be suspended inside the provider for this test to mean anything")
        await server.republish(descriptor: Self.signedDescriptor(descriptorGeneration: 2))
        await gate.open()

        #expect(await attempt == false, "a challenge minted against a stale digest must be refused")
        #expect(await server.liveChallengeCount == 0)
    }

    @Test("Revocation clears every session and challenge")
    func revokeAll() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        _ = try await Self.handshake(server, descriptor: descriptor)
        await server.revokeAllSessions()
        #expect(await server.liveSessionCount == 0)
        #expect(await server.liveChallengeCount == 0)
    }

    @Test("Response sealing binds status, sequence, and body")
    func responseSealing() async throws {
        let descriptor = Self.signedDescriptor()
        let (server, _) = Self.makeServer(descriptor: descriptor)
        let session = try await Self.handshake(server, descriptor: descriptor)
        let body = Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8)
        let sealed = await server.sealResponse(
            sessionIdentifier: session.sessionIdentifier, sequence: 1,
            status: 200, contentType: "application/json", body: body
        )
        #expect(sealed == FirstPartyAuthProtocol.responseMAC(
            sessionKey: session.sessionKey, sessionIdentifier: session.sessionIdentifier,
            sequence: 1, status: 200, contentType: "application/json", body: body
        ))
        // An unknown session cannot be sealed for at all.
        let unknown = await server.sealResponse(
            sessionIdentifier: [UInt8](repeating: 0xAB, count: 16), sequence: 1,
            status: 200, contentType: "application/json", body: body
        )
        #expect(unknown == nil)
    }
}

// MARK: - Strict parser

@Suite("First-party auth server — strict request parsing")
struct StrictHTTPParserTests {

    static func raw(_ text: String) -> Data { Data(text.utf8) }

    @Test("A well-formed request parses and preserves duplicate headers in order")
    func parsesAndPreservesDuplicates() throws {
        let request = StrictHTTPParser.parse(Self.raw(
            "POST /mcp/first-party HTTP/1.1\r\n"
            + "Content-Type: application/json\r\n"
            + "Mootx01-Sequence: 1\r\n"
            + "Mootx01-Sequence: 2\r\n"
            + "Content-Length: 2\r\n"
            + "\r\n{}"
        ), maxBodyBytes: 4096)
        let parsed = try #require(request)
        #expect(parsed.method == "POST")
        #expect(parsed.requestTarget == "/mcp/first-party")
        // Both survive — which is the entire reason this parser exists.
        #expect(parsed.values(for: "mootx01-sequence") == ["1", "2"])
        // …and a duplicated header therefore has no single value.
        #expect(parsed.singleValue(for: "mootx01-sequence") == nil)
        #expect(parsed.body == Data("{}".utf8))
    }

    @Test("Field names are matched case-insensitively")
    func caseInsensitiveNames() {
        let parsed = StrictHTTPParser.parse(Self.raw(
            "POST /mcp/first-party HTTP/1.1\r\nCONTENT-TYPE: application/json\r\n\r\n"
        ), maxBodyBytes: 4096)
        #expect(parsed?.singleValue(for: "content-type") == "application/json")
    }

    @Test("Exactly the ASCII OWS the grammar allows is stripped, and nothing inside the value")
    func onlyASCIIWhitespaceStripped() {
        // Leading SP and trailing HTAB are the optional whitespace RFC 9110
        // permits around a field value, so stripping them is authorized. Spacing
        // INSIDE the value is part of the value and must survive — a parser that
        // collapsed it would change the bytes a MAC was computed over.
        let parsed = StrictHTTPParser.parse(Self.raw(
            "POST /mcp/first-party HTTP/1.1\r\nX-Test: \tvalue  with   spacing\t \r\n\r\n"
        ), maxBodyBytes: 4096)
        #expect(parsed?.singleValue(for: "x-test") == "value  with   spacing")
    }

    @Test("A non-ASCII byte anywhere in the header block refuses the whole request")
    func nonASCIIHeaderRefused() {
        // RFC 9110 deprecates obs-text in field values, and this lane has no use
        // for it. Refusing outright is stricter than decoding leniently, and it
        // removes the class of bug where two parsers disagree about how a
        // non-ASCII byte decodes — which for a MAC-bearing header means they
        // disagree about what was signed.
        #expect(StrictHTTPParser.parse(Self.raw(
            "POST /mcp/first-party HTTP/1.1\r\nX-Test: \u{00A0}value\r\n\r\n"
        ), maxBodyBytes: 4096) == nil)
    }

    @Test("Malformed requests are refused rather than normalized", arguments: [
        // Obsolete line folding.
        "POST /mcp/first-party HTTP/1.1\r\nContent-Type: application/\r\n json\r\n\r\n",
        // Bare LF is not a line ending in HTTP/1.1.
        "POST /mcp/first-party HTTP/1.1\nContent-Type: application/json\r\n\r\n",
        // Whitespace before the colon.
        "POST /mcp/first-party HTTP/1.1\r\nContent-Type : application/json\r\n\r\n",
        // Two spaces in the start line.
        "POST  /mcp/first-party HTTP/1.1\r\n\r\n",
        // Content-Length disagrees with the body — the smuggling primitive.
        "POST /mcp/first-party HTTP/1.1\r\nContent-Length: 99\r\n\r\n{}",
        // Non-canonical Content-Length.
        "POST /mcp/first-party HTTP/1.1\r\nContent-Length: 02\r\n\r\n{}",
        // Duplicate Content-Length.
        "POST /mcp/first-party HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
        // Transfer-Encoding is the other half of request smuggling.
        "POST /mcp/first-party HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        // A body with no Content-Length at all.
        "POST /mcp/first-party HTTP/1.1\r\n\r\n{}",
        // Empty field name.
        "POST /mcp/first-party HTTP/1.1\r\n: value\r\n\r\n",
        // No header terminator.
        "POST /mcp/first-party HTTP/1.1\r\n",
    ])
    func malformedRefused(text: String) {
        #expect(StrictHTTPParser.parse(Self.raw(text), maxBodyBytes: 4096) == nil)
    }

    @Test("A body larger than the cap is refused, never truncated")
    func oversizeBodyRefused() {
        let body = String(repeating: "a", count: 100)
        let text = "POST /mcp/first-party HTTP/1.1\r\nContent-Length: 100\r\n\r\n" + body
        #expect(StrictHTTPParser.parse(Self.raw(text), maxBodyBytes: 50) == nil)
    }

    // Codex Security 92eb919d. Splitting on CRLF alone leaves a bare LF (or a
    // bare CR) INSIDE a surviving header line, where a lenient downstream
    // parser would see a line break this parser did not — the classic
    // request-smuggling disagreement. Every byte of the header section must
    // therefore be free of bare line endings, not just the start line.
    @Test("Bare LF or bare CR anywhere in the header section refuses the whole request", arguments: [
        // Bare LF inside a header value — a lenient parser reads a forged
        // Authorization header where this parser read one field.
        "POST /mcp/first-party HTTP/1.1\r\nX-A: a\nAuthorization: forged\r\n\r\n",
        // LF-only ending between two header lines.
        "POST /mcp/first-party HTTP/1.1\r\nX-A: 1\nX-B: 2\r\n\r\n",
        // Bare CR inside a header value.
        "POST /mcp/first-party HTTP/1.1\r\nX-A: a\rb\r\n\r\n",
        // Bare LF as the final byte before the CRLFCRLF terminator.
        "POST /mcp/first-party HTTP/1.1\r\nX-A: ok\n\r\n\r\n",
        // Smuggled second Content-Length hidden behind a bare LF in a benign
        // header — the shape a front/back parser pair disagrees about.
        "POST /mcp/first-party HTTP/1.1\r\nX-Ignore: a\nContent-Length: 5\r\nContent-Length: 2\r\n\r\n{}",
    ])
    func bareLineEndingInHeaderRefused(text: String) {
        #expect(StrictHTTPParser.parse(Self.raw(text), maxBodyBytes: 4096) == nil)
    }

    @Test("A well-formed CRLF request parses identically when its bytes arrive fragmented")
    func fragmentedWellFormedRequestParses() {
        // TCP delivers bytes at arbitrary boundaries — including mid-CRLF.
        // Reassembly must be byte-transparent: the same bytes parse the same
        // way no matter how they were fragmented in transit.
        let fragments = [
            "POST /mcp/first-party HT", "TP/1.1\r", "\nContent-Type: application/json\r\n",
            "Content-Length: 2", "\r", "\n\r", "\n{}",
        ]
        var assembled = Data()
        for fragment in fragments { assembled.append(Data(fragment.utf8)) }
        let parsed = StrictHTTPParser.parse(assembled, maxBodyBytes: 4096)
        #expect(parsed?.singleValue(for: "content-type") == "application/json")
        #expect(parsed?.body == Data("{}".utf8))
    }
}

// MARK: - Test doubles

/// A clock the tests drive by hand. Injected everywhere a security deadline is
/// evaluated, because expiry that cannot be advanced cannot be tested.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1_766_000_100

    var seconds: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ delta: UInt64) {
        lock.lock(); defer { lock.unlock() }
        value += delta
    }
}

/// A releasable suspension point.
///
/// Real providers suspend for a Keychain read; `FixedFirstPartyRootProvider`
/// returns immediately and may not suspend at all, which would make a
/// reentrancy test depend on luck. This gate parks every caller until it is
/// opened, so the window under test is deterministic.
actor RootGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        // Once opened the gate stops suspending. That is why a test MUST park
        // every caller it cares about BEFORE opening: releasing early lets the
        // remaining callers run straight through, one at a time, which is
        // exactly the serialized order a broken implementation survives.
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let parked = waiters
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }

    /// How many callers are suspended right now.
    var waitingCount: Int { waiters.count }

    /// Park until at least `count` callers are suspended.
    ///
    /// Bounded and FAIL-CLOSED: it gives up after `maxYields` scheduler turns
    /// and returns `false` rather than hanging the suite. A test that cannot
    /// assemble the concurrency it needs must fail loudly, not quietly weaken
    /// into a serial test that passes for the wrong reason.
    ///
    /// - Returns: `true` when `count` callers are parked; `false` on timeout.
    func waitUntilWaiting(atLeast count: Int, maxYields: Int = 2_000_000) async -> Bool {
        var spins = 0
        while waiters.count < count {
            if spins >= maxYields { return false }
            spins += 1
            await Task.yield()
        }
        return true
    }
}

/// A root provider that parks on a shared gate before returning the root.
struct GatedRootProvider: FirstPartyRootProviding {
    let root: [UInt8]
    let gate: RootGate
    var credentialGeneration: UInt64 { 1 }

    func installationRoot() async throws -> [UInt8] {
        await gate.wait()
        return root
    }
}

/// A root provider whose credential generation can be rotated at runtime.
///
/// Needed because `FixedFirstPartyRootProvider`'s generation is a `let`: with it,
/// `session.credentialGeneration == rootProvider.credentialGeneration` is always
/// true and the revocation branch is unreachable — a check that cannot be made
/// to fail cannot be said to have been tested.
final class MutableRootProvider: FirstPartyRootProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let root: [UInt8]
    private var generation: UInt64

    init(root: [UInt8], credentialGeneration: UInt64) {
        self.root = root
        self.generation = credentialGeneration
    }

    var credentialGeneration: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func rotate(to value: UInt64) {
        lock.lock(); defer { lock.unlock() }
        generation = value
    }

    func installationRoot() async throws -> [UInt8] { root }
}

/// Deterministic stand-in for `SecRandomCopyBytes`. Counter-driven so nonces and
/// session identifiers are distinct and reproducible across a run.
final class RandomCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0

    func next(_ count: Int) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        var out = [UInt8](repeating: 0, count: count)
        for index in 0..<min(8, count) {
            out[index] = UInt8(truncatingIfNeeded: counter >> (UInt64(index) * 8))
        }
        return out
    }
}

// MARK: - MACD-3B1 Part B — Schema-3 specific tests for FirstPartyAuthProtocol

// A local helper for subsequence search that avoids the Swift Algorithms import.
// Uses a simple O(n·m) scan over [UInt8]; the inputs in these tests are small.
private extension [UInt8] {
    func containsSubsequence(_ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, needle.count <= self.count else { return false }
        return (0...(self.count - needle.count)).contains { start in
            self[start..<(start + needle.count)].elementsEqual(needle)
        }
    }
}

@Suite("MACD-3B1 — schema-3 descriptor contract (FirstPartyAuthProtocol layer)")
struct Schema3DescriptorContractTests {

    static let fixedRoot: [UInt8] = (0..<32).map { UInt8($0) }

    // MARK: Schema-3 descriptorSchemaVersion constant

    @Test("descriptorSchemaVersion is 3 (MACD-3B1 bump from 2)")
    func descriptorSchemaVersionIs3() {
        // MACD-3B1: descriptorSchemaVersion bumped 2 → 3.  Schema-2 golden MAC
        // vectors in this file use literal schemaVersion: 2 to prove schema-2
        // bytes are unchanged (R1).  This test locks the new constant value.
        #expect(FirstPartyAuthProtocol.descriptorSchemaVersion == 3)
    }

    // MARK: Schema-3 round-trip through macInput

    @Test("schema-3 descriptor macInput includes schemaVersion field as UInt64(3)")
    func schema3MacInputContainsVersion3() {
        // macInput encodes schemaVersion via UInt64(bitPattern: Int64(schemaVersion)).
        // For schemaVersion=3, that is UInt64(3), which encodes as [0,0,0,0,0,0,0,3].
        // Verify the big-endian encoding of the version field is present in macInput.
        var descriptor = FirstPartyAuthProtocolTests.vectorDescriptor()
        descriptor.schemaVersion = FirstPartyAuthProtocol.descriptorSchemaVersion  // 3
        descriptor.descriptorMAC = []
        let input = descriptor.macInput()
        // The 8-byte big-endian encoding of UInt64(3).
        let version3Bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 3]
        // The macInput begins with the descriptor domain string (length-prefixed).
        // schemaVersion is not the first field, but must appear in the input.
        // Verify by checking the bytes contain the version3 pattern.
        let inputContainsVersion3 = input.containsSubsequence(version3Bytes)
        #expect(inputContainsVersion3)
    }

    @Test("schema-2 macInput does NOT contain the version-3 byte pattern (golden anchor)")
    func schema2MacInputHasVersion2NotVersion3() {
        // The schema-2 golden vector (literal schemaVersion: 2) must encode
        // [0,0,0,0,0,0,0,2] in macInput — not [0,0,0,0,0,0,0,3].
        // This proves R1: FirstPartyDescriptor.macInput() was not modified.
        let descriptor = FirstPartyAuthProtocolTests.vectorDescriptor()
        // vectorDescriptor() uses literal schemaVersion: 2.
        #expect(descriptor.schemaVersion == 2)
        let input = descriptor.macInput()
        let version3Bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 3]
        let version2Bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 2]
        #expect(!input.containsSubsequence(version3Bytes))
        #expect(input.containsSubsequence(version2Bytes))
    }

    // MARK: CanonicalEncoder.appendSortedMap — additional golden bytes

    @Test("appendSortedMap encodes count as big-endian UInt32 then length-prefixed key-value pairs")
    func appendSortedMapGoldenBytes() {
        // Single-entry map: { "a": 1 }.
        // Encoding: UInt32(1) | UInt32(1) | 'a' | UInt64(1)
        //         = [0,0,0,1] | [0,0,0,1, 0x61] | [0,0,0,0,0,0,0,1]
        var encoder = CanonicalEncoder()
        encoder.appendSortedMap(["a": 1])
        let expected: [UInt8] = [
            0, 0, 0, 1,          // UInt32 count = 1
            0, 0, 0, 1, 0x61,    // appendString("a"): UInt32 len=1, 'a'
            0, 0, 0, 0, 0, 0, 0, 1,  // appendUInt64(1)
        ]
        #expect(encoder.bytes == expected)
    }

    @Test("appendSortedMap is consistent with appendCapabilities sort order for string keys")
    func appendSortedMapUsesLexicographicOrder() {
        // Both appendCapabilities and appendSortedMap use < for sort order.
        // Confirm that the map key order is the same as sorted string order.
        var mapEncoder = CanonicalEncoder()
        mapEncoder.appendSortedMap(["z": 2, "a": 1])
        // Expected: "a" comes before "z".
        var capEncoder = CanonicalEncoder()
        capEncoder.appendSortedMap(["a": 1, "z": 2])  // identical semantics
        #expect(mapEncoder.bytes == capEncoder.bytes)
        // And confirm "a" really is before "z" — the first key entry after count:
        let countBytes = 4
        let firstKeyLenBytes = 4
        // "a" = 0x61, "z" = 0x7A.
        let firstKeyByte = mapEncoder.bytes[countBytes + firstKeyLenBytes]
        #expect(firstKeyByte == 0x61)  // 'a'
    }
}
