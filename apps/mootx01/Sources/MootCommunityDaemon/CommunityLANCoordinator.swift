// CommunityLANCoordinator.swift
//
// LAN serving coordinator for the five lan-family endpoints (Wave D2: CORE-08).
//
// ARCHITECTURE
// ────────────────────────────────────────────────────────────────────────────
// This actor owns:
//   1. Serving state machine  — stopped → active → stopped (or interrupted/failed).
//   2. Eligibility engine     — reads capture-ledger.json from the layout dir;
//                               computes eligible/ineligible counts on demand.
//   3. TCP listener task      — a Task.detached loop that accepts connections on
//                               the bound socket and serves eligible records over
//                               an authenticated HTTP lane. The accept loop runs
//                               blocking POSIX syscalls off-pool to avoid
//                               starving the cooperative executor.
//   4. Durable sidecar        — lan-state.json: stores authority grants only.
//                               Serving state is NEVER persisted; on every init
//                               the coordinator starts in .stopped (frozen policy).
//
// FROZEN-POLICY RESTART READING
// ────────────────────────────────────────────────────────────────────────────
// The default policy, baked at build time, is OFF. The sidecar stores
// `authorityGranted` so lan_start can succeed after a restart without
// re-granting, but NOT the serving state. On init, state is always .stopped
// and a fresh lan_start is required to begin serving again.
//
// This satisfies the CORE-08 criterion:
//   "Restart does not silently restore serving unless the frozen policy
//    explicitly authorizes restoration."
// The frozen policy does not authorize restoration; therefore it is never
// silently restored.
//
// ELIGIBILITY ENGINE
// ────────────────────────────────────────────────────────────────────────────
// A record from the capture ledger is LAN-addressable iff ALL hold:
//   1. sensitivity ∈ {normal, elevated}  ("below restricted")
//   2. exportEligible == true
//   3. lanEligible == true
//
// The engine reads the ledger file at call time (not cached in-process), so
// eligibility changes made via lan_refresh_eligibility take effect on the LIVE
// server immediately — no restart required.
//
// TRANSPORT DESIGN
// ────────────────────────────────────────────────────────────────────────────
// The LAN transport reuses LoopbackHTTP (POSIXSocket + HTTPWire) with one
// addition: `listenAnyTCP(port:bindAddress:)` accepts a configurable bind
// address so production binds to 0.0.0.0 while tests bind to 127.0.0.1:0
// (sandbox-safe — no real LAN exposure in tests).
//
// HTTP routes served:
//   GET /records          — list eligible record IDs as JSON array
//   GET /records/{id}     — fetch one record if eligible; 404 otherwise
//   Any other path        — 404
//
// Authentication: every request must carry a valid Bearer token in the
// Authorization header. Wrong or missing token → HTTP 401 (distinguishable
// error). Expired token → HTTP 401 with body {"error":"lan-credential-expired"}.
//
// An ineligible recordID requested directly returns HTTP 404 (not-found-equivalent).
// This applies whether the ID is found but ineligible, or simply unknown — both
// return the same 404 so no information about the existence of ineligible records
// leaks through the LAN surface.
//
// STOP SEMANTICS
// ────────────────────────────────────────────────────────────────────────────
// Stop closes the accept-socket fd (using Darwin/Linux shutdown + close),
// cancels the server Task, and AWAITS the task's completion before returning.
//
// Awaiting task completion is critical for two reasons:
//   1. stop() returns only after serving has ceased — no window where a caller
//      sees "stopped" but a request is still being served with old credentials.
//   2. Actor isolation serializes stop→start: since stop() awaits the task
//      before returning, the actor does not execute start() until the old
//      accept loop has fully exited. This eliminates the fd-number reuse window
//      where a stale loop (holding the old credential) could inadvertently
//      adopt the new listening socket if the OS reuses the same fd number.
//
// TOKEN COMPARISON (F8)
// ────────────────────────────────────────────────────────────────────────────
// Bearer tokens are compared using constant-time SHA-256 digest equality:
// SHA-256(presented) vs SHA-256(stored), compared byte-by-byte without early
// exit. This prevents timing side-channels on the 0.0.0.0-bindable surface.
// Ordinary String == is a variable-time comparison and must NOT be used.

