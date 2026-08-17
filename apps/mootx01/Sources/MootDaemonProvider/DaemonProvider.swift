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
        // 0. P-c2-1 construction refusal, enforced at the earliest
        //    zero-side-effect point: a PRODUCTION Keychain authority may
        //    never be composed with a proof context. (The mint site in
        //    InstallationRootAuthority additionally re-judges the lock's
        //    layout — defense in depth, both fail-closed.)
        if keychain is ProductionCredentialAuthority, configuration.proofContext != nil {
            throw DaemonProviderError.keychainFatal(.proofContextRefused)
        }
        // 1. Eligibility — the first judgment, before any side effect. The
        //    four ineligible classes exit here (Perkins P1).
        let identity = try readback.processIdentity()
        let eligibility = try ProviderEligibilityJudge.judge(identity)

        // 2. Root resolution through the injected resolver only (Perkins P2),
        //    then hygiene on the directory that will hold lock and state.
        let layout = try ProviderRootLayout.resolve(
            resolver: resolver,
            groupIdentifier: eligibility.appGroupIdentifier,
            proofContext: configuration.proofContext
        )
        try SecureFiles.ensureProviderDirectory(layout.providerDirectory)

        // 3. THE RACE GATE. A loser throws here having invoked zero
        //    Keychain/estate/bind/publish callbacks — everything below this
        //    line runs only while the exclusive lock is held (Perkins P4).
        let handle = try ProviderLock.acquire(at: layout.lockFile, context: layout.context)
        do {
            let proof = handle.proof

            // 4. K_install: read, or mint under the licensed conditions
            //    (Perkins P5).
            let rootAuthority = InstallationRootAuthority(
                keychain: keychain, eligibility: eligibility, randomBytes: randomBytes
            )
            let root = try rootAuthority.ensureRoot(lockProof: proof)

            // 5. Durable generations: first activation initializes; every
            //    later activation bumps the provider generation (Perkins P6).
            let store = GenerationStore(fileURL: layout.generationsFile)
            var generations: ProviderGenerations
            if let existing = try store.load() {
                generations = try store.advance(
                    to: existing.bumpedProvider(), expecting: existing, lockProof: proof
                )
            } else {
                generations = try store.initialize(lockProof: proof)
            }

            // 6. Estate open through the injected authority. No production
            //    conformer exists in this module (frozen package graph); the
            //    real estate host arrives with MACD-3 — until then this seam
            //    is exercised by fakes, and the ordering is what is proven.
            let estateProof = try await estate.openEstate()

            // 7. Bind, then read the bound address back (Perkins P8's
            //    exact-bind precondition consumes this proof).
            let bindProof = try await bind.bindLoopback()

            // 8. Publish: bump the descriptor generation durably FIRST, so a
            //    crash between bump and publish costs a number, never a
            //    replayable descriptor; then seal and atomically publish.
            generations = try store.advance(
                to: generations.bumpedDescriptor(), expecting: generations, lockProof: proof
            )
            let descriptor = Self.sealedDescriptor(
                configuration: configuration, root: root.bytes,
                estate: estateProof, generations: generations, publishedAt: clock()
            )
            let publisher = DescriptorPublisher(descriptorFile: layout.descriptorFile)
            try publisher.publish(
                descriptor, lockProof: proof,
                estateReady: estateProof, bind: bindProof,
                authenticator: AuthenticatorReadiness(capabilities: configuration.capabilities)
            )

            let activation = ProviderActivation(
                eligibility: eligibility,
                rootProvenance: root.provenance,
                generations: generations,
                descriptor: descriptor
            )
            self.lockHandle = handle
            self.activation = activation
            self.layout = layout
            self.installationRoot = root.bytes
            // Classification only — never a path, key, account, or root byte.
            ProviderLog.logger.info(
                "provider activated; root=\(root.provenance.rawValue, privacy: .public)"
            )
            return activation
        } catch {
            // Failure after the lock: release before propagating so a failed
            // activation never wedges the machine.
            handle.release()
            throw error
        }
    }

    /// Explicit credential rotation (Perkins P7), in this exact order:
    /// durably bump the credential generation → revoke EVERY session (and,
    /// by generation binding, every outstanding lease — a lease is only
    /// consumable when its credential generation is exactly current, so the
    /// bump burns them all) → republish the descriptor ONLY after complete
    /// readiness is re-proven.
    ///
    /// SCOPE (c1): rotation is generation bump + revocation + republication
    /// per Kong decision 1 / Perkins P7. It does NOT re-mint K_install — the
    /// `KeychainItemAuthority` seam deliberately has no update/delete
    /// primitive, so a root re-mint is structurally impossible here;
    /// post-compromise HKDF derivability of prior rungs is an accepted
    /// posture, and the root-rotation seam (under-lock update/delete with a
    /// descriptor+session+lease cascade) is an EXPLICIT DEFERRAL: MACD-2c2
    /// landed no root rotation, so the seam deliberately still has no
    /// update/delete primitive. Recorded for MACD-3.
    ///
    /// - Returns: The republished descriptor.
    public func rotateCredential() async throws -> FirstPartyDescriptor {
        guard let handle = lockHandle, let layout, let current = activation,
              let root = installationRoot else {
            // Rotation is an operation of the ACTIVE provider; without the
            // lock there is nothing whose credential could rotate.
            throw DaemonProviderError.lockUnavailable
        }
        let proof = handle.proof
        let store = GenerationStore(fileURL: layout.generationsFile)
        guard let stored = try store.load() else {
            throw DaemonProviderError.generationFault(.mismatch)
        }
        // 1. Durable credential bump — the revocation edge.
        var generations = try store.advance(
            to: stored.bumpedCredential(), expecting: stored, lockProof: proof
        )
        // 2. Revoke everything derived under the old credential BEFORE any
        //    republication: sessions actively, leases by generation binding.
        await sessions.revokeAllSessions()
        // 3. Republish only after readiness is RE-PROVEN: a fresh estate
        //    proof and a fresh bind readback, not the stale ones from
        //    activation (openEstate is idempotent readiness proof for a live
        //    estate on this seam).
        let estateProof = try await estate.openEstate()
        let bindProof = try await bind.bindLoopback()
        generations = try store.advance(
            to: generations.bumpedDescriptor(), expecting: generations, lockProof: proof
        )
        let descriptor = Self.sealedDescriptor(
            configuration: configuration, root: root,
            estate: estateProof, generations: generations, publishedAt: clock()
        )
        try DescriptorPublisher(descriptorFile: layout.descriptorFile).publish(
            descriptor, lockProof: proof,
            estateReady: estateProof, bind: bindProof,
            authenticator: AuthenticatorReadiness(capabilities: configuration.capabilities)
        )
        self.activation = ProviderActivation(
            eligibility: current.eligibility,
            rootProvenance: current.rootProvenance,
            generations: generations,
            descriptor: descriptor
        )
        ProviderLog.logger.info("credential rotated; sessions revoked before republication")
        return descriptor
    }

    /// Orderly shutdown: remove only this provider's own descriptor
    /// (instance + generation match, Perkins P8), then release the lock.
    public func shutdown() async throws -> DescriptorRemovalOutcome {
        guard let handle = lockHandle, let layout, let current = activation else {
            throw DaemonProviderError.lockUnavailable
        }
        let outcome = try DescriptorPublisher(descriptorFile: layout.descriptorFile)
            .removeOwnDescriptor(
                instanceIdentifier: current.descriptor.instanceIdentifier,
                descriptorGeneration: current.descriptor.descriptorGeneration
            )
        handle.release()
        lockHandle = nil
        activation = nil
        installationRoot = nil
        self.layout = nil
        ProviderLog.logger.info(
            "provider shut down; descriptor=\(outcome.rawValue, privacy: .public)"
        )
        return outcome
    }

    /// Build and MAC-seal the schema-2 descriptor for this configuration.
    private static func sealedDescriptor(
        configuration: DaemonProviderConfiguration,
        root: [UInt8],
        estate: EstateReadyProof,
        generations: ProviderGenerations,
        publishedAt: UInt64
    ) -> FirstPartyDescriptor {
        var descriptor = FirstPartyDescriptor(
            schemaVersion: FirstPartyAuthProtocol.descriptorSchemaVersion,
            providerIdentifier: FirstPartyAuthProtocol.providerIdentifier,
            serviceIdentifier: FirstPartyAuthProtocol.serviceIdentifier,
            endpoint: FirstPartyAuthProtocol.endpoint,
            authProtocol: FirstPartyAuthProtocol.authProtocolIdentifier,
            authKeyIdentifier: FirstPartyAuthProtocol.authKeyIdentifier,
            publishedAt: publishedAt,
            instanceIdentifier: configuration.instanceIdentifier,
            estateIdentifier: estate.estateIdentifier,
            binaryVersion: configuration.binaryVersion,
            contractRevision: FirstPartyAuthProtocol.contractRevision,
            mcpProtocolVersion: FirstPartyAuthProtocol.mcpProtocolVersion,
            capabilities: configuration.capabilities,
            credentialGeneration: generations.credential,
            descriptorGeneration: generations.descriptor,
            descriptorMAC: []
        )
        descriptor.descriptorMAC = FirstPartyAuthProtocol.hmacSHA256(
            key: FirstPartyAuthProtocol.descriptorKey(installationRoot: root),
            message: descriptor.macInput()
        )
        return descriptor
    }
}
