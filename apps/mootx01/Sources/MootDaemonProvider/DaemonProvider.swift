import Foundation
import AriaMCP
import OSLog

// MARK: - MACD-2c1 — the provider orchestrator
//
// One actor owns the activation pipeline and enforces its order (Perkins P4):
//
//   eligibility → root resolution → hygiene → EXCLUSIVE LOCK → K_install →
//   generations → injected estate open → bind readback → descriptor publish
//
// Everything left of the lock performs no side effect; everything right of it
// happens only while the lock is held. The race loser exits at the lock with
// zero authority callbacks — a property the tests prove with counting fakes
// and the live proof re-proves across two signed processes.

/// Logging: OSLog, subsystem per project convention, category = module name,
/// and NOTHING dynamic that could carry a path, key, account, or lease value
/// (Perkins P11). Every dynamic interpolation in this module is `.public`
/// AND drawn from closed enum/classification sets, so redaction never depends
/// on a call-site remembering a privacy annotation for secret material —
/// secrets simply never reach the logger.
enum ProviderLog {
    static let logger = Logger(subsystem: "com.mootx01.kit", category: "MootDaemonProvider")
}

/// What a completed activation proved.
public struct ProviderActivation: Sendable, Equatable {
    /// The judged eligibility.
    public let eligibility: ProviderEligibility
    /// Whether the installation root was found or minted.
    public let rootProvenance: InstallationRoot.Provenance
    /// The durable generations after activation.
    public let generations: ProviderGenerations
    /// The published descriptor.
    public let descriptor: FirstPartyDescriptor

    public init(
        eligibility: ProviderEligibility,
        rootProvenance: InstallationRoot.Provenance,
        generations: ProviderGenerations,
        descriptor: FirstPartyDescriptor
    ) {
        self.eligibility = eligibility
        self.rootProvenance = rootProvenance
        self.generations = generations
        self.descriptor = descriptor
    }
}

/// Static configuration for one provider instance.
public struct DaemonProviderConfiguration: Sendable, Equatable {
    /// This process's instance identity.
    public let instanceIdentifier: UUID
    /// The daemon binary's marketing version.
    public let binaryVersion: String
    /// Capability wire spellings this provider will advertise.
    public let capabilities: [String]
    /// Optional proof-context UUID string (see `ProviderRootLayout.resolve`).
    public let proofContext: String?

    public init(
        instanceIdentifier: UUID,
        binaryVersion: String,
        capabilities: [String],
        proofContext: String? = nil
    ) {
        self.instanceIdentifier = instanceIdentifier
        self.binaryVersion = binaryVersion
        self.capabilities = capabilities.sorted()
        self.proofContext = proofContext
    }
}

/// The provider orchestrator.
public actor DaemonProvider {

    private let configuration: DaemonProviderConfiguration
    private let readback: any EntitlementReadback
    private let resolver: any ProviderRootResolving
    private let keychain: any KeychainItemAuthority
    private let estate: any EstateLifecycleAuthority
    private let bind: any BindAuthority
    private let sessions: any SessionRevocationAuthority
    private let clock: ProviderClock
    private let randomBytes: ProviderRandomness

    /// The held lock while active.
    private var lockHandle: ProviderLockHandle?
    /// The last activation, while active.
    private var activation: ProviderActivation?
    /// The resolved layout, while active.
    private var layout: ProviderRootLayout?
    /// The validated installation root, while active. Held in-actor only;
    /// never logged, never serialized (Perkins P11).
    private var installationRoot: [UInt8]?

    public init(
        configuration: DaemonProviderConfiguration,
        readback: any EntitlementReadback,
        resolver: any ProviderRootResolving,
        keychain: any KeychainItemAuthority,
        estate: any EstateLifecycleAuthority,
        bind: any BindAuthority,
        sessions: any SessionRevocationAuthority,
        clock: @escaping ProviderClock,
        randomBytes: @escaping ProviderRandomness
    ) {
        self.configuration = configuration
        self.readback = readback
        self.resolver = resolver
        self.keychain = keychain
        self.estate = estate
        self.bind = bind
        self.sessions = sessions
        self.clock = clock
        self.randomBytes = randomBytes
    }

    /// Run the full ordered activation pipeline.
    ///
    /// - Returns: The activation record.
    /// - Throws: The first gate's refusal. A refusal BEFORE the lock has
    ///   performed zero side effects; a loser AT the lock has invoked zero
    ///   Keychain/estate/bind/publish callbacks (Perkins P1/P4).
    public func activate() async throws -> ProviderActivation {
        throw DaemonProviderError.unimplemented("DaemonProvider.activate")
    }

    /// Explicit credential rotation (Perkins P7), in this exact order:
    /// durably bump the credential generation → revoke EVERY session (and,
    /// by generation binding, every outstanding lease) → republish the
    /// descriptor ONLY after complete readiness is re-proven.
    ///
    /// - Returns: The republished descriptor.
    public func rotateCredential() async throws -> FirstPartyDescriptor {
        throw DaemonProviderError.unimplemented("DaemonProvider.rotateCredential")
    }

    /// Orderly shutdown: remove only this provider's own descriptor
    /// (instance + generation match), then release the lock.
    public func shutdown() async throws -> DescriptorRemovalOutcome {
        throw DaemonProviderError.unimplemented("DaemonProvider.shutdown")
    }
}
