import AriaMCPWire
import Foundation

// MARK: - First-party daemon authenticator (client half)
//
// MACD-1 left readiness bound by ASSERTION: the authenticator stated it had
// authenticated, and the daemon stated its own identifiers over a loopback
// connection the client could not cryptographically attribute to any particular
// peer. Anything able to answer on the endpoint could therefore claim whatever
// the descriptor named. This file closes that gap.
//
// The order of operations is the security argument, so it is spelled out rather
// than left to the reader:
//
//   1. Parse and bound the descriptor. Verify its MAC under a key derived from
//      the installation root. NO NETWORK TRAFFIC HAPPENS BEFORE THIS. A
//      descriptor is attacker-controlled input until its MAC verifies, and that
//      includes the endpoint field — dialing first would mean trusting an
//      unverified address to tell us where to send a credential.
//   2. Judge compatibility, fail-closed, including the exact endpoint and the
//      supported version range.
//   3. Challenge: send a nonce and the descriptor digest; verify the server's
//      proof before answering it.
//   4. Establish: send the client proof; verify the establishment proof under
//      the derived session key before any transport exists.
//   5. Only then construct an `AuthenticatedDaemonTransport` that stamps a
//      per-request MAC and verifies every response MAC before parsing.
//
// DARK INFRASTRUCTURE. Nothing in production routing reaches this type. It is
// constructed only by tests until MACD-2c supplies a signed provider and a
// published descriptor, and MACD-3 performs the atomic routing conversion.

/// Why a first-party authentication attempt failed.
///
/// Deliberately coarse at the boundary: the cases name which STAGE failed, never
/// which byte differed. A finer-grained error is an oracle.
public enum FirstPartyAuthenticationError: Error, Equatable, Sendable {

    /// The descriptor's MAC did not verify under the installation root.
    case descriptorNotAuthentic

    /// The descriptor was authentic but this client does not contract with it.
    case incompatibleDescriptor(DaemonCompatibility)

    /// The installation root could not be obtained. Fail-closed: never treated
    /// as "no authentication required".
    case rootUnavailable

    /// The challenge step failed, or the server's proof did not verify.
    case challengeFailed

    /// The establish step failed, or the establishment proof did not verify.
    case establishmentFailed

    /// The daemon's authenticated `serverInfo` disagreed with the descriptor.
    case identityMismatch
}

/// Supplies the installation root to the client half.
///
/// The app reads the same data-protection Keychain item the daemon does, in the
/// same fully expanded access group — that shared custody is exactly what
/// MACD-2a proved. Injected so tests can drive the handshake without
/// entitlements.
public protocol FirstPartyInstallationRootProviding: Sendable {
    func installationRoot() async throws -> [UInt8]
}

/// Lets a cancellation handler unblock a worker parked in a blocking socket read.
///
/// A blocking `read` does not observe Swift task cancellation, so cancelling the
/// surrounding task would otherwise leave the worker parked until the deadline.
/// The handler calls `shutdownNow()`, which `shutdown()`s the registered
/// descriptor and makes the pending read return immediately.
///
/// The worker is the ONLY closer, and it unregisters before closing. That
/// ordering is what prevents the classic fd-reuse race: a cancellation arriving
/// after the close cannot shut down a descriptor number the kernel has since
/// handed to something else.
/// `internal`, not private, solely so the cancel-before-register latch can be
/// unit-tested directly. A Task-level race test cannot pin that ordering: it
/// also passes when cancellation happens to land after registration.
final class LoopbackSocketOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    /// Latched under the same lock as `descriptor`.
    ///
    /// Without it there is a window: cancellation can fire BEFORE the worker
    /// registers, `shutdownNow` sees -1 and does nothing, and the worker then
    /// registers and runs the whole exchange for a task that is already
    /// cancelled. Latching lets `register` refuse.
    private var cancelled = false

    /// Register the descriptor, or refuse because cancellation already landed.
    ///
    /// - Returns: `false` when the exchange was cancelled before it began; the
    ///   worker must close and throw without connecting.
    func register(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        descriptor = fd
        return true
    }

    /// Admit work after `connect`, or refuse when cancellation won the race.
    ///
    /// `shutdown()` on a registered but not-yet-connected socket can return
    /// `ENOTCONN` without preventing a later `connect`. This second gate closes
    /// that interval. Its lock ordering gives exactly two outcomes: either
    /// cancellation was already latched and the worker closes immediately, or
    /// this gate wins and a later cancellation sees a connected descriptor that
    /// `shutdown()` can reliably unblock.
    func connectionEstablished(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard descriptor == fd, !cancelled else { return false }
        return true
    }

    func unregister() {
        lock.lock(); defer { lock.unlock() }
        descriptor = -1
    }

    func shutdownNow() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR)
    }
}

