import Foundation

// MARK: - MACD-2c1 — the provider arbiter (Kong decision 3, K6)
//
// One pure, deterministic function from an observation of the machine to one
// of the twelve Kong states. Pure on purpose: an arbiter that reads the world
// while judging it can be raced; this one judges a snapshot the caller
// assembled, so two arbiters given the same observation MUST agree — which is
// what the golden winner-matrix tests pin.
//
// The winner rule, verbatim from the gate: an already running, authenticated,
// compatible provider wins REGARDLESS of whether it came from the direct
// installer or an app bundle. Installation source is not a priority rule. An
// incompatible newer daemon is left running and the app requires an update.
// An older daemon may be replaced only through explicit approved handover.
// Port liveness never elects a winner.

/// Which provider artifact a claim belongs to.
public enum ProviderKind: String, Sendable, Equatable, CaseIterable {
    /// The Developer-ID direct-install app-like daemon.
    case direct = "direct-install"
    /// The sandboxed nested SMAppService helper.
    case bundled = "bundled-helper"
}

/// Whether a claim's holder proved its identity through the authenticated
/// contract (descriptor MAC + handshake) — never through port liveness.
public enum AuthenticationObservation: String, Sendable, Equatable {
    case authenticated
    case unauthenticated
}

/// Client/daemon contract compatibility of an observed provider.
public enum ContractCompatibility: String, Sendable, Equatable {
    case compatible
    /// Daemon newer than the client supports: left running; the app updates.
    case incompatibleNewer = "incompatible-newer"
    /// Daemon older than the client supports: replaced only via explicit
    /// approved handover.
    case incompatibleOlder = "incompatible-older"
}

/// Liveness of a claim's process, as verified by the process authority.
public enum ProcessLiveness: String, Sendable, Equatable {
    case live
    case exited
}

/// Registration state of one mechanism.
public enum RegistrationObservation: String, Sendable, Equatable {
    case none
    /// SMAppService requires user approval (bundled mechanism only).
    case awaitingApproval = "awaiting-approval"
    case registered
}

/// What holds — or fails to hold — TCP port 4242. Deliberately incapable of
/// electing a winner; it exists so a squatter can be REPORTED.
public enum PortObservation: String, Sendable, Equatable {
    case unbound
    /// The bound process is the authenticated lock owner.
    case verifiedOwner = "verified-owner"
    /// Something is bound that cannot be authenticated.
    case unverifiedHolder = "unverified-holder"
}

/// One observed claim on the exclusive provider lock.
public struct LockClaim: Sendable, Equatable {
    /// Which artifact claims the lock.
    public let kind: ProviderKind
    /// The claimant's instance identity.
    public let instance: UUID
    /// The estate the claimant reports owning.
    public let estate: UUID
    /// The claimant's binary version.
    public let version: String
    /// Whether the claimant authenticated (descriptor MAC + handshake).
    public let authentication: AuthenticationObservation
    /// Contract compatibility with this client.
    public let compatibility: ContractCompatibility
    /// Whether the claimant's process is live.
    public let liveness: ProcessLiveness

    public init(
        kind: ProviderKind, instance: UUID, estate: UUID, version: String,
        authentication: AuthenticationObservation,
        compatibility: ContractCompatibility,
        liveness: ProcessLiveness
    ) {
        self.kind = kind
        self.instance = instance
        self.estate = estate
        self.version = version
        self.authentication = authentication
        self.compatibility = compatibility
        self.liveness = liveness
    }
}

/// The published descriptor, as observed.
public enum DescriptorObservation: Sendable, Equatable {
    case absent
    /// A record is present for `instance`, with its authentication result.
    case present(instance: UUID, authentication: AuthenticationObservation)
}

/// The handover coordinator's externally observable phase.
public enum HandoverObservation: String, Sendable, Equatable {
    case none
    /// Target installed disabled; source authenticated and quiescing.
    case preparing
    /// Source checkpointed, closed, and issued the lease.
    case leaseIssued = "lease-issued"
    /// Source PID gone and lock released; target may start.
    case sourceExitedLockReleased = "source-exited-lock-released"
    /// Target failed after the source stopped.
    case targetFailedAfterSourceStopped = "target-failed-after-source-stopped"
}

/// A complete snapshot for arbitration.
public struct ArbiterObservation: Sendable, Equatable {
    /// Direct-install LaunchAgent registration (`awaitingApproval` is not a
    /// direct-mechanism state and is judged as `registered` if presented).
    public var directRegistration: RegistrationObservation
    /// Bundled SMAppService registration.
    public var bundledRegistration: RegistrationObservation
    /// Every observed lock claim. Zero, one, or — pathologically — more.
    public var lockClaims: [LockClaim]
    /// The published descriptor observation.
    public var descriptor: DescriptorObservation
    /// The port observation. Never elects.
    public var port: PortObservation
    /// The handover phase.
    public var handover: HandoverObservation

