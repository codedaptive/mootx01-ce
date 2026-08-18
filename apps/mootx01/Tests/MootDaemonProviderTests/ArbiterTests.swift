import Foundation
import Testing
@testable import MootDaemonProvider

// MARK: - The twelve Kong states and the deterministic winner rule

private let ownerInstance = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
private let ownerEstate = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

private func liveOwner(
    kind: ProviderKind = .direct,
    version: String = "1.0.18",
    authentication: AuthenticationObservation = .authenticated,
    compatibility: ContractCompatibility = .compatible,
    liveness: ProcessLiveness = .live
) -> LockClaim {
    LockClaim(
        kind: kind, instance: ownerInstance, estate: ownerEstate, version: version,
        authentication: authentication, compatibility: compatibility, liveness: liveness
    )
}

@Suite("Arbiter states")
struct ArbiterStateTests {

    @Test("nothing observed is absent")
    func absent() {
        #expect(ProviderArbiter.arbitrate(ArbiterObservation()) == .absent)
    }

    @Test("registration-only observations map to their registration states")
    func registrationStates() {
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(directRegistration: .registered))
                == .standaloneRegistered)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(bundledRegistration: .registered))
                == .bundledRegistered)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(bundledRegistration: .awaitingApproval))
                == .bundledAwaitingApproval)
    }

    @Test("an authenticated compatible lock owner with an agreeing descriptor is ready")
    func ready() {
        let observation = ArbiterObservation(
            directRegistration: .registered,
            lockClaims: [liveOwner()],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated),
            port: .verifiedOwner
        )
        #expect(ProviderArbiter.arbitrate(observation)
                == .ready(providerKind: .direct, instance: ownerInstance, estate: ownerEstate, version: "1.0.18"))
    }

    @Test("both mechanisms registered with one authenticated owner is duplicateRegistration")
    func duplicateRegistration() {
        let observation = ArbiterObservation(
            directRegistration: .registered,
            bundledRegistration: .registered,
            lockClaims: [liveOwner(kind: .bundled)],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated)
        )
        #expect(ProviderArbiter.arbitrate(observation)
                == .duplicateRegistration(winner: .bundled, instance: ownerInstance))
    }

    @Test("handover phases surface as their dedicated states")
    func handoverStates() {
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(handover: .preparing)) == .handoverPreparing)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(handover: .leaseIssued)) == .handoverLeaseIssued)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(handover: .sourceExitedLockReleased)) == .handoverStarting)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(handover: .targetFailedAfterSourceStopped)) == .recoveryRequired)
    }

    @Test("an incompatible live authenticated provider is incompatible, with direction")
    func incompatible() {
        let newer = ArbiterObservation(
            lockClaims: [liveOwner(compatibility: .incompatibleNewer)],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated)
        )
        #expect(ProviderArbiter.arbitrate(newer) == .incompatible(.incompatibleNewer))
        let older = ArbiterObservation(
            lockClaims: [liveOwner(compatibility: .incompatibleOlder)],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated)
        )
        #expect(ProviderArbiter.arbitrate(older) == .incompatible(.incompatibleOlder))
    }

    @Test("conflict classes: multiple claims, unproven ownership, disagreement, stale claim, squatter, dual registration, orphan descriptor")
    func conflicts() {
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner(), liveOwner(kind: .bundled)]
        )) == .conflicted(.multipleLockClaims))

        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner(authentication: .unauthenticated)]
        )) == .conflicted(.unprovenOwnership))

        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner()],
            descriptor: .present(instance: UUID(), authentication: .authenticated)
        )) == .conflicted(.descriptorLockDisagreement))

        // A descriptor for the owner that itself fails authentication is a
        // disagreement too: ready demands an AUTHENTICATED descriptor.
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner()],
            descriptor: .present(instance: ownerInstance, authentication: .unauthenticated)
        )) == .conflicted(.descriptorLockDisagreement))

        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner(liveness: .exited)]
        )) == .conflicted(.indeterminateShutdown))

        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            port: .unverifiedHolder
        )) == .conflicted(.unverifiedPortHolder))

        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            directRegistration: .registered, bundledRegistration: .registered
        )) == .conflicted(.dualRegistrationUnproven))

        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            descriptor: .present(instance: UUID(), authentication: .authenticated)
        )) == .conflicted(.descriptorWithoutOwner))
    }

    @Test("an authenticated owner without a descriptor is registered, not ready")
    func ownerWithoutDescriptor() {
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            directRegistration: .registered, lockClaims: [liveOwner()]
        )) == .standaloneRegistered)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            bundledRegistration: .registered, lockClaims: [liveOwner(kind: .bundled)]
        )) == .bundledRegistered)
    }

    @Test("an owner outside every registration mechanism is conflicted, never claimed registered")
    func unregisteredOwnerConflicted() {
        // Zero registration evidence: the registered states would assert
        // evidence that does not exist, and absent would deny a live owner.
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner()]
        )) == .conflicted(.unregisteredLockOwner))
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner(kind: .bundled)]
        )) == .conflicted(.unregisteredLockOwner))
        // Cross-registration: the OTHER mechanism's record does not account
        // for this owner either.
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            bundledRegistration: .registered, lockClaims: [liveOwner(kind: .direct)]
        )) == .conflicted(.unregisteredLockOwner))
    }

    @Test("the twelve wire encodings are frozen")
    func wireEncodings() {
        #expect(ProviderArbiterState.allWireEncodings == [
            "absent", "standalone-registered", "bundled-awaiting-approval",
            "bundled-registered", "ready", "duplicate-registration",
            "handover-preparing", "handover-lease-issued", "handover-starting",
            "incompatible", "conflicted", "recovery-required",
        ])
        #expect(ProviderArbiterState.absent.wireEncoding == "absent")
        #expect(ProviderArbiterState.recoveryRequired.wireEncoding == "recovery-required")
        #expect(ProviderArbiterState.ready(
            providerKind: .direct, instance: ownerInstance, estate: ownerEstate, version: "1"
        ).wireEncoding == "ready")
    }
}

