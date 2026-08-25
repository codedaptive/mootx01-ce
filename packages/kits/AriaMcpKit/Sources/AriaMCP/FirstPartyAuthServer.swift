import AriaMCPWire
import Foundation
import Security

// MARK: - First-party authenticated wire — the server lane
//
// This file owns everything the daemon side of the first-party lane needs that
// is not pure algebra: the strict request parser, the root-credential contract,
// the bounded challenge and session tables, and the middleware that must run
// before any JSON is parsed or any request dispatched.
//
// DARK BY CONSTRUCTION. Nothing here is reachable unless an
// `FirstPartyAuthServer` is explicitly constructed and handed to `HTTPServer`.
// Every production construction site inherits `nil` (see the blast-radius
// report's C-1), so the resident daemon cannot serve or advertise this lane
// without an edit no mission has yet made. Darkness is a property of the type
// system here, not a runtime flag someone remembered to leave off.
//
// NO PRODUCTION ROOT IS EVER MINTED HERE. MACD-2c supplies the exclusive
// provider lock; until it exists, minting a root would create a credential with
// no owner and no arbiter. The reader below can only READ, and every failure
// mode — missing entitlement, missing item, malformed length, a synchronizable
// item, any Keychain error — is fatal. None of them is ever treated as ordinary
// absence, because "absent" is exactly the answer that would tempt a caller to
// create one.

/// Why a first-party operation was refused.
///
/// One case per distinct cause, because "which gate closed" is the first
/// question every authentication bug asks. None of these values ever carries key
/// material, proof bytes, or a Keychain item's contents — they are safe to log.
public enum FirstPartyAuthError: Error, Equatable, Sendable {

    /// The signed bundle carries no Keychain access-group entitlement, or the
    /// entitlement does not authorize the group this protocol requires.
    ///
    /// FATAL, never "absent". `errSecMissingEntitlement` means the process is
    /// not allowed to see the item — an unentitled process being told "no such
    /// item" and responding by creating one is how a second, competing root
    /// gets minted.
    case missingEntitlement

    /// The root item is not present. Fatal here: only MACD-2c's provider may
    /// create one.
    case rootUnavailable

    /// The item exists but is not exactly `rootKeyByteCount` bytes.
    case rootMalformed

    /// The Keychain returned an error other than "not found". The OSStatus is
    /// deliberately not carried: it is diagnostic noise at this boundary and
    /// the caller's only correct response to any of them is to fail closed.
    case keychainUnavailable

    /// The item was marked synchronizable — it may have left this device, so it
    /// cannot be the device-bound installation root.
    case rootSynchronizable

    /// The request could not be parsed under the strict grammar.
    case malformedRequest

    /// A required authentication header was absent, duplicated, or malformed.
    case malformedCredentials

    /// No live session matches the presented identifier.
    case unknownSession

    /// The session exists but has passed its idle or absolute expiry.
    case sessionExpired

    /// The request MAC did not verify.
    case badRequestMAC

    /// The sequence was a replay, was too old to adjudicate, or was zero.
    case replayedSequence

    /// The session's sequence space is exhausted.
    case sequenceExhausted

    /// The challenge is unknown, already consumed, or expired.
    case unknownChallenge

    /// The client proof did not verify.
    case badClientProof

    /// A bounded table is full and no entry has expired. The server refuses
    /// rather than evicting a live entry — eviction would let a flood displace
    /// a legitimate peer's session.
    case capacityExhausted

    /// The presented descriptor digest is not the active descriptor's.
    case descriptorMismatch
}

// MARK: - Root credential

/// Supplies the 32-byte installation root.
///
/// An interface rather than a concrete reader so tests can inject a fixed root
/// and specific failures without a Keychain, and so MACD-2c can supply the real
/// provider behind the exclusive lock without touching this file.
public protocol FirstPartyRootProviding: Sendable {

    /// The installation root, exactly `rootKeyByteCount` bytes.
    ///
    /// - Throws: `FirstPartyAuthError` on every failure. There is no "absent"
    ///   success case.
    func installationRoot() async throws -> [UInt8]

    /// Monotonic; bumped by an explicit rotation. A change revokes every
    /// session derived under the previous value.
    var credentialGeneration: UInt64 { get }
}

/// A fixed in-memory root. TEST AND INJECTION ONLY — it holds key material in
/// process memory, which is precisely what the data-protection Keychain exists
/// to avoid.
public struct FixedFirstPartyRootProvider: FirstPartyRootProviding {
    private let root: [UInt8]
    public let credentialGeneration: UInt64