    public init(
        directRegistration: RegistrationObservation = .none,
        bundledRegistration: RegistrationObservation = .none,
        lockClaims: [LockClaim] = [],
        descriptor: DescriptorObservation = .absent,
        port: PortObservation = .unbound,
        handover: HandoverObservation = .none
    ) {
        self.directRegistration = directRegistration
        self.bundledRegistration = bundledRegistration
        self.lockClaims = lockClaims
        self.descriptor = descriptor
        self.port = port
        self.handover = handover
    }
}

/// Why an observation is `conflicted`.
public enum ConflictReason: String, Sendable, Equatable {
    /// Two or more simultaneous lock claims.
    case multipleLockClaims = "multiple-lock-claims"
    /// A live claim whose holder cannot be authenticated.
    case unprovenOwnership = "unproven-ownership"
    /// The descriptor names a different instance than the lock owner.
    case descriptorLockDisagreement = "descriptor-lock-disagreement"
    /// A lock claim whose process is gone — indeterminate shutdown.
    case indeterminateShutdown = "indeterminate-shutdown"
    /// Something unauthenticatable holds the port while state exists that a
    /// client might otherwise trust.
    case unverifiedPortHolder = "unverified-port-holder"
    /// Both mechanisms registered and no live authenticated owner to elect —
    /// ownership cannot be proved (Kong: "it becomes a hard stop if ...
    /// ownership cannot be proved").
    case dualRegistrationUnproven = "dual-registration-unproven"
    /// A descriptor is published but nothing holds the lock. A stale
    /// descriptor alone can never authenticate a replacement process.
    case descriptorWithoutOwner = "descriptor-without-owner"
}

/// The twelve Kong arbiter states.
public enum ProviderArbiterState: Sendable, Equatable {
    case absent
    case standaloneRegistered
    case bundledAwaitingApproval
    case bundledRegistered
    case ready(providerKind: ProviderKind, instance: UUID, estate: UUID, version: String)
    /// Both mechanisms registered; exactly one authenticated compatible owner
    /// holds the lock. Continue using it; offer cleanup; never start the other.
    case duplicateRegistration(winner: ProviderKind, instance: UUID)
    case handoverPreparing
    case handoverLeaseIssued
    case handoverStarting
    /// A live authenticated provider exists but the contract is incompatible.
    case incompatible(ContractCompatibility)
    case conflicted(ConflictReason)
    case recoveryRequired

    /// The stable wire encoding of the state (self-report surface). The
    /// twelve spellings are frozen: both shells must emit identical
    /// encodings, and the c2 UI keys its honest states off them.
    public var wireEncoding: String {
        switch self {
        case .absent: return "absent"
        case .standaloneRegistered: return "standalone-registered"
        case .bundledAwaitingApproval: return "bundled-awaiting-approval"
        case .bundledRegistered: return "bundled-registered"
        case .ready: return "ready"
        case .duplicateRegistration: return "duplicate-registration"
        case .handoverPreparing: return "handover-preparing"
        case .handoverLeaseIssued: return "handover-lease-issued"
        case .handoverStarting: return "handover-starting"
        case .incompatible: return "incompatible"
        case .conflicted: return "conflicted"
        case .recoveryRequired: return "recovery-required"
        }
    }

    /// Every wire encoding, in fixed order — part of the canonical
    /// self-report, so a shell whose arbiter diverges has a different module
    /// digest.
    public static let allWireEncodings: [String] = [
        "absent", "standalone-registered", "bundled-awaiting-approval",
        "bundled-registered", "ready", "duplicate-registration",
        "handover-preparing", "handover-lease-issued", "handover-starting",
        "incompatible", "conflicted", "recovery-required",
    ]
}

/// The deterministic arbiter.
public enum ProviderArbiter {

    /// Judge one observation.
    ///
    /// Precedence, highest first: recovery, explicit handover phases,
    /// conflicts, the winner rule over the single live authenticated lock
    /// owner, registration states, absence. Port observation NEVER changes
    /// the elected winner; it can only surface a `conflicted` squatter report
    /// when nothing legitimate is running.
    public static func arbitrate(_ observation: ArbiterObservation) -> ProviderArbiterState {
        .absent // RED placeholder — the matrix tests must fail against this.
    }
}