@Suite("Deterministic winner matrix (Kong decision 3)")
struct WinnerMatrixTests {

    @Test("the running authenticated compatible lock owner wins regardless of kind, version, registration, or port")
    func winnerInvariance() {
        for kind in [ProviderKind.direct, .bundled] {
            for version in ["0.9.0", "1.0.18", "3.4.5"] {
                for direct in [RegistrationObservation.none, .registered] {
                    for port in [PortObservation.unbound, .verifiedOwner, .unverifiedHolder] {
                        let observation = ArbiterObservation(
                            directRegistration: direct,
                            bundledRegistration: .none,
                            lockClaims: [liveOwner(kind: kind, version: version)],
                            descriptor: .present(instance: ownerInstance, authentication: .authenticated),
                            port: port
                        )
                        let state = ProviderArbiter.arbitrate(observation)
                        #expect(state == .ready(
                            providerKind: kind, instance: ownerInstance,
                            estate: ownerEstate, version: version
                        ), "kind=\(kind) version=\(version) direct=\(direct) port=\(port) → \(state)")
                    }
                }
            }
        }
    }

    @Test("install source is not a priority rule: the bundled owner beats a registered direct mechanism and vice versa")
    func noSourcePriority() {
        let bundledOwner = ArbiterObservation(
            directRegistration: .registered,
            lockClaims: [liveOwner(kind: .bundled)],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated)
        )
        #expect(ProviderArbiter.arbitrate(bundledOwner)
                == .duplicateRegistration(winner: .bundled, instance: ownerInstance)
                || ProviderArbiter.arbitrate(bundledOwner)
                == .ready(providerKind: .bundled, instance: ownerInstance, estate: ownerEstate, version: "1.0.18"))
        // The elected instance is the OWNER's in both encodings.
        switch ProviderArbiter.arbitrate(bundledOwner) {
        case .ready(let kind, let instance, _, _):
            #expect(kind == .bundled && instance == ownerInstance)
        case .duplicateRegistration(let winner, let instance):
            #expect(winner == .bundled && instance == ownerInstance)
        default:
            Issue.record("bundled owner was not elected")
        }
    }

    @Test("port liveness never elects: a squatter cannot make anything ready")
    func portNeverElects() {
        // A verified-looking port with no lock owner elects nothing.
        let squatterOnly = ArbiterObservation(port: .unverifiedHolder)
        #expect(ProviderArbiter.arbitrate(squatterOnly) == .conflicted(.unverifiedPortHolder))
        // And an unverified holder does not strip an authenticated owner of
        // its win.
        let ownerWithSquatterPort = ArbiterObservation(
            lockClaims: [liveOwner()],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated),
            port: .unverifiedHolder
        )
        #expect(ProviderArbiter.arbitrate(ownerWithSquatterPort)
                == .ready(providerKind: .direct, instance: ownerInstance, estate: ownerEstate, version: "1.0.18"))
    }

    @Test("an incompatible newer daemon is left running; an older one is not elected around")
    func incompatibleDirections() {
        // Newer: state says update the app; the daemon is not displaced.
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner(compatibility: .incompatibleNewer)],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated)
        )) == .incompatible(.incompatibleNewer))
        // Older: also incompatible — never silently replaced; replacement is
        // the explicit approved handover flow.
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner(compatibility: .incompatibleOlder)],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated)
        )) == .incompatible(.incompatibleOlder))
    }

    @Test("arbitration is a pure function: identical observations always agree")
    func pure() {
        let observation = ArbiterObservation(
            directRegistration: .registered,
            bundledRegistration: .registered,
            lockClaims: [liveOwner(kind: .bundled)],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated),
            port: .verifiedOwner
        )
        let first = ProviderArbiter.arbitrate(observation)
        for _ in 0..<100 {
            #expect(ProviderArbiter.arbitrate(observation) == first)
        }
    }
}