    public init(root: [UInt8], credentialGeneration: UInt64 = 1) {
        self.root = root
        self.credentialGeneration = credentialGeneration
    }

    public func installationRoot() async throws -> [UInt8] {
        guard root.count == FirstPartyAuthProtocol.rootKeyByteCount else {
            throw FirstPartyAuthError.rootMalformed
        }
        return root
    }
}

/// A provider that always fails. Used to prove the lane stays closed on every
/// credential fault rather than degrading to an unauthenticated path.
public struct FailingFirstPartyRootProvider: FirstPartyRootProviding {
    private let error: FirstPartyAuthError
    public let credentialGeneration: UInt64

    public init(error: FirstPartyAuthError, credentialGeneration: UInt64 = 1) {
        self.error = error
        self.credentialGeneration = credentialGeneration
    }

    public func installationRoot() async throws -> [UInt8] { throw error }
}

/// Reads the installation root from the macOS data-protection Keychain.
///
/// The query shape is the whole security argument, so it is spelled out rather
/// than assembled from configuration:
///
/// - `kSecUseDataProtectionKeychain: true` — REQUIRED. `kSecAttrAccessGroup` is
///   only enforced on macOS when the data-protection or synchronizable keychain
///   is selected. Without this flag the access group is advisory and the item
///   is not actually protected by it.
/// - `kSecAttrAccessGroup` — the FULLY EXPANDED runtime group read from the
///   signed entitlement, never a literal. An unexpanded group silently misses.
/// - `kSecAttrSynchronizable: false` — the root is device-bound. A
///   synchronizable item may have left this device.
/// - service and account are PROTOCOL CONSTANTS, never taken from a descriptor.
///   A descriptor is unauthenticated input until its MAC verifies under a key
///   found at this account; letting it name the account would let an attacker
///   point the reader at an item they control and verify their own forgery.
///
/// This provider only ever reads. It has no code path that adds, updates, or
/// deletes a Keychain item: creating the installation root is MACD-2c's, behind
/// the exclusive provider lock, because a root minted before an arbiter exists
/// is a credential with no owner.
public struct DataProtectionKeychainRootProvider: FirstPartyRootProviding {

    /// Performs the Keychain lookup. Injected so tests can drive every failure
    /// path — including `errSecMissingEntitlement` — without entitlements.
    public typealias ItemLookup = @Sendable (_ query: [String: Any]) -> (status: OSStatus, item: Any?)

    /// The fully expanded access group, e.g. `G94X5T5GK7.com.codedaptive.mootx01.shared`.
    private let accessGroup: String
    private let lookup: ItemLookup

    public let credentialGeneration: UInt64

    /// - Parameters:
    ///   - accessGroup: The fully expanded runtime entitlement value. Callers
    ///     read this from the signed bundle; it is never a compiled-in literal.
    ///   - credentialGeneration: The generation this provider serves.
    ///   - lookup: The Keychain lookup. Defaults to `SecItemCopyMatching`.
    public init(
        accessGroup: String,
        credentialGeneration: UInt64 = 1,
        lookup: @escaping ItemLookup = { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result)
        }
    ) {
        self.accessGroup = accessGroup
        self.credentialGeneration = credentialGeneration
        self.lookup = lookup
    }

    /// The exact query this provider issues. Exposed so a test can assert the
    /// shape rather than trusting a comment about it.
    public var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: FirstPartyAuthProtocol.keychainService,
            kSecAttrAccount as String: FirstPartyAuthProtocol.keychainAccount,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
    }

    public func installationRoot() async throws -> [UInt8] {
        // An empty or unexpanded group would make the query match nothing while
        // looking correct. Refuse before asking.
        guard !accessGroup.isEmpty, accessGroup.contains(".") else {
            throw FirstPartyAuthError.missingEntitlement
        }

        let (status, item) = lookup(query)
        switch status {
        case errSecSuccess:
            break
        case errSecMissingEntitlement:
            // NOT absence. See the type's doc comment.
            throw FirstPartyAuthError.missingEntitlement
        case errSecItemNotFound:
            throw FirstPartyAuthError.rootUnavailable
        default:
            throw FirstPartyAuthError.keychainUnavailable
        }

        guard let data = item as? Data else { throw FirstPartyAuthError.rootMalformed }
        guard data.count == FirstPartyAuthProtocol.rootKeyByteCount else {
            throw FirstPartyAuthError.rootMalformed
        }
        return Array(data)
    }
}

