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
