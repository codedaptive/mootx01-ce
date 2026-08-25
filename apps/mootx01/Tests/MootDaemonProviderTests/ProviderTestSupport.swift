import Foundation
import AriaMCP
@testable import MootDaemonProvider

// MARK: - MACD-2c1 test support — counting adversarial fakes
//
// Every fake here COUNTS. The mission's central negative claims — "the race
// loser invokes zero Keychain/estate/bind/publish callbacks", "no handover
// callback occurs out of order", "rotation revokes before republish" — are
// only provable by fakes that record every invocation in one shared, ordered
// event log. Silence in the log is the evidence.

/// A lock-guarded ordered event log shared across fakes.
final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    func record(_ event: String) {
        lock.lock()
        defer { lock.unlock() }
        log.append(event)
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func count(prefix: String) -> Int {
        events.filter { $0.hasPrefix(prefix) }.count
    }

    /// Index of the first event with `prefix`, or nil.
    func firstIndex(prefix: String) -> Int? {
        events.firstIndex { $0.hasPrefix(prefix) }
    }
}

// MARK: Identities

/// The test team. Any resemblance to a real team identifier is deliberate
/// absence of resemblance.
let testTeam = "TESTTEAM99"

/// A fully eligible signed identity.
func eligibleIdentity(
    signingClass: SignedProcessIdentity.SigningClass = .developerID,
    team: String = testTeam,
    bundle: String = "com.codedaptive.mootx01.test-shell"
) -> SignedProcessIdentity {
    SignedProcessIdentity(
        signingClass: signingClass,
        teamIdentifier: team,
        applicationGroups: [ProviderEligibilityJudge.requiredAppGroup],
        keychainAccessGroups: [team + "." + ProviderEligibilityJudge.requiredKeychainGroupSuffix],
        bundleIdentifier: bundle
    )
}

/// Judge an eligible identity into a `ProviderEligibility` for components
/// that require the proof value.
func makeEligibility() throws -> ProviderEligibility {
    try ProviderEligibilityJudge.judge(eligibleIdentity())
}

// MARK: Deterministic clock and randomness

/// A settable deterministic clock (Perkins P13).
final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64 = 1_700_000_000) { self.value = value }

    var now: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by seconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        value += seconds
    }

    var closure: ProviderClock { { self.now } }
}

/// Deterministic "randomness": a counter-stamped repeating pattern, so tests
/// can predict minted bytes exactly.
final class SeededRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt8

    init(seed: UInt8 = 7) { self.counter = seed }

    func bytes(_ count: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        counter &+= 1
        return [UInt8](repeating: counter, count: count)
    }

    var closure: ProviderRandomness { { self.bytes($0) } }
}

// MARK: Injected authority fakes

/// Fixed readback.
struct FakeReadback: EntitlementReadback {
    let identity: SignedProcessIdentity
    func processIdentity() throws -> SignedProcessIdentity { identity }
}

/// Fixed-URL resolver (or nil to simulate resolution failure).
struct FakeResolver: ProviderRootResolving {
    let url: URL?
    func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? { url }
}

/// An in-memory Keychain with scriptable faults, counting every call.
final class CountingKeychain: KeychainItemAuthority, @unchecked Sendable {
    private let lock = NSLock()
    let recorder: CallRecorder
    /// Pre-scripted read results, consumed in order; when exhausted, reads
    /// consult `stored`.
    private var scriptedReads: [KeychainReadResult]
    /// Scripted add status; nil means honest add into `stored`.
    private var scriptedAdd: KeychainWriteStatus?
    private(set) var stored: [UInt8]?
    /// When set, a successful honest add stores THESE bytes instead of the
    /// requested ones — the "disagreement" adversary.
    var corruptOnAdd: [UInt8]?

    init(recorder: CallRecorder, scriptedReads: [KeychainReadResult] = [], scriptedAdd: KeychainWriteStatus? = nil) {
        self.recorder = recorder
        self.scriptedReads = scriptedReads
        self.scriptedAdd = scriptedAdd
    }

    func copyItem(service: String, account: String, accessGroup: String) -> KeychainReadResult {
        recorder.record("keychain.copy service=\(service) account=\(account) group=\(accessGroup)")
        lock.lock()
        defer { lock.unlock() }
        if !scriptedReads.isEmpty { return scriptedReads.removeFirst() }
        if let stored { return .found(stored) }
        return .notFound
    }

    func addItem(service: String, account: String, accessGroup: String, data: [UInt8]) -> KeychainWriteStatus {
        recorder.record("keychain.add service=\(service) account=\(account) group=\(accessGroup) bytes=\(data.count)")
        lock.lock()
        defer { lock.unlock() }
        if let scriptedAdd { return scriptedAdd }
        if stored != nil { return .duplicate }
        stored = corruptOnAdd ?? data
        return .added
    }
}

/// A counting estate lifecycle fake.
final class CountingEstate: EstateLifecycleAuthority, @unchecked Sendable {
    let recorder: CallRecorder
    let proof: EstateReadyProof
    /// When set, `openEstate` throws it.
    let openFailure: DaemonProviderError?

    init(
        recorder: CallRecorder,
        proof: EstateReadyProof = EstateReadyProof(
            estateIdentifier: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!,
            schemaVersion: 12
        ),
        openFailure: DaemonProviderError? = nil
    ) {
        self.recorder = recorder
        self.proof = proof
        self.openFailure = openFailure
    }