// MARK: - MACD-3B2: preference authority and repair-gate

@Suite("Preference authority (MACD-3B2)")
struct PreferenceAuthorityTests {

    // A fully-passing repair gate: all six conditions true.
    // preference comes BEFORE the Bool repair conditions in the init.
    private func repairGate(preference: ProviderPreferenceObservation) -> ArbiterObservation {
        ArbiterObservation(
            directRegistration: .registered,
            bundledRegistration: .registered,
            preference: preference,
            noAuthenticatedLockOwner: true,
            noHandoverInProgress: true,
            bundledArtifactAbsentOrUnusable: true,
            unambiguousCensus: true,
            directProviderSchemaCompatible: true,
            generationRollbackChecksPassed: true
        )
    }

    @Test("verified preference + all repair conditions resolves dual-registration to standaloneRegistered")
    func preferDirectResolvesConflict() {
        let obs = repairGate(preference: .verified(preferredKind: .direct, preferenceGeneration: 1))
        #expect(ProviderArbiter.arbitrate(obs) == .standaloneRegistered)
    }

    @Test("verified preference for bundled + repair conditions stays conflicted — bundled artifact is proven absent")
    func preferBundledUnderRepairConditionsStaysConflicted() {
        // The six repair conditions include `bundledArtifactAbsentOrUnusable = true`,
        // which proves the bundled executable is absent.  A preference for `.bundled`
        // cannot be honoured under these conditions — electing it would produce an
        // immediate launch failure.  The arbiter must fail closed to `.conflicted`.
        let obs = repairGate(preference: .verified(preferredKind: .bundled, preferenceGeneration: 2))
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }

    @Test("invalid preference + all repair conditions still returns conflicted")
    func invalidPreferenceKeepsConflict() {
        let obs = repairGate(preference: .invalid)
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }

    @Test("no preference + all repair conditions still returns conflicted")
    func noPreferenceKeepsConflict() {
        let obs = repairGate(preference: .none)
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }

    @Test("verified preference + ONE failed repair condition returns conflicted")
    func partialGateFails() {
        let pref: ProviderPreferenceObservation = .verified(preferredKind: .direct, preferenceGeneration: 1)
        // Each of the six conditions individually blocks the preference when false.
        // preference precedes all Bool repair fields in the init — keep that order.
        for observation in [
            // noAuthenticatedLockOwner = false (default)
            ArbiterObservation(
                directRegistration: .registered, bundledRegistration: .registered,
                preference: pref,
                noHandoverInProgress: true, bundledArtifactAbsentOrUnusable: true,
                unambiguousCensus: true, directProviderSchemaCompatible: true,
                generationRollbackChecksPassed: true
            ),
            // noHandoverInProgress = false (default)
            ArbiterObservation(
                directRegistration: .registered, bundledRegistration: .registered,
                preference: pref,
                noAuthenticatedLockOwner: true,
                bundledArtifactAbsentOrUnusable: true,
                unambiguousCensus: true, directProviderSchemaCompatible: true,
                generationRollbackChecksPassed: true
            ),
            // bundledArtifactAbsentOrUnusable = false (default)
            ArbiterObservation(
                directRegistration: .registered, bundledRegistration: .registered,
                preference: pref,
                noAuthenticatedLockOwner: true, noHandoverInProgress: true,
                unambiguousCensus: true, directProviderSchemaCompatible: true,
                generationRollbackChecksPassed: true
            ),
            // unambiguousCensus = false (default)
            ArbiterObservation(
                directRegistration: .registered, bundledRegistration: .registered,
                preference: pref,
                noAuthenticatedLockOwner: true, noHandoverInProgress: true,
                bundledArtifactAbsentOrUnusable: true,
                directProviderSchemaCompatible: true,
                generationRollbackChecksPassed: true
            ),
            // directProviderSchemaCompatible = false (default)
            ArbiterObservation(
                directRegistration: .registered, bundledRegistration: .registered,
                preference: pref,
                noAuthenticatedLockOwner: true, noHandoverInProgress: true,
                bundledArtifactAbsentOrUnusable: true, unambiguousCensus: true,
                generationRollbackChecksPassed: true
            ),
            // generationRollbackChecksPassed = false (default)
            ArbiterObservation(
                directRegistration: .registered, bundledRegistration: .registered,
                preference: pref,
                noAuthenticatedLockOwner: true, noHandoverInProgress: true,
                bundledArtifactAbsentOrUnusable: true, unambiguousCensus: true,
                directProviderSchemaCompatible: true
            ),
        ] {
            #expect(ProviderArbiter.arbitrate(observation) == .conflicted(.dualRegistrationUnproven),
                    "one failed condition must still produce conflicted")
        }
    }

    @Test("verified preference does NOT affect a live authenticated owner")
    func preferenceIgnoredForLiveOwner() {
        // The preference is authority level 4; a live level-3 owner wins.
        let obs = ArbiterObservation(
            directRegistration: .registered,
            lockClaims: [liveOwner(kind: .bundled)],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated),
            preference: .verified(preferredKind: .direct, preferenceGeneration: 99)
        )
        // The BUNDLED owner wins (winner rule) even though preference says direct.
        #expect(ProviderArbiter.arbitrate(obs)
                == .ready(providerKind: .bundled, instance: ownerInstance, estate: ownerEstate, version: "1.0.18"))
    }

    @Test("verified preference does NOT affect a handover in progress")
    func preferenceIgnoredDuringHandover() {
        for phase in [HandoverObservation.preparing, .leaseIssued, .sourceExitedLockReleased] {
            let obs = ArbiterObservation(
                handover: phase,
                preference: .verified(preferredKind: .direct, preferenceGeneration: 1)
            )
            let state = ProviderArbiter.arbitrate(obs)
            #expect(state != .standaloneRegistered && state != .bundledRegistered,
                    "handover phase \(phase) must not be overridden by preference")
        }
    }

    @Test("verified preference does NOT affect a recovery-required state")
    func preferenceIgnoredInRecovery() {
        let obs = ArbiterObservation(
            handover: .targetFailedAfterSourceStopped,
            preference: .verified(preferredKind: .direct, preferenceGeneration: 1)
        )
        #expect(ProviderArbiter.arbitrate(obs) == .recoveryRequired)
    }

    @Test("all existing 30+ single-mechanism cases are unaffected by a default preference (.none)")
    func existingCasesUnchangedWithDefaultPreference() {
        // Preference defaults to .none and repair conditions to false — no
        // existing arbitration outcome changes.  A spot-check of the most
        // common states.
        #expect(ProviderArbiter.arbitrate(ArbiterObservation()) == .absent)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(directRegistration: .registered))
                == .standaloneRegistered)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(bundledRegistration: .registered))
                == .bundledRegistered)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(bundledRegistration: .awaitingApproval))
                == .bundledAwaitingApproval)
        #expect(ProviderArbiter.arbitrate(ArbiterObservation(
            lockClaims: [liveOwner()],
            descriptor: .present(instance: ownerInstance, authentication: .authenticated)
        )) == .ready(providerKind: .direct, instance: ownerInstance, estate: ownerEstate, version: "1.0.18"))
    }
}