import CryptoKit
import Foundation
import OSLog
import AriaMCP
import LoopbackHTTP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

private let log = Logger(subsystem: "com.mootx01", category: "CommunityLANCoordinator")

// MARK: - Sidecar

/// Persisted state in lan-state.json.
///
/// Only `authorityGranted` is stored. Serving state is not persisted — the
/// coordinator always starts in .stopped (frozen-policy default-off).
private struct LANSidecar: Codable, Sendable {
    /// True when the user / authority source has granted LAN serving permission.
    /// Persisted so lan_start can succeed after restart without re-granting.
    var authorityGranted: Bool

    static let `default` = LANSidecar(authorityGranted: false)
}

// MARK: - Ledger entry (mirror of CommunityCaptureCoordinator's private type)

/// One entry from capture-ledger.json.
///
/// This mirrors `LedgerEntry` in CommunityCaptureCoordinator. A local
/// definition is used rather than sharing the type because:
///   - CommunityCaptureCoordinator's LedgerEntry is `private` (correct encapsulation).
///   - The fields we need (sensitivity, exportEligible, lanEligible) are a stable
///     subset of the ledger format; the coordinator need not know about recordID,
///     destinationID, etc.
/// Both types must decode the same JSON, so the Codable keys must match exactly.
private struct LANLedgerEntry: Codable, Sendable {
    let recordID: String
    let destinationID: String
    let sensitivity: String
    let exportEligible: Bool
    let lanEligible: Bool
}

// MARK: - Credential

/// A bearer token with an expiry date.
///
/// The token is a UUID string minted at lan_start. The expiry window is
/// `tokenValiditySeconds` (24 hours by default; overrideable in tests via
/// the coordinator's `tokenValiditySeconds` property).
private struct LANCredential: Sendable {
    let token: String
    let expiresAt: Date

    /// True while the current date is before the expiry.
    func isValid(at now: Date) -> Bool { now < expiresAt }

    var authenticationState: LANAuthentication {
        isValid(at: Date()) ? .valid : .expired
    }
}

// MARK: - Internal serving state

/// Internal state machine for the coordinator.
///
/// This is separate from the public `LANStatus` enum so internal state carries
/// the live socket fd and credential without exposing them in the public API.
private enum ServingState {
    case stopped
    case active(fd: Int32, port: UInt16, credential: LANCredential, serverTask: Task<Void, Never>)
    case interrupted(reason: String)
    case failed(reason: String)

    /// Public representation.
    func asLANStatus(bindAddress: String) -> LANStatus {
        switch self {
        case .stopped:
            return .stopped
        case let .active(_, port, credential, _):
            let auth = credential.isValid(at: Date()) ? LANAuthentication.valid : .expired
            let endpoint = "http://\(bindAddress):\(port)"
            return .active(endpoint: endpoint, authentication: auth)
        case let .interrupted(reason):
            return .interrupted(reason: reason)
        case let .failed(reason):
            return .failed(reason: reason)
        }
    }
}

// MARK: - CommunityLANCoordinator