/// Establishes an authenticated session with a resident daemon and produces a
/// transport that keeps it authenticated.
public struct FirstPartyDaemonAuthenticator: Sendable {

    /// Performs one handshake HTTP exchange.
    ///
    /// Returns the raw status, content type, and body — the authenticator does
    /// its own interpretation, because the handshake responses are not JSON-RPC
    /// and must not go through a JSON-RPC decoder.
    ///
    /// **INTERNAL test seam, not a configuration point.** Production always uses
    /// `pinnedLoopbackExchange`, which is what actually enforces the
    /// no-redirect, exact-endpoint, and response-size guarantees; an injected
    /// closure enforces none of them.
    ///
    /// Deliberately `internal`: a public seam is a public bypass, and a shipping
    /// caller outside this module must have no way to construct an authenticator
    /// that skips the pinned path. Tests reach it through `@testable import`.
    typealias HandshakeExchange = @Sendable (
        _ url: URL, _ body: Data
    ) async throws -> (status: Int, contentType: String, body: Data)

    private let rootProvider: any FirstPartyInstallationRootProviding
    private let policy: DaemonCompatibilityPolicy
    private let exchange: HandshakeExchange
    private let randomBytes: @Sendable (Int) -> [UInt8]

    /// Build an authenticator that talks to the real loopback daemon.
    ///
    /// This is the ONLY initializer production uses. It wires
    /// `pinnedLoopbackExchange`, so the no-redirect and exact-endpoint
    /// guarantees are properties of the type rather than of whatever a caller
    /// remembered to pass.
    ///
    /// - Parameters:
    ///   - rootProvider: Reads the shared installation root.
    ///   - policy: The compatibility gate. Defaults to the shipped contract.
    ///   - randomBytes: Client nonce source. Injected for determinism in tests.
    public init(
        rootProvider: any FirstPartyInstallationRootProviding,
        policy: DaemonCompatibilityPolicy = .current,
        randomBytes: @escaping @Sendable (Int) -> [UInt8] = Self.secureRandomBytes
    ) {
        self.rootProvider = rootProvider
        self.policy = policy
        self.randomBytes = randomBytes
        self.exchange = Self.pinnedLoopbackExchange
    }

    /// Build an authenticator with an injected handshake exchange.
    ///
    /// **INTERNAL, tests only.** An injected exchange bypasses
    /// `pinnedLoopbackExchange` and with it the redirect refusal, the endpoint
    /// pin, and the response cap. It is `internal` rather than public precisely
    /// so that no shipping caller can reach it: the module's public surface
    /// offers exactly one way to build an authenticator, and that way is pinned.
    init(
        rootProvider: any FirstPartyInstallationRootProviding,
        policy: DaemonCompatibilityPolicy = .current,
        randomBytes: @escaping @Sendable (Int) -> [UInt8] = Self.secureRandomBytes,
        unsafeTestExchange: @escaping HandshakeExchange
    ) {
        self.rootProvider = rootProvider
        self.policy = policy
        self.randomBytes = randomBytes
        self.exchange = unsafeTestExchange
    }