    func stopWrites() async throws { recorder.record("estate.stopWrites") }
    func drain() async throws { recorder.record("estate.drain") }
    func checkpoint() async throws { recorder.record("estate.checkpoint") }
    func closeEstate() async throws { recorder.record("estate.close") }
    func openEstate() async throws -> EstateReadyProof {
        recorder.record("estate.open")
        if let openFailure { throw openFailure }
        return proof
    }
}

/// A counting installer fake.
final class CountingInstaller: InstallerAuthority, @unchecked Sendable {
    let recorder: CallRecorder
    init(recorder: CallRecorder) { self.recorder = recorder }
    func prepareTargetDisabled() async throws { recorder.record("installer.prepareTargetDisabled") }
    func removeSource() async throws { recorder.record("installer.removeSource") }
    func rollbackToSource() async throws { recorder.record("installer.rollbackToSource") }
}

/// A counting process-exit fake; scriptable to report a still-running source.
final class CountingProcess: ProcessExitAuthority, @unchecked Sendable {
    let recorder: CallRecorder
    let sourceStillRunning: Bool
    init(recorder: CallRecorder, sourceStillRunning: Bool = false) {
        self.recorder = recorder
        self.sourceStillRunning = sourceStillRunning
    }
    func verifySourceExited() async throws {
        recorder.record("process.verifySourceExited")
        if sourceStillRunning { throw DaemonProviderError.handoverSequenceViolation(expected: .sourceExited, requested: .sourceExited) }
    }
    func verifyLockReleased() async throws { recorder.record("process.verifyLockReleased") }
}

/// A fixed source authenticator.
final class FakeSourceAuthentication: SourceAuthenticationAuthority, @unchecked Sendable {
    let recorder: CallRecorder
    let identity: SigningIdentityDescriptor
    init(recorder: CallRecorder, identity: SigningIdentityDescriptor = SigningIdentityDescriptor(
        teamIdentifier: testTeam, bundleIdentifier: "com.codedaptive.mootx01.source", signingClass: .developerID
    )) {
        self.recorder = recorder
        self.identity = identity
    }
    func authenticateSource() async throws -> SigningIdentityDescriptor {
        recorder.record("sourceAuth.authenticate")
        return identity
    }
}

/// A counting session-revocation fake.
final class CountingSessions: SessionRevocationAuthority, @unchecked Sendable {
    let recorder: CallRecorder
    init(recorder: CallRecorder) { self.recorder = recorder }
    func revokeAllSessions() async { recorder.record("sessions.revokeAll") }
}

/// A counting bind fake with a scriptable readback.
final class CountingBind: BindAuthority, @unchecked Sendable {
    let recorder: CallRecorder
    let proof: BindProof
    init(recorder: CallRecorder, proof: BindProof = BindProof(host: "127.0.0.1", port: 4242)) {
        self.recorder = recorder
        self.proof = proof
    }
    func bindLoopback() async throws -> BindProof {
        recorder.record("bind.loopback")
        return proof
    }
}

// MARK: Filesystem scratch

/// A fresh scratch directory per test, removed on deinit.
final class ScratchDirectory: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macd2c1-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    deinit {
        // Restore permissive modes first so removal cannot be blocked by a
        // test that deliberately broke permissions.
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let item as URL in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: item.path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: Provider assembly

/// Everything a `DaemonProvider` needs, assembled around one recorder and one
/// scratch container so tests can race two providers on one root.
struct ProviderHarness {
    let recorder: CallRecorder
    let scratch: ScratchDirectory
    let clock: FixedClock
    let random: SeededRandom
    let keychain: CountingKeychain
    let estate: CountingEstate
    let bind: CountingBind
    let sessions: CountingSessions
    let configuration: DaemonProviderConfiguration
    let provider: DaemonProvider

    init(
        scratch: ScratchDirectory = ScratchDirectory(),
        recorder: CallRecorder = CallRecorder(),
        identity: SignedProcessIdentity = eligibleIdentity(),
        instance: UUID = UUID(),
        resolverURL: URL? = nil,
        keychain: CountingKeychain? = nil,
        estate: CountingEstate? = nil,
        bind: CountingBind? = nil
    ) {
        self.recorder = recorder
        self.scratch = scratch
        self.clock = FixedClock()
        self.random = SeededRandom()
        self.keychain = keychain ?? CountingKeychain(recorder: recorder)
        self.estate = estate ?? CountingEstate(recorder: recorder)
        self.bind = bind ?? CountingBind(recorder: recorder)
        self.sessions = CountingSessions(recorder: recorder)
        self.configuration = DaemonProviderConfiguration(
            instanceIdentifier: instance,
            binaryVersion: "1.0.18",
            capabilities: ["authenticated-first-party", "resident-estate", "tool-surface"]
        )
        self.provider = DaemonProvider(
            configuration: configuration,
            readback: FakeReadback(identity: identity),
            resolver: FakeResolver(url: resolverURL ?? scratch.url),
            keychain: self.keychain,
            estate: self.estate,
            bind: self.bind,
            sessions: self.sessions,
            clock: clock.closure,
            randomBytes: random.closure
        )
    }

    /// Count of side-effect callbacks the mission's race rule forbids for a
    /// loser: Keychain, estate, bind, and session activity.
    var sideEffectCallbackCount: Int {
        recorder.count(prefix: "keychain.") + recorder.count(prefix: "estate.")
            + recorder.count(prefix: "bind.") + recorder.count(prefix: "sessions.")
    }
}