// MARK: - Strict request parsing

/// One header line, exactly as received.
///
/// The name is lowercased (HTTP field names are case-insensitive, so this is a
/// normalization the grammar authorizes). The value keeps every byte between
/// the RFC 9110 optional leading and trailing whitespace — no Unicode trimming,
/// no collapsing, no rewriting.
public struct StrictHeaderField: Sendable, Equatable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A first-party request parsed WITHOUT loss.
///
/// `LoopbackHTTP.HTTPRequest` is the right shape for the third-party lane and
/// the wrong shape here, in two ways that both matter to a MAC:
///
/// 1. it collapses duplicate header lines last-wins, so a duplicated
///    authentication header is invisible rather than refusable; and
/// 2. it trims values with `trimmingCharacters(in: .whitespaces)`, which strips
///    Unicode whitespace rather than the ASCII SP/HTAB the grammar allows — so
///    the value a consumer compares is not necessarily the value that arrived.
///
/// A MAC-bearing header has to be judged as transmitted, so the first-party lane
/// parses its own. `LoopbackHTTP` is untouched and the third-party lane keeps
/// its exact current behaviour.
public struct StrictHTTPRequest: Sendable, Equatable {
    public let method: String
    /// The request target exactly as it appeared on the request line, including
    /// any query string. Compared whole: the lane has one legal target.
    public let requestTarget: String
    public let headers: [StrictHeaderField]
    public let body: Data

    public init(method: String, requestTarget: String, headers: [StrictHeaderField], body: Data) {
        self.method = method
        self.requestTarget = requestTarget
        self.headers = headers
        self.body = body
    }

    /// All values for `name`, in wire order. Returns every occurrence, which is
    /// the point of this type.
    public func values(for name: String) -> [String] {
        headers.filter { $0.name == name }.map(\.value)
    }

    /// The single value for `name`, or `nil` if it is absent OR duplicated.
    ///
    /// Duplication is an error rather than a last-wins choice: two spellings of
    /// one authentication input is a disagreement, and a lane that silently
    /// picks one has picked for the attacker.
    public func singleValue(for name: String) -> String? {
        let all = values(for: name)
        return all.count == 1 ? all[0] : nil
    }
}

/// A strict HTTP/1.1 request parser for the first-party lane.
///
/// Strict means: no obsolete line folding, no bare CR or LF as a line ending, no
/// non-ASCII in the start line or field names, exactly one SP between start-line
/// tokens, and a `Content-Length` that must be canonical decimal and must match
/// the body actually read. Anything it cannot represent exactly is refused
/// rather than normalized — on this lane an ambiguous request is a refused
/// request.
public enum StrictHTTPParser {

    /// Parse a complete request from `bytes`.
    ///
    /// - Parameters:
    ///   - bytes: The full request: start line, headers, CRLFCRLF, body.
    ///   - maxBodyBytes: Refuse a `Content-Length` above this.
    /// - Returns: The parsed request, or `nil` when the grammar is violated.
    public static func parse(_ bytes: Data, maxBodyBytes: Int) -> StrictHTTPRequest? {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let headerEnd = bytes.range(of: terminator) else { return nil }
        let headerBlock = bytes[bytes.startIndex..<headerEnd.lowerBound]
        let body = Data(bytes[headerEnd.upperBound...])

        // Field names and the start line must be ASCII. A non-ASCII byte here
        // has no legal meaning and is refused rather than decoded leniently.
        guard let headerText = String(data: headerBlock, encoding: .utf8),
              headerText.allSatisfy({ $0.isASCII }) else { return nil }

        // Split on CRLF only. A bare LF is not a line ending in HTTP/1.1, and
        // accepting one is how two parsers come to disagree about where a
        // header ends. After the split, any CR or LF remaining INSIDE a line
        // is by construction a bare one (every CRLF pair was consumed by the
        // split), so its presence anywhere — start line or header field —
        // refuses the whole request rather than letting a lenient downstream
        // parser see a line break this parser did not (Codex Security
        // 92eb919d).
        let lines = headerText.components(separatedBy: "\r\n")
        guard lines.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else { return nil }
        guard let startLine = lines.first, !startLine.isEmpty else { return nil }

        // Exactly three tokens separated by exactly one space each.
        let startTokens = startLine.split(separator: " ", omittingEmptySubsequences: false)
        guard startTokens.count == 3 else { return nil }
        let method = String(startTokens[0])
        let target = String(startTokens[1])
        let version = String(startTokens[2])
        guard !method.isEmpty, !target.isEmpty else { return nil }
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { return nil }

        var fields: [StrictHeaderField] = []
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            // Obsolete line folding: a continuation line begins with SP or HTAB.
            // RFC 9110 removed it; accepting it lets a folded header mean two
            // different things to two parsers.
            guard let first = line.first, first != " ", first != "\t" else { return nil }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let rawName = String(line[line.startIndex..<colon])
            // No whitespace is permitted between the field name and the colon.
            guard !rawName.isEmpty, rawName.allSatisfy({ isTokenCharacter($0) }) else { return nil }
            // Strip exactly the ASCII OWS the grammar allows — SP and HTAB —
            // and nothing else.
            let rawValue = String(line[line.index(after: colon)...])
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            fields.append(StrictHeaderField(name: rawName.lowercased(), value: value))
        }