    /// Cryptographic randomness for the client nonce.
    public static let secureRandomBytes: @Sendable (Int) -> [UInt8] = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes
    }

    /// The production handshake exchange: one POST, one response, one endpoint.
    ///
    /// Two guarantees live here rather than in the caller, because a guarantee a
    /// caller can forget is not a guarantee:
    ///
    /// 1. **The URL is re-pinned.** Only the two contracted handshake URLs are
    ///    dialed; anything else fails before a socket is opened. The
    ///    authenticator already builds them from protocol constants, so this is a
    ///    second, independent check of the same invariant.
    /// 2. **The transfer is bounded and head-gated** — see
    ///    `boundedNonRedirectingPost`, which reads the status line and headers
    ///    before deciding whether to read a body at all.
    ///
    /// Redirects are not "refused" so much as unrepresentable: this reads exactly
    /// one response and follows nothing.
    static let pinnedLoopbackExchange: HandshakeExchange = { url, body in
        // The pin is applied HERE, before any socket is opened, and the bounded
        // transfer below is a separate step. Splitting them is what lets the
        // transfer's cap and cancellation be tested against a real socket on an
        // ephemeral port: the contracted port is frequently held by an actual
        // resident daemon, and a test that has to bind 4242 is a test that fails
        // on any machine where the product is running.
        let permitted = [
            FirstPartyAuthProtocol.challengePath,
            FirstPartyAuthProtocol.establishPath,
        ].map { "http://127.0.0.1:4242" + $0 }
        guard permitted.contains(url.absoluteString) else {
            throw FirstPartyAuthenticationError.challengeFailed
        }
        return try await boundedNonRedirectingPost(url: url, body: body)
    }

    /// One POST to the loopback daemon: one response, no redirects ever, the
    /// head judged before a single body byte is read, and a hard body cap.
    ///
    /// `internal`, and the URL pin is the CALLER's responsibility —
    /// `pinnedLoopbackExchange` is the only production caller and applies it
    /// first. Nothing public reaches this.
    ///
    /// WHY THIS IS A RAW SOCKET AND NOT `URLSession`.
    ///
    /// The requirement is that an unacceptable response — a redirect, a wrong
    /// status, a wrong media type — costs the peer its body. `URLSession` cannot
    /// deliver that for redirects: it consumes a 3xx body as part of redirect
    /// processing, BEFORE `willPerformHTTPRedirection` and before any
    /// response-disposition callback that could cancel. Both were tried and both
    /// measured the same: a paced 64 KiB 3xx body arrived in full, 65,536 of
    /// 65,536, whether the status was judged after `bytes(for:)` or inside
    /// `didReceive response:`. The transfer had already happened by the time any
    /// client code could object.
    ///
    /// This lane does not need what `URLSession` provides. It is loopback-only,
    /// plaintext by contract, one exact endpoint, one request, one response,
    /// no cookies, no cache, no credentials, no redirects wanted, and payloads of
    /// a few hundred bytes. Reading the status line and headers before deciding
    /// whether to read a body is trivial over a socket and impossible above
    /// `URLSession`, so the socket is the simpler tool as well as the correct one.
    ///
    /// A redirect is not "refused" here so much as unrepresentable: this reads
    /// exactly one response and follows nothing.
    static func boundedNonRedirectingPost(
        url: URL, body: Data, timeout: TimeInterval = 30,
        afterSocketRegistration: (@Sendable () -> Void)? = nil
    ) async throws -> (status: Int, contentType: String, body: Data) {
        guard let host = url.host, host == "127.0.0.1", let port = url.port else {
            throw FirstPartyAuthenticationError.challengeFailed
        }
        let target = url.path.isEmpty ? "/" : url.path

        // ONE ABSOLUTE DEADLINE for the whole exchange.
        //
        // `SO_RCVTIMEO` alone is a PER-READ timeout, and the head is read a byte
        // at a time — so a peer dripping one byte every 29 seconds satisfies
        // every individual read forever and pins a GCD worker indefinitely. The
        // bound has to be on the exchange, not on any single syscall, so each
        // read's timeout is set to what remains of this deadline and expiry is
        // checked between reads.
        // Finite and positive before the conversion: `UInt64(_:)` traps on NaN
        // and on infinity, and this value is a parameter.
        guard timeout.isFinite, timeout > 0 else {
            throw FirstPartyAuthenticationError.challengeFailed
        }
        let budgetNanoseconds = min(timeout, 3600) * 1_000_000_000
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(budgetNanoseconds)

        // A blocking read does not observe Swift task cancellation. The owner
        // lets the cancellation handler `shutdown()` the socket that is
        // currently registered, which unblocks the worker immediately. Only the
        // worker ever CLOSES the descriptor, and it unregisters before doing so,
        // so a cancellation arriving late cannot shut down a descriptor the
        // kernel has since reissued to someone else.
        let owner = LoopbackSocketOwner()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<(Int, String, Data), Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try performLoopbackExchange(
                            host: host, port: port, target: target,
                            body: body, deadline: deadline, owner: owner,
                            afterSocketRegistration: afterSocketRegistration
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            owner.shutdownNow()
        }
    }

    /// The blocking half of `boundedNonRedirectingPost`.
    private static func performLoopbackExchange(
        host: String, port: Int, target: String, body: Data,
        deadline: UInt64, owner: LoopbackSocketOwner,
        afterSocketRegistration: (@Sendable () -> Void)?
    ) throws -> (status: Int, contentType: String, body: Data) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FirstPartyAuthenticationError.challengeFailed }
        // Refused when cancellation already landed: close and throw before
        // connecting, rather than running an exchange nobody is waiting for.
        guard owner.register(fd) else {
            close(fd)
            throw FirstPartyAuthenticationError.challengeFailed
        }
        // Internal deterministic race seam. Production passes nil; the focused
        // regression parks here so cancellation lands while the descriptor is
        // registered but still unconnected.
        afterSocketRegistration?()
        // Closed on EVERY exit, including the throws below. That close is what
        // costs a misbehaving peer its body: it happens while the peer is still
        // writing, before this code has read any of it. Unregistering first
        // keeps this the sole closer.
        defer {
            owner.unregister()
            close(fd)
        }

        /// Remaining time, or nil once the exchange deadline has passed.
        func remaining() -> timeval? {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return nil }
            let left = deadline - now
            // Under a microsecond counts as EXPIRED. Truncating it would yield
            // `timeval(0, 0)`, which does not mean "expire immediately" — it
            // means "no timeout at all", reinstating the indefinite blocking
            // read this whole deadline exists to prevent.
            guard left >= 1_000 else { return nil }
            let seconds = Int(left / 1_000_000_000)
            // Clamp the sub-second remainder to at least 1 µs for the same
            // reason: a positive remainder must never arm as zero.
            let microseconds = max(Int32((left % 1_000_000_000) / 1_000), seconds == 0 ? 1 : 0)
            return timeval(tv_sec: seconds, tv_usec: microseconds)
        }
        /// Re-arm both socket timeouts to what is LEFT of the exchange deadline.
        func armTimeouts() throws {
            guard var left = remaining() else {
                throw FirstPartyAuthenticationError.challengeFailed
            }
            // BOTH must install. A failed setsockopt would leave the socket
            // with no timeout at all, reintroducing the unbounded blocking read
            // the absolute deadline exists to prevent — the deadline checks
            // between reads cannot help while a single read is parked forever.
            let receiveArmed = setsockopt(
                fd, SOL_SOCKET, SO_RCVTIMEO, &left, socklen_t(MemoryLayout<timeval>.size)
            )
            let sendArmed = setsockopt(
                fd, SOL_SOCKET, SO_SNDTIMEO, &left, socklen_t(MemoryLayout<timeval>.size)
            )
            guard receiveArmed == 0, sendArmed == 0 else {
                throw FirstPartyAuthenticationError.challengeFailed
            }
        }
        try armTimeouts()
        // A peer that vanishes mid-write must yield an error, not a signal.
        var noSigPipe: Int32 = 1
        guard setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            // Continuing would make the `write` calls below process-fatal on a
            // disappearing peer, so inability to install the protection is an
            // exchange failure rather than a best-effort condition.
            throw FirstPartyAuthenticationError.challengeFailed
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw FirstPartyAuthenticationError.challengeFailed }
        // `shutdown()` during the unconnected interval can fail with ENOTCONN
        // and does not guarantee that this successful connect was interrupted.
        // Synchronize with the cancellation latch before sending credentials.
        guard owner.connectionEstablished(fd) else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        var request = "\(FirstPartyAuthProtocol.requestMethod) \(target) HTTP/1.1\r\n"
        request += "Host: \(host):\(port)\r\n"
        request += "Content-Type: \(FirstPartyAuthProtocol.contentType)\r\n"
        request += "Content-Length: \(body.count)\r\n"
        request += "Connection: close\r\n\r\n"
        guard writeAll(fd, Data(request.utf8)), writeAll(fd, body) else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        // Read ONLY the head, ONE BYTE AT A TIME.
        //
        // A chunked read would pull body bytes into the header buffer, so the
        // "we have not read any body" claim would be false the moment a peer
        // sent headers and body in one segment. Byte-at-a-time costs nothing on
        // a loopback handshake of a few hundred bytes and makes the boundary
        // exact: when the terminator is seen, precisely the head has been
        // consumed and not one byte more.
        let terminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        var head = [UInt8]()
        while true {
            // Cap enforced AT the terminator search, so a peer cannot stream
            // headers forever.
            if head.count >= FirstPartyAuthProtocol.handshakeMaxBodyBytes {
                throw FirstPartyAuthenticationError.challengeFailed
            }
            // Re-armed every byte, always against the SAME absolute deadline,
            // so a drip peer runs the exchange out of time rather than
            // refreshing a per-read window forever.
            try armTimeouts()
            var byte: UInt8 = 0
            let n = read(fd, &byte, 1)
            guard n == 1 else { throw FirstPartyAuthenticationError.challengeFailed }
            head.append(byte)
            if head.count >= 4, Array(head.suffix(4)) == terminator { break }
        }
        guard let headText = String(bytes: head.dropLast(4), encoding: .utf8),
              headText.allSatisfy({ $0.isASCII }) else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        let lines = headText.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw FirstPartyAuthenticationError.challengeFailed }

        // Exactly `HTTP/1.1 <3 digits> [reason]`. A lenient status parse is how
        // a client ends up agreeing with a peer about a response neither of them
        // described the same way.
        let statusTokens = statusLine.split(separator: " ", omittingEmptySubsequences: false)
        guard statusTokens.count >= 2, statusTokens[0] == "HTTP/1.1" else {
            throw FirstPartyAuthenticationError.challengeFailed
        }
        let statusToken = statusTokens[1]
        guard statusToken.count == 3, statusToken.allSatisfy({ $0.isASCII && $0.isNumber }),
              let status = Int(statusToken) else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        // Parsed duplicate-preserving so that duplicates can be REFUSED below
        // rather than silently resolved last-wins — the same discipline the
        // server's strict request parser applies, for the same reason.
        var fields: [(name: String, value: String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { continue }
            // No obsolete line folding.
            guard let first = line.first, first != " ", first != "\t" else {
                throw FirstPartyAuthenticationError.challengeFailed
            }
            guard let colon = line.firstIndex(of: ":") else {
                throw FirstPartyAuthenticationError.challengeFailed
            }
            let rawName = String(line[line.startIndex..<colon])
            // No whitespace between field name and colon, and token characters only.
            guard !rawName.isEmpty,
                  rawName.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) })
            else { throw FirstPartyAuthenticationError.challengeFailed }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            fields.append((rawName.lowercased(), value))
        }

        // ANY duplicated field name is refused, not just the two this code
        // reads. Narrowing it to Content-Type and Content-Length would leave the
        // comment below overclaiming, and a response whose meaning depends on
        // which copy of a field a parser happens to keep is ambiguous whatever
        // the field is.
        var seen = Set<String>()
        for field in fields {
            guard seen.insert(field.name).inserted else {
                throw FirstPartyAuthenticationError.challengeFailed
            }
        }
        func singleValue(_ name: String) -> String? {
            fields.first { $0.name == name }?.value
        }

        // Transfer-Encoding is not spoken on this lane; accepting it alongside
        // Content-Length is the request-smuggling shape.
        guard !fields.contains(where: { $0.name == "transfer-encoding" }) else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        // THE HEAD GATE. Nothing below has read a body byte, so a throw here
        // closes the connection while the peer is still writing. A 3xx lands
        // here like any other unacceptable status: this reads one response and
        // follows nothing, so there is no redirect handling to be pre-empted by.
        guard let contentType = singleValue("content-type") else {
            throw FirstPartyAuthenticationError.challengeFailed
        }
        guard status == 200, FirstPartyAuthProtocol.isExactContentType(contentType) else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        // Exactly one strict-decimal Content-Length, within the cap.
        guard let rawLength = singleValue("content-length"),
              !rawLength.isEmpty,
              rawLength.allSatisfy({ $0.isASCII && $0.isNumber }),
              rawLength.count == 1 || rawLength.first != "0",
              let declared = Int(rawLength),
              declared <= FirstPartyAuthProtocol.handshakeMaxBodyBytes else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        // Only now is a body read, and only exactly as many bytes as declared.
        var responseBody = Data()
        responseBody.reserveCapacity(declared)
        while responseBody.count < declared {
            try armTimeouts()
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, min(chunk.count, declared - responseBody.count))
            guard n > 0 else { throw FirstPartyAuthenticationError.challengeFailed }
            responseBody.append(contentsOf: chunk[0..<n])
        }
        return (status, contentType, responseBody)
    }

    /// Write every byte or report failure.
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { raw in
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }

    /// Convert a client descriptor into the canonical protocol form.
    ///
    /// The two types exist separately on purpose: `DaemonDescriptor` is the
    /// app's decoded view with a `URL` and a `Set` of capabilities, while
    /// `FirstPartyDescriptor` is the canonicalization input whose field types
    /// are fixed by the wire contract. Converting explicitly is what keeps a
    /// `Set`'s iteration order from ever reaching a MAC input.
    public static func canonical(_ descriptor: DaemonDescriptor) -> FirstPartyDescriptor {
        FirstPartyDescriptor(
            schemaVersion: descriptor.schemaVersion,
            providerIdentifier: descriptor.providerIdentifier,
            serviceIdentifier: descriptor.serviceIdentifier,
            endpoint: descriptor.endpoint.absoluteString,
            authProtocol: descriptor.authProtocol,
            authKeyIdentifier: descriptor.authKeyIdentifier,
            publishedAt: descriptor.publishedAt,
            instanceIdentifier: descriptor.instanceIdentifier,
            estateIdentifier: descriptor.estateIdentifier,
            binaryVersion: descriptor.binaryVersion,
            contractRevision: descriptor.contractRevision,
            mcpProtocolVersion: descriptor.mcpProtocolVersion,
            capabilities: descriptor.capabilities.map(\.rawValue).sorted(),
            credentialGeneration: descriptor.credentialGeneration,
            descriptorGeneration: descriptor.descriptorGeneration,
            descriptorMAC: descriptor.descriptorMAC
        )
    }

    /// Run the full handshake and return a transport that stays authenticated.
    ///
    /// - Parameter descriptor: The published descriptor. Untrusted on entry.
    /// - Returns: An authenticated transport.
    public func authenticate(_ descriptor: DaemonDescriptor) async throws -> AuthenticatedDaemonTransport {
        // GATE 1 — authenticity, then compatibility. Both before any traffic.
        let root: [UInt8]
        do {
            root = try await rootProvider.installationRoot()
        } catch {
            // A missing or unreadable root is never "no authentication needed".
            throw FirstPartyAuthenticationError.rootUnavailable
        }

        // Bounds BEFORE canonicalization. `schemaVersion` and `contractRevision`
        // are `Int` on a decoded record but unsigned on the wire, and this runs
        // before the MAC verifies — so a descriptor carrying a negative one is
        // attacker-supplied input reaching an integer conversion. It has no
        // canonical encoding, so it is refused here rather than encoded.
        let canonical = Self.canonical(descriptor)
        guard canonical.hasEncodableFieldWidths else {
            throw FirstPartyAuthenticationError.descriptorNotAuthentic
        }
        guard canonical.verifyMAC(installationRoot: root) else {
            throw FirstPartyAuthenticationError.descriptorNotAuthentic
        }
        let verdict = policy.evaluate(descriptor)
        guard verdict == .compatible else {
            throw FirstPartyAuthenticationError.incompatibleDescriptor(verdict)
        }

        // The endpoint is only now safe to use, because only now has the record
        // naming it been proved authentic and contracted-with. The handshake
        // URLs are built from the PROTOCOL CONSTANTS rather than from the
        // descriptor, so even an authentic descriptor cannot redirect the
        // handshake somewhere the contract does not name.
        let origin = "http://127.0.0.1:4242"
        guard let endpoint = URL(string: FirstPartyAuthProtocol.endpoint),
              let challengeURL = URL(string: origin + FirstPartyAuthProtocol.challengePath),
              let establishURL = URL(string: origin + FirstPartyAuthProtocol.establishPath) else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        let digest = canonical.digest()
        let clientNonce = randomBytes(FirstPartyAuthProtocol.nonceByteCount)

        // GATE 2 — challenge. The server's proof is verified before the client
        // answers it, so a peer that cannot produce a proof never learns
        // anything it could replay.
        let challengePayload: [String: Any] = [
            "clientNonce": FirstPartyAuthProtocol.base64URLEncode(clientNonce),
            "descriptorDigest": FirstPartyAuthProtocol.base64URLEncode(digest),
        ]
        guard let challengeBody = try? JSONSerialization.data(
            withJSONObject: challengePayload, options: [.sortedKeys]
        ) else { throw FirstPartyAuthenticationError.challengeFailed }

        let challenge: (status: Int, contentType: String, body: Data)
        do {
            challenge = try await exchange(challengeURL, challengeBody)
        } catch {
            throw FirstPartyAuthenticationError.challengeFailed
        }
        // The content type is CHECKED, not merely observed. A peer that answers
        // with something other than JSON has not implemented this protocol, and
        // guessing at its bytes is how a parser ends up interpreting a payload
        // the sender never meant as one.
        guard challenge.status == 200,
              FirstPartyAuthProtocol.isExactContentType(challenge.contentType),
              let issued = FirstPartyAuthProtocol.strictJSONObject(challenge.body, expected: [
                  "sessionIdentifier", "serverNonce", "serverProof",
                  "issuedAt", "idleExpiry", "absoluteExpiry",
              ]),
              let sessionRaw = issued["sessionIdentifier"] as? String,
              let serverNonceRaw = issued["serverNonce"] as? String,
              let serverProofRaw = issued["serverProof"] as? String,
              // Total decoding: see `exactUInt64`. These three values are read
              // BEFORE the server proof can be computed, so they are the most
              // exposed input in the whole handshake.
              let issuedAt = FirstPartyAuthProtocol.exactUInt64(issued["issuedAt"]),
              let idleExpiry = FirstPartyAuthProtocol.exactUInt64(issued["idleExpiry"]),
              let absoluteExpiry = FirstPartyAuthProtocol.exactUInt64(issued["absoluteExpiry"]),
              let sessionIdentifier = FirstPartyAuthProtocol.base64URLDecode(sessionRaw),
              let serverNonce = FirstPartyAuthProtocol.base64URLDecode(serverNonceRaw),
              let serverProof = FirstPartyAuthProtocol.base64URLDecode(serverProofRaw),
              sessionIdentifier.count == FirstPartyAuthProtocol.sessionIdentifierByteCount,
              serverNonce.count == FirstPartyAuthProtocol.nonceByteCount,
              serverProof.count == FirstPartyAuthProtocol.macByteCount,
              // Ordering is part of the shape: a peer that claims an idle
              // deadline before issuance, or an absolute deadline before the
              // idle one, is describing a session that cannot exist.
              issuedAt <= idleExpiry, idleExpiry <= absoluteExpiry else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        let transcript = FirstPartyAuthProtocol.sessionTranscript(
            descriptorDigest: digest,
            providerIdentifier: canonical.providerIdentifier,
            serviceIdentifier: canonical.serviceIdentifier,
            endpoint: canonical.endpoint,
            instanceIdentifier: canonical.instanceIdentifier,
            estateIdentifier: canonical.estateIdentifier,
            binaryVersion: canonical.binaryVersion,
            descriptorSchemaVersion: canonical.schemaVersion,
            contractRevision: canonical.contractRevision,
            mcpProtocolVersion: canonical.mcpProtocolVersion,
            credentialGeneration: canonical.credentialGeneration,
            descriptorGeneration: canonical.descriptorGeneration,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            sessionIdentifier: sessionIdentifier,
            issuedAt: issuedAt,
            idleExpiry: idleExpiry,
            absoluteExpiry: absoluteExpiry
        )
        let authKey = FirstPartyAuthProtocol.authKey(installationRoot: root, descriptorDigest: digest)
        guard FirstPartyAuthProtocol.constantTimeEquals(
            FirstPartyAuthProtocol.serverProof(authKey: authKey, transcript: transcript), serverProof
        ) else {
            throw FirstPartyAuthenticationError.challengeFailed
        }

        // GATE 3 — establish. The establishment proof is taken under the SESSION
        // key, so verifying it is how this client learns the peer derived the
        // same key it did. No transport exists before that.
        let clientProof = FirstPartyAuthProtocol.clientProof(authKey: authKey, transcript: transcript)
        let establishPayload: [String: Any] = [
            "sessionIdentifier": FirstPartyAuthProtocol.base64URLEncode(sessionIdentifier),
            "clientProof": FirstPartyAuthProtocol.base64URLEncode(clientProof),
        ]
        guard let establishBody = try? JSONSerialization.data(
            withJSONObject: establishPayload, options: [.sortedKeys]
        ) else { throw FirstPartyAuthenticationError.establishmentFailed }

        let established: (status: Int, contentType: String, body: Data)
        do {
            established = try await exchange(establishURL, establishBody)
        } catch {
            throw FirstPartyAuthenticationError.establishmentFailed
        }
        guard established.status == 200,
              FirstPartyAuthProtocol.isExactContentType(established.contentType),
              let object = FirstPartyAuthProtocol.strictJSONObject(
                  established.body, expected: ["establishmentProof"]
              ),
              let proofRaw = object["establishmentProof"] as? String,
              let establishmentProof = FirstPartyAuthProtocol.base64URLDecode(proofRaw),
              establishmentProof.count == FirstPartyAuthProtocol.macByteCount else {
            throw FirstPartyAuthenticationError.establishmentFailed
        }

        let sessionKey = FirstPartyAuthProtocol.sessionKey(
            installationRoot: root, transcript: transcript
        )
        guard FirstPartyAuthProtocol.constantTimeEquals(
            FirstPartyAuthProtocol.establishmentProof(sessionKey: sessionKey, transcript: transcript),
            establishmentProof
        ) else {
            throw FirstPartyAuthenticationError.establishmentFailed
        }

        // GATE 4 — a transport, at last.
        let sequencer = FirstPartySequencer()
        let transport = HTTPTransport(
            endpoint: endpoint,
            authorize: { request in
                // Header-only, as the seam requires. The sequence is taken here
                // so it advances exactly once per outbound request.
                guard let sequence = await sequencer.next() else {
                    // Exhausted. Fail the request rather than wrap — see
                    // `FirstPartySequencer`.
                    throw FirstPartyAuthenticationError.establishmentFailed
                }
                var authorized = request
                let mac = FirstPartyAuthProtocol.requestMAC(
                    sessionKey: sessionKey,
                    sessionIdentifier: sessionIdentifier,
                    sequence: sequence,
                    method: FirstPartyAuthProtocol.requestMethod,
                    path: FirstPartyAuthProtocol.requestPath,
                    contentType: FirstPartyAuthProtocol.contentType,
                    body: request.httpBody ?? Data()
                )
                authorized.setValue(
                    "\(FirstPartyAuthProtocol.authorizationScheme) "
                        + FirstPartyAuthProtocol.base64URLEncode(sessionIdentifier),
                    forHTTPHeaderField: "Authorization"
                )
                authorized.setValue(
                    FirstPartyAuthProtocol.formatSequenceHeader(sequence),
                    forHTTPHeaderField: FirstPartyAuthProtocol.sequenceHeaderWireName
                )
                authorized.setValue(
                    FirstPartyAuthProtocol.base64URLEncode(mac),
                    forHTTPHeaderField: FirstPartyAuthProtocol.requestMACHeaderWireName
                )
                return authorized
            },
            verifyResponse: { sentRequest, status, contentType, headers, body in
                // Runs on RAW bytes before any parse.
                //
                // The sequence is read back off the request THIS response is
                // answering, not from the sequencer. Asking the sequencer for
                // "the current sequence" would return whichever request most
                // recently started: with two requests in flight, the response to
                // the first would be checked against the second's sequence and
                // rejected despite being authentic. Reading it off the request
                // makes the binding structural instead of timing-dependent.
                guard let rawSequence = sentRequest.value(
                    forHTTPHeaderField: FirstPartyAuthProtocol.sequenceHeaderWireName
                ), let sequence = FirstPartyAuthProtocol.parseSequenceHeader(rawSequence) else {
                    throw FirstPartyAuthenticationError.identityMismatch
                }
                // A missing response MAC is a failure, not a permissible
                // omission: an unauthenticated answer is exactly what this lane
                // exists to refuse.
                guard let raw = headers[FirstPartyAuthProtocol.responseMACHeader],
                      let presented = FirstPartyAuthProtocol.base64URLDecode(raw),
                      presented.count == FirstPartyAuthProtocol.macByteCount else {
                    throw FirstPartyAuthenticationError.identityMismatch
                }
                let expected = FirstPartyAuthProtocol.responseMAC(
                    sessionKey: sessionKey,
                    sessionIdentifier: sessionIdentifier,
                    sequence: sequence,
                    status: UInt16(status),
                    contentType: contentType,
                    body: body
                )
                guard FirstPartyAuthProtocol.constantTimeEquals(expected, presented) else {
                    throw FirstPartyAuthenticationError.identityMismatch
                }
            },
            redirectPolicy: .refuse
        )

        return AuthenticatedDaemonTransport(
            transport: transport,
            sessionIdentifier: FirstPartyAuthProtocol.base64URLEncode(sessionIdentifier)
        )
    }
}

/// Owns one session's sequence stream.
///
/// An actor because `HTTPTransport` is `Sendable` and its seams are called from
/// arbitrary tasks. Each session owns exactly one UInt64 stream, and requests
/// start at 1 because 0 is not a legal sequence.
///
/// Overflow revokes rather than wraps: wrapping would restart the sequence
/// inside the server's replay window and make every subsequent request look
/// like a duplicate — a session that silently stops working rather than one
/// that fails cleanly.
actor FirstPartySequencer {
    private var sequence: UInt64 = 0

    /// True once the sequence space is exhausted and the session must be
    /// discarded.
    private(set) var isExhausted = false

    /// The next sequence, or `nil` when the stream is exhausted.
    ///
    /// This actor deliberately keeps NO notion of "the request in flight".
    /// Several requests can be in flight at once, so a single such field would
    /// describe whichever started most recently and would mis-bind every other
    /// response. Each request carries its own sequence in its own header, and
    /// that is the only place the response check reads it from.
    func next() -> UInt64? {
        guard sequence < UInt64.max else {
            isExhausted = true
            return nil
        }
        sequence += 1
        return sequence
    }
}
