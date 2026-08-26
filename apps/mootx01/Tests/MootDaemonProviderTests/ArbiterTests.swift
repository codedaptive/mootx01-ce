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
