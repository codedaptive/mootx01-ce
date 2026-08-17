import Foundation
import AriaMCP

// MARK: - MACD-2c1 — the two-phase handover state machine (Kong decision 3)
//
// Eight steps, in order, no skipping, no repetition, no reordering. Every
// step method FIRST judges the machine's position and only then invokes its
// injected authority — so a sequencing violation refuses BEFORE the side
// effect, and the tests can prove "no callback occurs out of order" by
// counting authority invocations across every illegal call.
//
// The coordinator owns SEQUENCE, not substance: the estate, installer, and
// process authorities are injected (fakes-only in c1), the lease comes from
// `LeaseAuthority`, and target-side activation is a caller-supplied closure
// so the coordinator never constructs a provider itself.

/// The terminal disposition of a failed handover.
public enum HandoverFailureDisposition: String, Sendable, Equatable {
    /// The source configuration was restored (step 8a).
    case rolledBack = "rolled-back"
    /// No compatible rollback exists; operator recovery required (step 8b).
    case recoveryRequired = "recovery-required"
}

/// The two-phase handover coordinator.
public actor HandoverCoordinator {

    private let estate: any EstateLifecycleAuthority
    private let installer: any InstallerAuthority
    private let process: any ProcessExitAuthority
    private let sourceAuthentication: any SourceAuthenticationAuthority

    /// The machine's position. Exposed for tests and the arbiter observation.
    public private(set) var step: HandoverStep = .idle

    /// The source identity captured at step 2, bound into the lease.
    private var authenticatedSource: SigningIdentityDescriptor?

    public init(
        estate: any EstateLifecycleAuthority,
        installer: any InstallerAuthority,
        process: any ProcessExitAuthority,
        sourceAuthentication: any SourceAuthenticationAuthority
    ) {
        self.estate = estate
        self.installer = installer
        self.process = process
        self.sourceAuthentication = sourceAuthentication
    }

    /// Step 1 — install the target, disabled.
    public func prepareTarget() async throws {
        throw DaemonProviderError.unimplemented("HandoverCoordinator.prepareTarget")
    }

    /// Step 2 — authenticate the source; capture its signing identity.
    public func authenticateSource() async throws -> SigningIdentityDescriptor {
        throw DaemonProviderError.unimplemented("HandoverCoordinator.authenticateSource")
    }

    /// Step 3 — quiesce the source in the mandated order (stop writes, drain,
    /// checkpoint, close) and durably increment the provider generation via
    /// the caller-supplied generation advance.
    ///
    /// - Parameter advanceGenerations: Performs the durable increment under
    ///   the source's lock; returns the post-increment record the lease will
    ///   carry.
    public func quiesceSource(
        advanceGenerations: @Sendable () throws -> ProviderGenerations
    ) async throws -> ProviderGenerations {
        throw DaemonProviderError.unimplemented("HandoverCoordinator.quiesceSource")
    }

    /// Step 4 — issue the MACed, expiring, single-use lease.
    public func issueLease(
        authority: LeaseAuthority,
        estate estateProof: EstateReadyProof,
        sourceInstance: UUID, targetInstance: UUID,
        targetIdentity: SigningIdentityDescriptor,
        generations: ProviderGenerations,
        installationRoot: [UInt8]
    ) async throws -> HandoverLease {
        throw DaemonProviderError.unimplemented("HandoverCoordinator.issueLease")
    }

    /// Step 5 — verify source exit AND lock release through the injected
    /// process authority. Assumption is not verification.
    public func verifySourceExit() async throws {
        throw DaemonProviderError.unimplemented("HandoverCoordinator.verifySourceExit")
    }

    /// Step 6 — the target consumes the lease atomically and activates:
    /// `activateTarget` performs lock → same-estate open → bind →
    /// authenticate → publish and returns only on full readiness.
    public func consumeAndStartTarget(
        activateTarget: @Sendable () async throws -> Void
    ) async throws {
        throw DaemonProviderError.unimplemented("HandoverCoordinator.consumeAndStartTarget")
    }

    /// Step 7 — only after target readiness may the injected installer remove
    /// the source.
    public func removeSource() async throws {
        throw DaemonProviderError.unimplemented("HandoverCoordinator.removeSource")
    }

    /// Step 8 — failure handling from any post-quiescence position: invoke
    /// the injected rollback when a compatible source configuration still
    /// exists, else land in `recoveryRequired` and STOP.
    public func fail(compatibleRollbackAvailable: Bool) async throws -> HandoverFailureDisposition {
        throw DaemonProviderError.unimplemented("HandoverCoordinator.fail")
    }
}