/// Implements the five LAN-family endpoints for the community 1.1 contract.
///
/// Inject one instance into `CommunityContractDispatch` after construction.
/// The coordinator uses the same `layoutURL` as `CommunityCaptureCoordinator`
/// so it can read the capture ledger for eligibility computations.
///
/// In production: `bindAddress = "0.0.0.0"`, `lanPort = 4243`.
/// In tests:      `bindAddress = "127.0.0.1"`, `lanPort = 0` (OS-assigned).
public actor CommunityLANCoordinator: Sendable {

    // MARK: - Properties

    /// Layout directory — same as the capture coordinator's layoutURL.
    public let layoutURL: URL

    /// IPv4 address to bind the serving socket. "0.0.0.0" for production LAN
    /// serving; "127.0.0.1" for test-sandbox safety.
    public let bindAddress: String

    /// TCP port to request. 0 lets the OS assign one (use in tests).
    public let lanPort: UInt16

    /// How long (in seconds) a minted token is valid. Defaults to 86400 (24 h).
    /// Override in tests to exercise expiry without sleeping.
    public var tokenValiditySeconds: TimeInterval = 86400

    /// Closure that returns true iff LAN authority has been granted.
    ///
    /// In production this checks the persisted sidecar. Tests inject their own
    /// closure to control authority for the `lan-authority-missing` case.
    ///
    /// The closure is called from actor-isolated context; it must be Sendable.
    private let authorityCheck: @Sendable () -> Bool

    // MARK: - Derived paths

    private var sidecarURL: URL { layoutURL.appendingPathComponent("lan-state.json") }
    private var ledgerURL:  URL { layoutURL.appendingPathComponent("capture-ledger.json") }

    // MARK: - Internal state

    /// Current serving state. Always starts as .stopped (frozen-policy default-off).
    ///
    /// FROZEN-POLICY RESTART: this field is unconditionally set to .stopped in
    /// init() regardless of anything in the sidecar. The sidecar only carries
    /// `authorityGranted` (which persists across restarts) — NOT the serving state.
    private var servingState: ServingState = .stopped

    // MARK: - Policy description (fixed contract string)

    /// Human-readable policy description matching the contract fixture exactly.
    static let policyDescription =
        "Only explicitly LAN-eligible and export-eligible records below restricted sensitivity are served."

    // MARK: - Init

    /// Default production init. Authority is derived from the persisted sidecar.
    ///
    /// - Parameters:
    ///   - layoutURL: Layout directory (same as capture coordinator).
    ///   - bindAddress: IPv4 bind address (production: "0.0.0.0").
    ///   - lanPort: Port to bind (production: 4243; tests: 0 for OS-assigned).
    public init(layoutURL: URL, bindAddress: String, lanPort: UInt16 = 4243) {
        self.layoutURL = layoutURL
        self.bindAddress = bindAddress
        self.lanPort = lanPort
        // Read sidecar on the calling thread (sync init); if sidecar is missing
        // or unreadable, authority defaults to false (fail-closed).
        let sidecarPath = layoutURL.appendingPathComponent("lan-state.json").path
        let authorityFromSidecar: Bool
        if let data = try? Data(contentsOf: URL(fileURLWithPath: sidecarPath)),
           let sidecar = try? JSONDecoder().decode(LANSidecar.self, from: data) {
            authorityFromSidecar = sidecar.authorityGranted
        } else {
            authorityFromSidecar = false
        }
        // Capture in closure so the actor body doesn't need to re-read disk.
        let granted = authorityFromSidecar
        self.authorityCheck = { granted }
    }

    /// Test init: injects an explicit authority flag and uses 127.0.0.1:0.
    ///
    /// Using 127.0.0.1 and port 0 keeps tests sandbox-safe (no real LAN
    /// exposure) while still exercising the full TCP stack with a real kernel
    /// socket. The OS assigns an available port and `lan_start` reports the
    /// actual endpoint in its response.
    public init(layoutURL: URL, hasAuthority: Bool, bindAddress: String = "127.0.0.1", lanPort: UInt16 = 0) {
        self.layoutURL = layoutURL
        self.bindAddress = bindAddress
        self.lanPort = lanPort
        self.authorityCheck = { hasAuthority }
    }

    // MARK: - Endpoint: moot_community_lan_status

    /// Returns the current serving state.
    ///
    /// Always safe to call. Returns .stopped for a fresh coordinator (frozen
    /// policy: serving is never auto-restored on restart). The `endpoint` field
    /// is present only in the `active` state.
    public func status() async -> JSONValue {
        let status = servingState.asLANStatus(bindAddress: bindAddress)
        return status.toJSONValue()
    }

    // MARK: - Endpoint: moot_community_lan_policy

    /// Compute and return LAN eligibility counts.
    ///
    /// Reads the capture ledger file at call time — counts are ALWAYS live,
    /// never cached. This is the same file `CommunityCaptureCoordinator` writes
    /// to (`capture-ledger.json` in the layout directory).
    ///
    /// The function is deliberately non-throwing: if the ledger is missing or
    /// unparseable, both counts are 0 (fail-safe — no estate access required).
    public func policy() async -> JSONValue {
        let (eligible, ineligible) = computeEligibilityCounts()
        return LANPolicy(
            eligibleCount: eligible,
            ineligibleCount: ineligible,
            policyDescription: Self.policyDescription
        ).toJSONValue()
    }

    // MARK: - Endpoint: moot_community_lan_start

    /// Start LAN serving.
    ///
    /// Preconditions checked in order:
    ///   1. Authority granted (from authorityCheck closure) — else denied{lan-authority-missing}.
    ///   2. Not already active — if already active, return the current state as started.
    ///   3. Bind socket — else failed{lan-network-unavailable or unexpected-failure}.
    ///   4. Mint bearer token.
    ///
    /// On success, a Task.detached accept loop begins serving connections.
    /// The loop is actor-isolated for state mutations but runs the blocking
    /// accept/read/write calls on a detached Task (off the cooperative pool) so
    /// the cooperative executor is never stalled.
    public func start() async -> JSONValue {
        // 1. Authority check.
        guard authorityCheck() else {
            log.info("lan_start: denied — authority not granted")
            return LANStartOutcome.denied(reason: "lan-authority-missing").toJSONValue()
        }

        // 2. Already active? Return the current endpoint.
        if case let .active(_, port, credential, _) = servingState {
            let auth = credential.isValid(at: Date()) ? LANAuthentication.valid : .expired
            let endpoint = "http://\(bindAddress):\(port)"
            log.info("lan_start: already active on \(endpoint, privacy: .public)")
            return LANStartOutcome.started(endpoint: endpoint, authentication: auth).toJSONValue()
        }

        // 3. Bind socket.
        let (fd, actualPort): (Int32, UInt16)
        do {
            (fd, actualPort) = try POSIXSocket.listenAnyTCP(port: lanPort, bindAddress: bindAddress)
        } catch {
            log.error("lan_start: socket bind failed: \(error, privacy: .public)")
            return LANStartOutcome.failed(reason: "lan-network-unavailable").toJSONValue()
        }

        // 4. Mint bearer token.
        let token = UUID().uuidString
        let expiresAt = Date().addingTimeInterval(tokenValiditySeconds)
        let credential = LANCredential(token: token, expiresAt: expiresAt)

        // 5. Start accept loop in a detached Task.
        //
        // The loop captures:
        //   - fd:          the listening socket (closed by lan_stop via close(fd))
        //   - credential:  bearer token + expiry for request authentication
        //   - layoutURL:   for computing eligibility at request time (ledger file)
        //   - ledgerURL:   derived from layoutURL for ledger reads
        //   - bindAddress: not needed in the loop but kept for clarity
        //
        // Actor isolation is NOT re-entered in the loop — the loop is
        // deliberately off-actor (it can't call `self.computeEligibilityCounts()`
        // without hopping back to the actor). Instead it reads the ledger file
        // directly. This is safe because the ledger file is written atomically
        // (write to .tmp, then rename) by CommunityCaptureCoordinator, so there
        // is no torn-read risk. Reading the file from a detached Task while the
        // actor reads it for policy() is the same safe pattern.
        let ledgerURLCopy = self.ledgerURL
        let serverTask = Task.detached(priority: .background) { [fd, credential, ledgerURLCopy] in
            Self.runAcceptLoop(
                listenFD: fd,
                credential: credential,
                ledgerURL: ledgerURLCopy
            )
        }

        let endpoint = "http://\(bindAddress):\(actualPort)"
        log.info("lan_start: bound to \(endpoint, privacy: .public) token=\(token.prefix(8), privacy: .public)...")

        servingState = .active(fd: fd, port: actualPort, credential: credential, serverTask: serverTask)
        return LANStartOutcome.started(endpoint: endpoint, authentication: .valid).toJSONValue()
    }

    // MARK: - Endpoint: moot_community_lan_stop

    /// Stop LAN serving and close the listening socket.
    ///
    /// After this call:
    ///   - The accept loop has fully exited (stop AWAITS task completion).
    ///   - A connection attempt to the former endpoint is refused by the OS.
    ///   - State transitions to .stopped.
    ///
    /// AWAIT SEMANTICS: stop() awaits serverTask.value before returning, so the
    /// caller receives "stopped" only after the last in-flight connection has been
    /// served and the accept loop has exited. This eliminates the fd-reuse window
    /// described in the STOP SEMANTICS section above.
    ///
    /// Idempotent: stopping an already-stopped coordinator returns stopped.
    public func stop() async -> JSONValue {
        switch servingState {
        case let .active(fd, _, _, serverTask):
            // 1. Close the listening fd. This causes any pending accept() call in the
            //    accept loop to return EBADF / EINVAL and the loop to detect shutdown.
            shutdown(fd, SHUT_RDWR)
            close(fd)
            // 2. Cancel the Task so Task.isCancelled is true when the loop re-checks
            //    (belt-and-suspenders for the cancellation path after accept returns).
            serverTask.cancel()
            // 3. Transition state to stopped NOW (before await) so that any concurrent
            //    actor-isolated call that sneaks in sees the stopped state. Actor isolation
            //    ensures only one of stop/start runs at a time, so this is safe.
            servingState = .stopped
            // 4. Await loop exit. This is the critical gate: stop() does not return until
            //    the accept loop has finished its current iteration and exited. Only after
            //    this await can start() allocate a new fd — preventing fd-number reuse by
            //    a stale loop that still holds the old credential.
            await serverTask.value
            log.info("lan_stop: socket closed, accept loop exited, serving stopped")
            return LANStopOutcome.stopped.toJSONValue()

        case .stopped:
            // Already stopped — idempotent.
            log.debug("lan_stop: already stopped")
            return LANStopOutcome.stopped.toJSONValue()

        case .interrupted(_):
            // Was interrupted — reset to stopped, return success.
            servingState = .stopped
            log.debug("lan_stop: transitioning from interrupted to stopped")
            return LANStopOutcome.stopped.toJSONValue()

        case .failed(_):
            // Was in failed state — reset to stopped, return success.
            servingState = .stopped
            log.debug("lan_stop: transitioning from failed to stopped")
            return LANStopOutcome.stopped.toJSONValue()
        }
    }

    // MARK: - Endpoint: moot_community_lan_refresh_eligibility

    /// Recompute eligibility counts and update the live filter.
    ///
    /// The live server automatically uses the new counts on subsequent requests
    /// because the accept loop reads the ledger file at request time (not cached).
    /// No restart is required for eligibility changes to take effect.
    ///
    /// Refused when: `policyForbidsRefresh` is set on the coordinator (injected
    /// at construction to model the `lan-policy-forbidden` fixture case). In
    /// normal operation this flag is false and refresh always succeeds.
    public var policyForbidsRefresh: Bool = false

    public func refreshEligibility() async -> JSONValue {
        // If a policy gate explicitly forbids refresh (test-injected or config-driven),
        // return the distinguishable refusal code.
        if policyForbidsRefresh {
            return LANEligibilityOutcome.refused(reason: "lan-policy-forbidden").toJSONValue()
        }

        // Recompute from the ledger.
        let (eligible, ineligible) = computeEligibilityCounts()
        log.debug("lan_refresh_eligibility: eligible=\(eligible) ineligible=\(ineligible)")
        return LANEligibilityOutcome.updated(
            eligibleCount: eligible,
            ineligibleCount: ineligible
        ).toJSONValue()
    }

    // MARK: - Eligibility engine

    /// Compute eligibility counts from the capture ledger file.
    ///
    /// Reads `capture-ledger.json` from the layout directory (the same file
    /// `CommunityCaptureCoordinator` writes to). If the file is absent or
    /// unparseable, returns (0, 0) — fail-safe, no crash.
    ///
    /// A record is ELIGIBLE iff ALL hold:
    ///   - sensitivity ∈ {"normal", "elevated"}   (below restricted)
    ///   - exportEligible == true
    ///   - lanEligible    == true
    ///
    /// All other records are INELIGIBLE.
    func computeEligibilityCounts() -> (eligible: Int, ineligible: Int) {
        guard let data = try? Data(contentsOf: ledgerURL),
              let ledger = try? JSONDecoder().decode([String: LANLedgerEntry].self, from: data) else {
            // Ledger absent or corrupt — zero counts (no records to serve or exclude).
            return (0, 0)
        }
        var eligible = 0
        var ineligible = 0
        for entry in ledger.values {
            if isLANEligible(entry) {
                eligible += 1
            } else {
                ineligible += 1
            }
        }
        return (eligible, ineligible)
    }

    /// True iff this ledger entry meets all three LAN eligibility criteria.
    private func isLANEligible(_ entry: LANLedgerEntry) -> Bool {
        // Criterion 1: sensitivity below restricted (normal or elevated only).
        let sensitivityOK = entry.sensitivity == "normal" || entry.sensitivity == "elevated"
        // Criterion 2: export-eligible flag set.
        let exportOK = entry.exportEligible
        // Criterion 3: LAN-eligible flag set.
        let lanOK = entry.lanEligible
        return sensitivityOK && exportOK && lanOK
    }

    // MARK: - Sidecar helpers

    /// Persist the current authority grant to the sidecar.
    ///
    /// Used when authority is programmatically granted (test or admin path).
    /// Serving state is NOT written to the sidecar (frozen-policy invariant).
    func grantAuthority() {
        let sidecar = LANSidecar(authorityGranted: true)
        writeSidecar(sidecar)
    }

    private func writeSidecar(_ sidecar: LANSidecar) {
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        let tmpURL = sidecarURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpURL, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(sidecarURL, withItemAt: tmpURL)
        } catch {
            // Fallback: direct write.
            try? data.write(to: sidecarURL, options: .atomic)
            try? FileManager.default.removeItem(at: tmpURL)
        }
    }

    // MARK: - Accept loop (static, off-actor)

    /// The blocking TCP accept-and-serve loop. Runs in a Task.detached so it
    /// never occupies a cooperative executor thread.
    ///
    /// ELIGIBILITY AT REQUEST TIME: the loop reads the ledger file fresh for
    /// every request. This ensures that a refresh_eligibility call (which updates
    /// the ledger on disk via the capture coordinator) takes effect immediately on
    /// subsequent LAN requests — no in-process cache invalidation is needed.
    ///
    /// AUTHENTICATION: every request must carry the correct Bearer token.
    ///   - Missing or wrong token → HTTP 401, body {"error":"unauthorized"}
    ///   - Expired token          → HTTP 401, body {"error":"lan-credential-expired"}
    ///   - Valid token            → request is handled
    ///
    /// INELIGIBLE RECORDS: a record that does not meet all three eligibility
    /// criteria returns HTTP 404 — identical to an unknown record. This is
    /// intentional: the LAN surface must not leak whether an ineligible record
    /// exists.
    private static func runAcceptLoop(
        listenFD: Int32,
        credential: LANCredential,
        ledgerURL: URL
    ) {
        log.debug("lan accept loop: started on fd=\(listenFD)")
        while true {
            // Check cancellation at the TOP of every iteration. stop() calls
            // serverTask.cancel() before closing the fd, so if cancel fires between
            // two accept() calls the loop exits without attempting another accept.
            if Task.isCancelled {
                log.debug("lan accept loop: cancelled before accept — exiting")
                break
            }
            guard let clientFD = POSIXSocket.acceptOne(listenFD) else {
                // accept() failed — either the fd was closed (stop was called) or
                // a transient EINTR. Either way, exit: a closed fd cannot recover.
                log.debug("lan accept loop: accept returned nil — exiting")
                break
            }
            // Check cancellation AFTER accept returns and BEFORE serving. This guards
            // against the race where stop closes the fd while the previous accept was
            // blocking: the new clientFD arrived from the last accept before close but
            // stop has already transitioned state. We still serve this connection
            // (in-flight handling completes) but will not accept another.
            //
            // Note: we do NOT skip serving the accepted connection here — doing so
            // would leave the client hanging. The connection is short-lived
            // (HTTP/1.1 Connection: close); serving completes in microseconds.
            serveConnection(fd: clientFD, credential: credential, ledgerURL: ledgerURL)
            close(clientFD)
            // Check cancellation AFTER serving. If stop was called during serve, we
            // exit cleanly instead of looping back to accept() on a closed fd.
            if Task.isCancelled {
                log.debug("lan accept loop: cancelled after serve — exiting")
                break
            }
        }
        log.debug("lan accept loop: exited")
    }

    // MARK: - Constant-time token comparison (F8)

    /// Compare two strings for equality in constant time.
    ///
    /// Uses SHA-256 digests of both values and compares all 32 bytes with bitwise-OR
    /// accumulation — no early exit on mismatch. This eliminates timing side-channels
    /// that could allow an attacker to brute-force the bearer token by measuring
    /// response latency.
    ///
    /// Rationale: the LAN surface binds to 0.0.0.0 (reachable by all hosts on the
    /// local network). An attacker with local network access could mount a timing
    /// attack against a naive String == comparison. SHA-256 digest comparison is the
    /// standard mitigation: hash both sides, compare 32 bytes, accumulate with XOR|OR
    /// so every byte is always read regardless of mismatch position.
    private static func constantTimeTokenEqual(_ presented: String, _ stored: String) -> Bool {
        let presentedDigest = Data(SHA256.hash(data: Data(presented.utf8)))
        let storedDigest = Data(SHA256.hash(data: Data(stored.utf8)))
        // Both digests are always 32 bytes. Compare all 32 regardless of first mismatch.
        var result: UInt8 = 0
        for (a, b) in zip(presentedDigest, storedDigest) {
            result |= a ^ b
        }
        return result == 0
    }

    /// Handle one accepted connection.
    private static func serveConnection(
        fd: Int32,
        credential: LANCredential,
        ledgerURL: URL
    ) {
        // Read the HTTP request (headers + body). Use a small header cap since
        // LAN record requests carry no large bodies; 8 KB is ample for headers.
        guard let request = HTTPRequest.read(fd: fd, maxHeaderBytes: 8 * 1024, maxBodyBytes: 0) else {
            // Malformed request — close silently.
            return
        }

        // Authenticate the request.
        let now = Date()
        guard let token = request.bearerToken else {
            // No token at all → 401 unauthorized.
            HTTPResponse(
                status: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"unauthorized"}"#.utf8)
            ).send(fd: fd)
            return
        }

        // Token present but expired? Use constant-time comparison to check whether the
        // presented token matches the stored credential before checking expiry. A timing
        // attack cannot distinguish "wrong token" from "right token, expired" because
        // both paths go through the same constant-time SHA-256 digest comparison.
        if constantTimeTokenEqual(token, credential.token) && !credential.isValid(at: now) {
            // Matched credential but expired → distinguishable 401 with the contract error code.
            HTTPResponse(
                status: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"lan-credential-expired"}"#.utf8)
            ).send(fd: fd)
            return
        }

        // Wrong token (could be expired AND wrong — treat as unauthorized).
        // Constant-time comparison: SHA-256(presented) vs SHA-256(stored), all 32 bytes
        // always compared — no early exit. Prevents timing side-channels.
        guard constantTimeTokenEqual(token, credential.token) else {
            HTTPResponse(
                status: 401,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"unauthorized"}"#.utf8)
            ).send(fd: fd)
            return
        }

        // Authenticated. Route the request.
        let path = request.path
        if path == "/records" {
            // List all eligible record IDs.
            let ledger = readLedger(from: ledgerURL)
            let eligibleIDs = ledger.values
                .filter { isLANEligibleStatic($0) }
                .map { $0.recordID }
                .sorted()
            if let body = try? JSONSerialization.data(withJSONObject: eligibleIDs) {
                HTTPResponse.json(status: 200, body: body).send(fd: fd)
            } else {
                HTTPResponse.json(status: 500, body: Data(#"{"error":"encode-failed"}"#.utf8)).send(fd: fd)
            }
        } else if path.hasPrefix("/records/") {
            // Fetch one record by ID.
            let recordID = String(path.dropFirst("/records/".count))
            guard !recordID.isEmpty else {
                HTTPResponse.notFound.send(fd: fd)
                return
            }
            let ledger = readLedger(from: ledgerURL)
            // Find the entry — check eligibility BEFORE returning any content.
            // An ineligible record returns 404 (same as unknown record — no leakage).
            if let entry = ledger.values.first(where: { $0.recordID == recordID }),
               isLANEligibleStatic(entry) {
                // Return a minimal JSON representation of the record.
                let payload: [String: Any] = [
                    "recordID":      entry.recordID,
                    "destinationID": entry.destinationID,
                    "sensitivity":   entry.sensitivity,
                    "exportEligible": entry.exportEligible,
                    "lanEligible":   entry.lanEligible,
                ]
                if let body = try? JSONSerialization.data(withJSONObject: payload) {
                    HTTPResponse.json(status: 200, body: body).send(fd: fd)
                } else {
                    HTTPResponse.json(status: 500, body: Data(#"{"error":"encode-failed"}"#.utf8)).send(fd: fd)
                }
            } else {
                // Unknown or ineligible — both return 404 (no information leakage).
                HTTPResponse.notFound.send(fd: fd)
            }
        } else {
            HTTPResponse.notFound.send(fd: fd)
        }
    }

    // MARK: - Test-support accessors

    /// Returns the active bearer token, or nil if the coordinator is not serving.
    ///
    /// This is a test-only accessor: it lets tests authenticate HTTP requests
    /// without needing to parse the wire format. Never expose this in production
    /// surfaces — the token is a private credential.
    public func testToken() -> String? {
        if case let .active(_, _, credential, _) = servingState {
            return credential.token
        }
        return nil
    }

    /// Override the token validity window. Used in tests to exercise expiry
    /// without requiring real clock advances.
    public func setTokenValidity(seconds: TimeInterval) {
        tokenValiditySeconds = seconds
    }

    /// Set policyForbidsRefresh to true. Used in tests to exercise the
    /// lan-policy-forbidden refusal path.
    public func enablePolicyForbidsRefresh() {
        policyForbidsRefresh = true
    }

    // MARK: - Static helpers (used in accept loop, off-actor)

    /// Read the capture ledger. Returns empty dict on error.
    private static func readLedger(from url: URL) -> [String: LANLedgerEntry] {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode([String: LANLedgerEntry].self, from: data) else {
            return [:]
        }
        return ledger
    }

    /// Eligibility check reusable without actor isolation (static version).
    private static func isLANEligibleStatic(_ entry: LANLedgerEntry) -> Bool {
        let sensitivityOK = entry.sensitivity == "normal" || entry.sensitivity == "elevated"
        return sensitivityOK && entry.exportEligible && entry.lanEligible
    }
}