// MARK: - MACD-3B2: per-condition repair gate tests (six separate tests, as required)
//
// The mission requires one test per repair condition to make the gate contract
// explicit and grep-searchable.  The `partialGateFails` loop above exercises
// the same six cases together; these tests each name exactly one failing
// condition so a future breakage is immediately attributable.

@Suite("Repair gate — per-condition (MACD-3B2)")
struct RepairGatePerConditionTests {

    private let pref: ProviderPreferenceObservation =
        .verified(preferredKind: .direct, preferenceGeneration: 1)

    /// Both registrations present; all conditions true except the one under
    /// test.  Helper keeps each test body terse.
    private func allButOne(
        noAuthenticatedLockOwner: Bool = true,
        noHandoverInProgress: Bool = true,
        bundledArtifactAbsentOrUnusable: Bool = true,
        unambiguousCensus: Bool = true,
        directProviderSchemaCompatible: Bool = true,
        generationRollbackChecksPassed: Bool = true
    ) -> ArbiterObservation {
        ArbiterObservation(
            directRegistration: .registered,
            bundledRegistration: .registered,
            preference: pref,
            noAuthenticatedLockOwner: noAuthenticatedLockOwner,
            noHandoverInProgress: noHandoverInProgress,
            bundledArtifactAbsentOrUnusable: bundledArtifactAbsentOrUnusable,
            unambiguousCensus: unambiguousCensus,
            directProviderSchemaCompatible: directProviderSchemaCompatible,
            generationRollbackChecksPassed: generationRollbackChecksPassed
        )
    }

    @Test("absent noAuthenticatedLockOwner blocks preference repair")
    func missingNoAuthenticatedLockOwnerBlocksRepair() {
        let obs = allButOne(noAuthenticatedLockOwner: false)
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }

    @Test("absent noHandoverInProgress blocks preference repair")
    func missingNoHandoverInProgressBlocksRepair() {
        // NOTE: noHandoverInProgress = false means caller cannot confirm there
        // is no in-progress handover — the arbiter fails closed to conflicted,
        // not to a handover phase (the handover observation itself is .none here,
        // so steps 1–2 are not triggered; it is the repair condition that fails).
        let obs = allButOne(noHandoverInProgress: false)
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }

    @Test("absent bundledArtifactAbsentOrUnusable blocks preference repair")
    func missingBundledArtifactAbsentBlocksRepair() {
        // The caller cannot confirm the bundled artifact is gone — the repair
        // condition is the key signal for the app-removal scenario (the
        // SMAppService entry may still appear .registered after the app is
        // removed, so the arbiter requires an explicit caller assertion rather
        // than inferring from the registration field).
        let obs = allButOne(bundledArtifactAbsentOrUnusable: false)
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }

    @Test("absent unambiguousCensus blocks preference repair (ambiguous census gates preference)")
    func missingUnambiguousCensusBlocksRepair() {
        // A preference can request convergence but NEVER elects when multiple
        // estates are present (MULTIPLE_ESTATES_HARD_STOP gate from the design).
        // The caller signals ambiguity by leaving unambiguousCensus = false;
        // the arbiter fails closed to conflicted, not to a preference outcome.
        let obs = allButOne(unambiguousCensus: false)
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }

    @Test("absent directProviderSchemaCompatible blocks preference repair")
    func missingDirectSchemaCompatibleBlocksRepair() {
        // Prevents preference from electing an incompatible provider in the
        // no-live-owner path.  Schema compatibility must be explicitly confirmed
        // by the caller — the arbiter cannot check the schema itself.
        let obs = allButOne(directProviderSchemaCompatible: false)
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }

    @Test("absent generationRollbackChecksPassed blocks preference repair")
    func missingGenerationRollbackChecksBlocksRepair() {
        // The store's monotonic generation check has already run by the time
        // the caller builds the observation.  If the check failed (rollback
        // detected), the caller leaves this false and the arbiter fails closed.
        let obs = allButOne(generationRollbackChecksPassed: false)
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }
}

// MARK: - MACD-3B2: stale bundled-preferred scenario

@Suite("Stale preference after app removal (MACD-3B2)")
struct StaleBundledPreferenceTests {

    @Test("stale bundled preference cannot block recovery-required state")
    func staleBundledPreferenceCannotBlockRecovery() {
        // Design scenario: the app is removed but (a) the SMAppService
        // registration still appears as .registered (stale) and (b) the on-disk
        // preference still names .bundled (stale preference file).  When the
        // handover target subsequently fails after the source stopped, the
        // machine must enter recoveryRequired — the stale preference MUST NOT
        // prevent recovery.
        //
        // Authority order: recoveryRequired (handover failure) is level 1 —
        // ABOVE every preference, registration, and repair condition.
        let obs = ArbiterObservation(
            directRegistration: .registered,
            bundledRegistration: .registered,  // stale SMAppService entry
            handover: .targetFailedAfterSourceStopped,
            preference: .verified(preferredKind: .bundled, preferenceGeneration: 7),
            noAuthenticatedLockOwner: true,
            noHandoverInProgress: false,  // handover phase IS in progress (failed)
            bundledArtifactAbsentOrUnusable: true,
            unambiguousCensus: true,
            directProviderSchemaCompatible: true,
            generationRollbackChecksPassed: true
        )
        // Recovery-required wins.  The stale bundled preference is irrelevant.
        #expect(ProviderArbiter.arbitrate(obs) == .recoveryRequired)
    }

    @Test("stale bundled preference in dual-registration without recovery produces conflicted, not bundledRegistered")
    func staleBundledPreferenceDualRegistrationNoRecovery() {
        // Same stale-preference scenario but WITHOUT a recovery-required
        // handover phase.  The caller cannot confirm bundledArtifactAbsentOrUnusable
        // (the app removal hasn't been verified yet) — the arbiter MUST fail
        // closed to conflicted rather than electing the stale bundled preference.
        // This ensures a stale preference file cannot unilaterally resolve a
        // dual-registration conflict when the bundled artifact may still be live.
        let obs = ArbiterObservation(
            directRegistration: .registered,
            bundledRegistration: .registered,  // stale SMAppService entry
            preference: .verified(preferredKind: .bundled, preferenceGeneration: 7),
            noAuthenticatedLockOwner: true,
            noHandoverInProgress: true,
            bundledArtifactAbsentOrUnusable: false,  // caller cannot confirm app is gone
            unambiguousCensus: true,
            directProviderSchemaCompatible: true,
            generationRollbackChecksPassed: true
        )
        #expect(ProviderArbiter.arbitrate(obs) == .conflicted(.dualRegistrationUnproven))
    }
}