        // Content-Length must be canonical, present at most once, and must
        // describe the body exactly. A mismatch is the classic smuggling
        // primitive, so it is refused rather than truncated or padded.
        let lengths = fields.filter { $0.name == "content-length" }
        if lengths.count > 1 { return nil }
        if let raw = lengths.first?.value {
            guard raw.allSatisfy({ $0.isASCII && $0.isNumber }), !raw.isEmpty else { return nil }
            if raw.count > 1 && raw.first == "0" { return nil }
            guard let declared = Int(raw), declared <= maxBodyBytes else { return nil }
            guard declared == body.count else { return nil }
        } else if !body.isEmpty {
            return nil
        }

        // Transfer-Encoding is not supported on this lane. Accepting it
        // alongside Content-Length is the other half of request smuggling.
        guard !fields.contains(where: { $0.name == "transfer-encoding" }) else { return nil }

        return StrictHTTPRequest(method: method, requestTarget: target, headers: fields, body: body)
    }

    /// RFC 9110 token characters, the only bytes legal in a field name.
    private static func isTokenCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        if character.isLetter || character.isNumber { return true }
        return "!#$%&'*+-.^_`|~".contains(character)
    }
}

// MARK: - Server identity

/// What the first-party lane's `initialize` must report, and what the client
/// checks it against.
///
/// Every field is drawn from the ACTIVE, MAC-VERIFIED descriptor, so a truthful
/// `serverInfo` and a verified descriptor cannot disagree — if they did, the
/// client would have no way to tell which was lying.
public struct FirstPartyServerIdentity: Sendable, Equatable {
    public let name: String
    public let binaryVersion: String
    public let instanceIdentifier: UUID
    public let estateIdentifier: UUID
    public let descriptorGeneration: UInt64
    public let credentialGeneration: UInt64
    public let contractRevision: Int
    public let mcpProtocolVersion: String

    public init(
        name: String,
        binaryVersion: String,
        instanceIdentifier: UUID,
        estateIdentifier: UUID,
        descriptorGeneration: UInt64,
        credentialGeneration: UInt64,
        contractRevision: Int,
        mcpProtocolVersion: String
    ) {
        self.name = name
        self.binaryVersion = binaryVersion
        self.instanceIdentifier = instanceIdentifier
        self.estateIdentifier = estateIdentifier
        self.descriptorGeneration = descriptorGeneration
        self.credentialGeneration = credentialGeneration
        self.contractRevision = contractRevision
        self.mcpProtocolVersion = mcpProtocolVersion
    }

    /// Build the identity from a descriptor the caller has already verified.
    public init(verifiedDescriptor descriptor: FirstPartyDescriptor, serverName: String) {
        self.init(
            name: serverName,
            binaryVersion: descriptor.binaryVersion,
            instanceIdentifier: descriptor.instanceIdentifier,
            estateIdentifier: descriptor.estateIdentifier,
            descriptorGeneration: descriptor.descriptorGeneration,
            credentialGeneration: descriptor.credentialGeneration,
            contractRevision: descriptor.contractRevision,
            mcpProtocolVersion: descriptor.mcpProtocolVersion
        )
    }
}

// MARK: - Session and challenge records

/// An outstanding challenge. Single-use and short-lived.
struct FirstPartyChallenge: Sendable {
    let sessionIdentifier: [UInt8]
    let clientNonce: [UInt8]
    let serverNonce: [UInt8]
    let transcript: [UInt8]
    let issuedAt: UInt64
    let idleExpiry: UInt64
    let absoluteExpiry: UInt64
    /// Wall-clock second after which this challenge is dead regardless of use.
    let expiresAt: UInt64
}

