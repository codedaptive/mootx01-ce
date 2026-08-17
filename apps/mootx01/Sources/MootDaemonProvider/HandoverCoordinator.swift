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

    /// The step the machine will accept next — what a sequencing violation
    /// reports as `expected`. Terminal states accept nothing and report
    /// themselves.
    private var nextLegalStep: HandoverStep {
        switch step {
        case .idle: return .targetPrepared
        case .targetPrepared: return .sourceAuthenticated
        case .sourceAuthenticated: return .estateClosed
        case .estateClosed: return .leaseIssued
        case .leaseIssued: return .sourceExited
        case .sourceExited: return .targetReady
        case .targetReady: return .sourceRemoved
        case .sourceRemoved, .rolledBack, .recoveryRequired: return step
        }
    }

    /// Refuse unless `requested` is exactly the next legal step. Runs BEFORE
    /// the step's authority is invoked, always.
    private func gate(_ requested: HandoverStep) throws {
        guard nextLegalStep == requested, step != requested else {
            throw DaemonProviderError.handoverSequenceViolation(
                expected: nextLegalStep, requested: requested
            )
        }
    }

    /// Step 1 — install the target, disabled.
    public func prepareTarget() async throws {
        try gate(.targetPrepared)
        try await installer.prepareTargetDisabled()
        step = .targetPrepared
    }

    /// Step 2 — authenticate the source; capture its signing identity.
    public func authenticateSource() async throws -> SigningIdentityDescriptor {
        try gate(.sourceAuthenticated)
        let identity = try await sourceAuthentication.authenticateSource()
        authenticatedSource = identity
        step = .sourceAuthenticated
        return identity
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
        try gate(.estateClosed)
        // The order is the contract: writes stop before draining, the drain
        // completes before the checkpoint, the checkpoint lands before the
        // close. Reordering any pair loses acknowledged work.
        try await estate.stopWrites()
        try await estate.drain()
        try await estate.checkpoint()
        try await estate.closeEstate()
        let generations = try advanceGenerations()
        step = .estateClosed
        return generations
    }

    /// Step 4 — issue the MACed, expiring, single-use lease, bound to the
    /// authenticated source identity captured at step 2.
    public func issueLease(
        authority: LeaseAuthority,
        estate estateProof: EstateReadyProof,
        sourceInstance: UUID, targetInstance: UUID,
        targetIdentity: SigningIdentityDescriptor,
        generations: ProviderGenerations,
        installationRoot: [UInt8]
    ) async throws -> HandoverLease {
        try gate(.leaseIssued)
        guard let source = authenticatedSource else {
            // Unreachable through the gate (step 2 sets it), but a lease
            // without a source identity must never exist.
            throw DaemonProviderError.handoverSequenceViolation(
                expected: .sourceAuthenticated, requested: .leaseIssued
            )
        }
        let lease = authority.issue(
            estate: estateProof,
            sourceInstance: sourceInstance, targetInstance: targetInstance,
            sourceIdentity: source, targetIdentity: targetIdentity,
            generations: generations,
            installationRoot: installationRoot
        )
        step = .leaseIssued
        return lease
    }

    /// Step 5 — verify source exit AND lock release through the injected
    /// process authority. Assumption is not verification: a still-running
    /// source refuses and the machine does not advance.
    public func verifySourceExit() async throws {
        try gate(.sourceExited)
        try await process.verifySourceExited()
        try await process.verifyLockReleased()
        step = .sourceExited
    }

    /// Step 6 — the target consumes the lease atomically and activates:
    /// `activateTarget` performs lock → same-estate open → bind →
    /// authenticate → publish and returns only on full readiness.
    public func consumeAndStartTarget(
        activateTarget: @Sendable () async throws -> Void
    ) async throws {
        try gate(.targetReady)
        try await activateTarget()
        step = .targetReady
    }

    /// Step 7 — only after target readiness may the injected installer remove
    /// the source.
    public func removeSource() async throws {
        try gate(.sourceRemoved)
        try await installer.removeSource()
        step = .sourceRemoved
    }

    /// Step 8 — failure handling from any in-flight position: invoke the
    /// injected rollback when a compatible source configuration still exists,
    /// else land in `recoveryRequired` and STOP (no rollback callback — a
    /// rollback across an unsupported schema/auth downgrade is the one thing
    /// worse than a stalled handover).
    public func fail(compatibleRollbackAvailable: Bool) async throws -> HandoverFailureDisposition {
        switch step {
        case .idle, .sourceRemoved, .rolledBack, .recoveryRequired:
            // Nothing in flight to fail, or already terminal.
            throw DaemonProviderError.handoverSequenceViolation(
                expected: nextLegalStep, requested: .rolledBack
            )
        default:
            break
        }
        if compatibleRollbackAvailable {
            try await installer.rollbackToSource()
            step = .rolledBack
            return .rolledBack
        }
        step = .recoveryRequired
        return .recoveryRequired
    }
}