/// A live authenticated session.
struct FirstPartySession: Sendable {
    let sessionKey: [UInt8]
    let issuedAt: UInt64
    let absoluteExpiry: UInt64
    /// Refreshed ONLY by an accepted authenticated request, so a stream of
    /// rejected requests cannot hold a session open.
    var idleExpiry: UInt64
    var replay: ReplayWindow
    /// The generation pair this session was minted under. A change to either
    /// revokes it.
    let credentialGeneration: UInt64
    let descriptorGeneration: UInt64
}

/// The result of authenticating one request.
public struct FirstPartyAuthenticatedRequest: Sendable, Equatable {
    /// The verified session identifier.
    public let sessionIdentifier: [UInt8]
    /// The verified, replay-checked sequence. The response MAC must use it.
    public let sequence: UInt64
    /// The exact body, verified by the request MAC.
    public let body: Data
}

// MARK: - The server

/// The daemon-side first-party authenticator: bounded challenge and session
/// tables, the pre-parse middleware, and response sealing.
///
/// An actor because the tables are mutable shared state reached from every
/// connection's task. Clock and randomness are INJECTED — a security test that
/// cannot control expiry or nonces is a test that cannot exercise expiry or
/// replay, and `Date()` inside an engine is forbidden by the project's
/// determinism rule besides.
public actor FirstPartyAuthServer {

    private let rootProvider: any FirstPartyRootProviding
    /// The active, MAC-verified descriptor this server authenticates against.
    private var descriptor: FirstPartyDescriptor
    private var descriptorDigest: [UInt8]

    /// Seconds since the Unix epoch. Injected.
    private let now: @Sendable () -> UInt64
    /// Cryptographic randomness. Injected.
    private let randomBytes: @Sendable (Int) -> [UInt8]

    private var challenges: [[UInt8]: FirstPartyChallenge] = [:]
    private var sessions: [[UInt8]: FirstPartySession] = [:]

    /// The dispatcher identity reported at `initialize` on this lane.
    ///
    /// COMPUTED from the descriptor currently in force, not captured at init.
    /// It was a `nonisolated let`, which meant `republish(descriptor:)` moved the
    /// descriptor and the generations underneath it while `initialize` went on
    /// advertising the old ones — the lane telling an authenticated client a
    /// generation pair that no longer authenticated anything. Being actor-
    /// isolated is what makes staleness impossible rather than merely unlikely.
    public var identity: FirstPartyServerIdentity {
        FirstPartyServerIdentity(verifiedDescriptor: descriptor, serverName: serverName)
    }

    /// The dispatcher name reported at `initialize`.
    private let serverName: String

    /// Build a first-party authenticator.
    ///
    /// - Parameters:
    ///   - rootProvider: Supplies the installation root. Never mints one.
    ///   - descriptor: The active descriptor. The caller must already have
    ///     verified its MAC.
    ///   - serverName: The dispatcher identity reported at `initialize`.
    ///   - now: Seconds since the Unix epoch.
    ///   - randomBytes: Cryptographic randomness.
    public init(
        rootProvider: any FirstPartyRootProviding,
        descriptor: FirstPartyDescriptor,
        serverName: String,
        now: @escaping @Sendable () -> UInt64,
        randomBytes: @escaping @Sendable (Int) -> [UInt8]
    ) {
        self.rootProvider = rootProvider
        self.descriptor = descriptor
        self.descriptorDigest = descriptor.digest()
        self.now = now
        self.randomBytes = randomBytes
        self.serverName = serverName
    }

    // MARK: Handshake

    /// Step 1. Verify the presented descriptor digest, allocate a nonce and an
    /// opaque session identifier, and record a single-use challenge.
    ///
    /// The digest is checked BEFORE anything is allocated: a peer that does not
    /// already know the active descriptor must not be able to consume a slot in
    /// a bounded table.
    ///
    /// - Returns: the server nonce, session identifier, timestamps, and the
    ///   server proof.
    public func challenge(
        clientNonce: [UInt8],
        descriptorDigest presented: [UInt8]
    ) async throws -> (
        sessionIdentifier: [UInt8], serverNonce: [UInt8],
        issuedAt: UInt64, idleExpiry: UInt64, absoluteExpiry: UInt64,
        serverProof: [UInt8]
    ) {
        guard clientNonce.count == FirstPartyAuthProtocol.nonceByteCount else {
            throw FirstPartyAuthError.malformedCredentials
        }
        // FIRST gate, before any key work: a peer that cannot name the active
        // descriptor must not be able to make this actor touch the Keychain.
        guard FirstPartyAuthProtocol.constantTimeEquals(presented, descriptorDigest) else {
            throw FirstPartyAuthError.descriptorMismatch
        }
        expireChallenges(asOf: now())
        guard challenges.count < FirstPartyAuthProtocol.maxChallenges else {
            throw FirstPartyAuthError.capacityExhausted
        }

        // SUSPENSION POINT. An actor is reentrant across `await`: other calls
        // run here. Nothing checked above still holds on the other side.
        let root = try await rootProvider.installationRoot()

        // SECOND gate, after the suspension, immediately before allocation.
        // Everything from here to the insert is synchronous, so this block is
        // atomic with respect to other calls on this actor.
        //
        // Re-checking capacity is not belt-and-braces: without it, N concurrent
        // unauthenticated callers all pass the pre-await guard, all suspend, and
        // all insert on resume — so a table documented as hard-bounded at 128
        // grows to N. The bound was enforced at the wrong side of an await.
        let current = now()
        expireChallenges(asOf: current)
        guard challenges.count < FirstPartyAuthProtocol.maxChallenges else {
            throw FirstPartyAuthError.capacityExhausted
        }
        // Re-validate against the LIVE descriptor. `republish(descriptor:)` can
        // land during the suspension, and a challenge minted against a digest
        // that is no longer current would produce a transcript no client could
        // ever reproduce — and would outlive the descriptor that justified it.
        guard FirstPartyAuthProtocol.constantTimeEquals(presented, descriptorDigest) else {
            throw FirstPartyAuthError.descriptorMismatch
        }

        // Snapshot the descriptor and its digest together, so the transcript is
        // built from one coherent record rather than from fields read across
        // several statements.
        let activeDescriptor = descriptor
        let activeDigest = descriptorDigest

        let serverNonce = randomBytes(FirstPartyAuthProtocol.nonceByteCount)
        let sessionIdentifier = randomBytes(FirstPartyAuthProtocol.sessionIdentifierByteCount)
        let idleExpiry = current + FirstPartyAuthProtocol.sessionIdleTimeout
        let absoluteExpiry = current + FirstPartyAuthProtocol.sessionAbsoluteTimeout

        let transcript = FirstPartyAuthProtocol.sessionTranscript(
            descriptorDigest: activeDigest,
            providerIdentifier: activeDescriptor.providerIdentifier,
            serviceIdentifier: activeDescriptor.serviceIdentifier,
            endpoint: activeDescriptor.endpoint,
            instanceIdentifier: activeDescriptor.instanceIdentifier,
            estateIdentifier: activeDescriptor.estateIdentifier,
            binaryVersion: activeDescriptor.binaryVersion,
            descriptorSchemaVersion: activeDescriptor.schemaVersion,
            contractRevision: activeDescriptor.contractRevision,
            mcpProtocolVersion: activeDescriptor.mcpProtocolVersion,
            credentialGeneration: activeDescriptor.credentialGeneration,
            descriptorGeneration: activeDescriptor.descriptorGeneration,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            sessionIdentifier: sessionIdentifier,
            issuedAt: current,
            idleExpiry: idleExpiry,
            absoluteExpiry: absoluteExpiry
        )

        challenges[sessionIdentifier] = FirstPartyChallenge(
            sessionIdentifier: sessionIdentifier,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            transcript: transcript,
            issuedAt: current,
            idleExpiry: idleExpiry,
            absoluteExpiry: absoluteExpiry,
            expiresAt: current + FirstPartyAuthProtocol.challengeLifetime
        )

        let authKey = FirstPartyAuthProtocol.authKey(
            installationRoot: root, descriptorDigest: activeDigest
        )
        return (
            sessionIdentifier, serverNonce, current, idleExpiry, absoluteExpiry,
            FirstPartyAuthProtocol.serverProof(authKey: authKey, transcript: transcript)
        )
    }

    /// Step 2. Verify the client proof and promote the challenge to a session.
    ///
    /// The challenge is consumed ATOMICALLY — removed before the proof is
    /// judged — so a failed or concurrent second attempt cannot reuse it.
    ///
    /// - Returns: the establishment proof, taken under the derived session key.
    public func establish(
        sessionIdentifier: [UInt8],
        clientProof presented: [UInt8]
    ) async throws -> [UInt8] {
        let current = now()
        expireChallenges(asOf: current)

        // Single-use: remove first, judge second.
        guard let challenge = challenges.removeValue(forKey: sessionIdentifier) else {
            throw FirstPartyAuthError.unknownChallenge
        }
        guard current <= challenge.expiresAt else { throw FirstPartyAuthError.unknownChallenge }

        let root = try await rootProvider.installationRoot()
        let authKey = FirstPartyAuthProtocol.authKey(
            installationRoot: root, descriptorDigest: descriptorDigest
        )
        let expected = FirstPartyAuthProtocol.clientProof(authKey: authKey, transcript: challenge.transcript)
        guard FirstPartyAuthProtocol.constantTimeEquals(expected, presented) else {
            throw FirstPartyAuthError.badClientProof
        }

        expireSessions(asOf: current)
        guard sessions.count < FirstPartyAuthProtocol.maxSessions else {
            throw FirstPartyAuthError.capacityExhausted
        }

        let sessionKey = FirstPartyAuthProtocol.sessionKey(
            installationRoot: root, transcript: challenge.transcript
        )
        sessions[sessionIdentifier] = FirstPartySession(
            sessionKey: sessionKey,
            issuedAt: challenge.issuedAt,
            absoluteExpiry: challenge.absoluteExpiry,
            idleExpiry: challenge.idleExpiry,
            replay: ReplayWindow(),
            credentialGeneration: descriptor.credentialGeneration,
            descriptorGeneration: descriptor.descriptorGeneration
        )
        return FirstPartyAuthProtocol.establishmentProof(
            sessionKey: sessionKey, transcript: challenge.transcript
        )
    }

    // MARK: Middleware

    /// Authenticate one request. Runs BEFORE any JSON parsing or dispatch.
    ///
    /// Order is deliberate and every step fails closed: shape first (method,
    /// target, content type), then credentials, then the session, then the MAC,
    /// and only then the replay window. The replay state is committed LAST —
    /// after the MAC verifies — because admitting a sequence on an unverified
    /// request would let an unauthenticated peer burn a legitimate client's
    /// sequence numbers and lock it out.
    ///
    /// - Returns: the verified sequence and body.
    public func authenticate(_ request: StrictHTTPRequest) throws -> FirstPartyAuthenticatedRequest {
        guard request.method == FirstPartyAuthProtocol.requestMethod else {
            throw FirstPartyAuthError.malformedRequest
        }
        // The target is compared whole, so a query string or fragment is a
        // different target and is refused rather than stripped.
        guard request.requestTarget == FirstPartyAuthProtocol.requestPath else {
            throw FirstPartyAuthError.malformedRequest
        }
        // Exactly one Content-Type, exactly the contracted media type, no
        // parameters. `application/json; charset=utf-8` is a different string
        // and a lane that normalizes it has two MAC inputs for one value.
        guard let contentType = request.singleValue(for: "content-type"),
              contentType.lowercased() == FirstPartyAuthProtocol.contentType else {
            throw FirstPartyAuthError.malformedRequest
        }

        // Each authentication header must appear exactly once. `singleValue`
        // returns nil for a duplicate, which is why the strict parser exists.
        guard let authorization = request.singleValue(for: FirstPartyAuthProtocol.authorizationHeader),
              let rawSequence = request.singleValue(for: FirstPartyAuthProtocol.sequenceHeader),
              let rawMAC = request.singleValue(for: FirstPartyAuthProtocol.requestMACHeader) else {
            throw FirstPartyAuthError.malformedCredentials
        }

        let scheme = FirstPartyAuthProtocol.authorizationScheme + " "
        guard authorization.hasPrefix(scheme) else { throw FirstPartyAuthError.malformedCredentials }
        guard let sessionIdentifier = FirstPartyAuthProtocol
            .base64URLDecode(String(authorization.dropFirst(scheme.count))),
            sessionIdentifier.count == FirstPartyAuthProtocol.sessionIdentifierByteCount else {
            throw FirstPartyAuthError.malformedCredentials
        }
        guard let sequence = FirstPartyAuthProtocol.parseSequenceHeader(rawSequence) else {
            throw FirstPartyAuthError.malformedCredentials
        }
        guard let presentedMAC = FirstPartyAuthProtocol.base64URLDecode(rawMAC),
              presentedMAC.count == FirstPartyAuthProtocol.macByteCount else {
            throw FirstPartyAuthError.malformedCredentials
        }

        let current = now()
        expireSessions(asOf: current)
        guard var session = sessions[sessionIdentifier] else {
            throw FirstPartyAuthError.unknownSession
        }
        guard current <= session.idleExpiry, current <= session.absoluteExpiry else {
            sessions.removeValue(forKey: sessionIdentifier)
            throw FirstPartyAuthError.sessionExpired
        }
        // A rotation or republication under this session invalidates it.
        guard session.credentialGeneration == rootProvider.credentialGeneration,
              session.descriptorGeneration == descriptor.descriptorGeneration else {
            sessions.removeValue(forKey: sessionIdentifier)
            throw FirstPartyAuthError.sessionExpired
        }
        guard !session.replay.isExhausted else {
            sessions.removeValue(forKey: sessionIdentifier)
            throw FirstPartyAuthError.sequenceExhausted
        }

        let expected = FirstPartyAuthProtocol.requestMAC(
            sessionKey: session.sessionKey,
            sessionIdentifier: sessionIdentifier,
            sequence: sequence,
            method: request.method,
            path: request.requestTarget,
            contentType: FirstPartyAuthProtocol.contentType,
            body: request.body
        )
        guard FirstPartyAuthProtocol.constantTimeEquals(expected, presentedMAC) else {
            throw FirstPartyAuthError.badRequestMAC
        }

        // MAC verified — only now is the sequence allowed to change state.
        guard session.replay.admit(sequence) else {
            throw FirstPartyAuthError.replayedSequence
        }
        // Only an ACCEPTED request refreshes the idle deadline.
        session.idleExpiry = current + FirstPartyAuthProtocol.sessionIdleTimeout
        sessions[sessionIdentifier] = session

        return FirstPartyAuthenticatedRequest(
            sessionIdentifier: sessionIdentifier, sequence: sequence, body: request.body
        )
    }

    /// Compute the response MAC for an authenticated exchange.
    ///
    /// Every response on this lane is authenticated, including empty 204
    /// acknowledgements and error bodies emitted after authenticated dispatch.
    /// An unauthenticated "nothing happened" is as useful to an attacker as a
    /// forged result.
    public func sealResponse(
        sessionIdentifier: [UInt8],
        sequence: UInt64,
        status: UInt16,
        contentType: String,
        body: Data
    ) -> [UInt8]? {
        guard let session = sessions[sessionIdentifier] else { return nil }
        return FirstPartyAuthProtocol.responseMAC(
            sessionKey: session.sessionKey,
            sessionIdentifier: sessionIdentifier,
            sequence: sequence,
            status: status,
            contentType: contentType,
            body: body
        )
    }

    // MARK: Lifecycle

    /// Drop every session. Called on restart, estate close, or provider handover.
    public func revokeAllSessions() {
        sessions.removeAll()
        challenges.removeAll()
    }

    /// Replace the active descriptor.
    ///
    /// Outstanding CHALLENGES are dropped immediately: each one's transcript is
    /// bound to the previous descriptor digest, so none of them could ever be
    /// completed against the new one.
    ///
    /// Live SESSIONS are deliberately NOT cleared here. They are revoked lazily,
    /// by the generation comparison in `authenticate`, on their next request.
    /// One mechanism rather than two: if republication eagerly cleared the table,
    /// the per-request check would be unreachable in practice and would rot into
    /// a branch nothing exercises — while still being the only thing standing
    /// between a session and a descriptor it was never minted against, on any
    /// path that changes generations without coming through here.
    ///
    /// - Parameter descriptor: The new active descriptor. The caller must
    ///   already have verified its MAC.
    public func republish(descriptor: FirstPartyDescriptor) {
        self.descriptor = descriptor
        self.descriptorDigest = descriptor.digest()
        challenges.removeAll()
    }

    /// Live session count, for tests and diagnostics. Never a secret.
    public var liveSessionCount: Int { sessions.count }

    /// Outstanding challenge count, for tests and diagnostics.
    public var liveChallengeCount: Int { challenges.count }

    /// Remove challenges past their lifetime. Called before every capacity
    /// judgement so a full table of dead entries never refuses a live peer.
    private func expireChallenges(asOf current: UInt64) {
        challenges = challenges.filter { current <= $0.value.expiresAt }
    }

    /// Remove sessions past either deadline, on the same schedule and for the
    /// same reason.
    private func expireSessions(asOf current: UInt64) {
        sessions = sessions.filter { current <= $0.value.idleExpiry && current <= $0.value.absoluteExpiry }
    }
}
