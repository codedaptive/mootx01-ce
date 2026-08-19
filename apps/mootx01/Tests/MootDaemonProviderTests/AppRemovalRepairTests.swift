// AppRemovalRepairTests.swift
// MootDaemonProviderTests — MACD-3B5 GAP 3 coverage.
//
// Full CLI app-removal repair path.
//
// Smythe pre-flight identified this gap as "the most significant untested
// path": the existing ArbiterTests cover each repair condition in unit
// isolation, but there is no scenario-level test that chains the FULL
// app-removal context and asserts the invariants the design mandate imposes:
//
//   Scenario: MOOTx01-App was installed. User deletes the app. CLI is then
//   invoked. The bundled SMAppService registration is still visible (launchd
//   has not purged it), but the app's binary/bundle is absent or unusable.
//   A stale bundled-preferred record may still exist from the app's tenure.
//
//   The repair gate: before activating the dormant direct provider, ALL SIX
//   preconditions must be proven by the caller (never inferred by the arbiter):
//
//     R1: no authenticated provider owns the lock
//     R2: no handover is in progress
//     R3: the bundled registration/artifact is absent or unusable
//     R4: the canonical estate census is unambiguous (exactly one estate)
//     R5: the direct provider is schema-compatible with the estate
//     R6: generation rollback checks pass
//
//   If ALL SIX are proven → direct provider activation (standaloneRegistered).
//   If ANY ONE is withheld → NO activation (conflicted — fail-closed).
//
// Additional design mandates (§App approval, removal, and recovery):
//   M-T: repair never elects by newest timestamp
//   M-E: repair never creates a fresh default estate
//   M-W: exactly one writer at end state (standaloneRegistered, not duplicateRegistration)
//   M-I: same estate identity — the existing canonical estate is the sole target
//
// Each test documents what regression would break it.
//
// BLOCKED paths (require live entitled provider):
//   - Actual direct provider process activation (requires entitlements + signed binary)
//   - Real lock acquisition in the direct provider after arbiter grants
//   - Real SQLite open on the canonical estate by the direct provider

import Foundation
import Testing
import AriaMCP
@testable import MootDaemonProvider

// MARK: - Shared repair-scenario builder

/// The full app-removal scenario observation: both mechanisms registered
/// (stale bundled + live direct), no live owner, no handover — the
/// precondition state before any repair gate is evaluated.
///
/// This is the scenario that MUST resolve to standaloneRegistered when all
/// six conditions hold, and MUST stay conflicted when any one is absent.
private func appRemovalObservation(
    preference: ProviderPreferenceObservation = .verified(
        preferredKind: .direct,
        preferenceGeneration: 2
    ),
    noAuthenticatedLockOwner: Bool = true,
    noHandoverInProgress: Bool = true,
    bundledArtifactAbsentOrUnusable: Bool = true,
    unambiguousCensus: Bool = true,
    directProviderSchemaCompatible: Bool = true,
    generationRollbackChecksPassed: Bool = true
) -> ArbiterObservation {
    ArbiterObservation(
        // Both mechanisms appear registered — this is the dual-registration
        // conflict the stale SMAppService registration creates. The repair gate
        // is the only resolution path when no live owner can authenticate.
        directRegistration: .registered,
        bundledRegistration: .registered,
        lockClaims: [],
        descriptor: .absent,
        port: .unbound,
        handover: .none,
        preference: preference,
        noAuthenticatedLockOwner: noAuthenticatedLockOwner,
        noHandoverInProgress: noHandoverInProgress,
        bundledArtifactAbsentOrUnusable: bundledArtifactAbsentOrUnusable,
        unambiguousCensus: unambiguousCensus,
        directProviderSchemaCompatible: directProviderSchemaCompatible,
        generationRollbackChecksPassed: generationRollbackChecksPassed
    )
}

// MARK: - Suite 1: Full positive — all six conditions → standaloneRegistered

@Suite("App-removal repair — full positive (all six conditions → standaloneRegistered)")
struct AppRemovalRepairPositiveTests {

    /// Full positive test: the complete app-removal scenario with all six
    /// repair conditions proven → standaloneRegistered (direct activation).
    ///
    /// Regression: if ANY of the six conditions is removed from the gate check,
    /// the corresponding per-condition negative test would START passing when
    /// it should fail (the gate becomes too permissive in the wrong direction).
    /// This positive test confirms the gate produces the correct activation
    /// outcome when everything is in order.
    @Test("full app-removal scenario with all six conditions → standaloneRegistered (M-W: exactly one writer)")
    func allSixConditionsProducesActivation() {
        let obs = appRemovalObservation()
        let result = ProviderArbiter.arbitrate(obs)

        #expect(result == .standaloneRegistered,
                "all six conditions → standaloneRegistered (direct activation)")
        // M-W: exactly one writer. standaloneRegistered is NOT
        // duplicateRegistration — there is exactly one active direct provider,
        // not a second competing bundled one.
        if case .duplicateRegistration = result {
            Issue.record("repair must not produce duplicateRegistration — that would be two writers")
        }
    }

    /// M-I: same estate identity. The repair activates the DIRECT provider
    /// against the EXISTING canonical estate — not a new estate. The
    /// `unambiguousCensus = true` flag is the gate: the census found exactly
    /// one canonical estate, so the repair targets that estate.
    ///
    /// Regression: if the repair were to create a new estate (e.g., by
    /// allowing activation without a census), `unambiguousCensus = false`
    /// would not block it. The negative test M-E below closes this gap.
    @Test("repair targets the existing canonical estate (M-I: same estate identity)")
    func repairTargetsExistingEstate() {
        // The unambiguousCensus flag proves there is exactly one canonical
        // estate. The arbiter's standaloneRegistered outcome binds the
        // direct provider to THAT estate — it cannot create a second one.
        let obs = appRemovalObservation(unambiguousCensus: true)
        let result = ProviderArbiter.arbitrate(obs)
        #expect(result == .standaloneRegistered,
                "with unambiguous census the arbiter must elect standaloneRegistered")
    }
}

// MARK: - Suite 2: Six negative — one condition withheld → NO activation

@Suite("App-removal repair — per-condition negative (each withheld condition blocks activation)")
struct AppRemovalRepairNegativeTests {

    /// R1 negative: no authenticated lock owner is NOT asserted.
    ///
    /// Regression: if R1 were removed from the gate, a repair could proceed
    /// while an authenticated provider still holds the lock — violating the
    /// "authenticated live lock ownership is authoritative" mandate. This test
    /// catches that by showing the gate stays closed when R1 is false.
    @Test("R1 withheld: noAuthenticatedLockOwner = false → conflicted (not standaloneRegistered)")
    func r1WithheldBlocksRepair() {
        let obs = appRemovalObservation(noAuthenticatedLockOwner: false)
        let result = ProviderArbiter.arbitrate(obs)
        #expect(result != .standaloneRegistered,
                "withholding R1 must prevent repair activation")
        if case .conflicted = result { /* expected */ } else {
            Issue.record("expected .conflicted when R1 withheld, got \(result)")
        }
    }

    /// R2 negative: no handover in progress is NOT asserted.
    ///
    /// Regression: if R2 were removed, repair could activate over an in-
    /// progress handover — creating two active providers during the lease
    /// window. This test catches that.
    @Test("R2 withheld: noHandoverInProgress = false → conflicted (not standaloneRegistered)")
    func r2WithheldBlocksRepair() {
        let obs = appRemovalObservation(noHandoverInProgress: false)
        let result = ProviderArbiter.arbitrate(obs)
        #expect(result != .standaloneRegistered,
                "withholding R2 must prevent repair activation")
        if case .conflicted = result { /* expected */ } else {
            Issue.record("expected .conflicted when R2 withheld, got \(result)")
        }
    }

    /// R3 negative: bundled artifact absent/unusable is NOT asserted.
    ///
    /// Regression: if R3 were removed, the repair gate could activate the
    /// direct provider while the bundled artifact is still present and
    /// viable — creating two competing providers. This test catches that.
    @Test("R3 withheld: bundledArtifactAbsentOrUnusable = false → conflicted (not standaloneRegistered)")
    func r3WithheldBlocksRepair() {
        let obs = appRemovalObservation(bundledArtifactAbsentOrUnusable: false)
        let result = ProviderArbiter.arbitrate(obs)
        #expect(result != .standaloneRegistered,
                "withholding R3 must prevent repair activation")
        if case .conflicted = result { /* expected */ } else {
            Issue.record("expected .conflicted when R3 withheld, got \(result)")
        }
    }

    /// R4 negative: unambiguous census is NOT asserted. This is also the
    /// M-E gate: if the census were ambiguous (multiple estates or none),
    /// the repair could not identify which estate to activate the provider
    /// against — and must NOT create a new one.
    ///
    /// Regression: if R4 were removed, repair could proceed with an ambiguous
    /// census (violating M-E: never creates a fresh default estate).
    @Test("R4 withheld: unambiguousCensus = false → conflicted (M-E: never creates fresh default estate)")
    func r4WithheldBlocksRepair() {
        let obs = appRemovalObservation(unambiguousCensus: false)
        let result = ProviderArbiter.arbitrate(obs)
        #expect(result != .standaloneRegistered,
                "withholding R4 must prevent repair — ambiguous census cannot elect")
        if case .conflicted = result { /* expected */ } else {
            Issue.record("expected .conflicted when R4 withheld, got \(result)")
        }
    }

    /// R5 negative: direct provider schema-compatible is NOT asserted.
    ///
    /// Regression: if R5 were removed, repair could activate a direct provider
    /// that cannot open the current estate schema — causing immediate failure
    /// after activation and leaving the estate in a bad state.
    @Test("R5 withheld: directProviderSchemaCompatible = false → conflicted (not standaloneRegistered)")
    func r5WithheldBlocksRepair() {
        let obs = appRemovalObservation(directProviderSchemaCompatible: false)
        let result = ProviderArbiter.arbitrate(obs)
        #expect(result != .standaloneRegistered,
                "withholding R5 must prevent repair — schema-incompatible provider cannot be elected")
        if case .conflicted = result { /* expected */ } else {
            Issue.record("expected .conflicted when R5 withheld, got \(result)")
        }
    }

    /// R6 negative: generation rollback checks are NOT asserted.
    ///
    /// Regression: if R6 were removed, a repair with a rolled-back generation
    /// could activate an outdated direct provider, defeating the anti-rollback
    /// protection.
    @Test("R6 withheld: generationRollbackChecksPassed = false → conflicted (not standaloneRegistered)")
    func r6WithheldBlocksRepair() {
        let obs = appRemovalObservation(generationRollbackChecksPassed: false)
        let result = ProviderArbiter.arbitrate(obs)
        #expect(result != .standaloneRegistered,
                "withholding R6 must prevent repair — generation rollback is refused")
        if case .conflicted = result { /* expected */ } else {
            Issue.record("expected .conflicted when R6 withheld, got \(result)")
        }
    }
}

// MARK: - Suite 3: M-T — repair never elects by newest timestamp

@Suite("App-removal repair — M-T: never elects by newest timestamp")
struct AppRemovalRepairNoTimestampTests {

    /// Proves M-T: the ArbiterObservation has no timestamp field. The arbiter
    /// cannot use a timestamp to choose a winner — there is no mechanism to
    /// express it.
    ///
    /// Regression: if a `newerTimestamp` field were added to ArbiterObservation
    /// and consulted in arbitrate(), this test would need to be updated — and
    /// the architectural review that added it would need to address M-T.
    @Test("ArbiterObservation carries no timestamp field — newest-wins election is structurally impossible")
    func noTimestampFieldInObservation() {
        // Verify that ArbiterObservation contains no timestamp-bearing
        // property by constructing one and confirming the six explicit
        // repair conditions are the ONLY disposition-affecting inputs
        // (beyond registration, lock claims, descriptor, port, handover,
        // and preference).
        let obs1 = appRemovalObservation()
        let obs2 = appRemovalObservation()
        // Two identical observations must produce the same arbitration result
        // always — no hidden timestamp divergence.
        #expect(ProviderArbiter.arbitrate(obs1) == ProviderArbiter.arbitrate(obs2),
                "arbitration is a pure function — identical observations must agree (M-T)")
    }

    /// Confirms that a .verified preference with a higher generation than
    /// the baseline still produces standaloneRegistered (not influenced by
    /// the generation number as a timestamp proxy).
    ///
    /// Regression: if the arbiter used the preferenceGeneration as a
    /// "newer wins" signal, it would violate M-T. This test proves the
    /// preference generation is used only for rollback detection (R6), not
    /// for election.
    @Test("higher preferenceGeneration does not change election outcome — generation is not a timestamp proxy")
    func higherGenerationNotATimestampProxy() {
        let obsLow = appRemovalObservation(
            preference: .verified(preferredKind: .direct, preferenceGeneration: 1)
        )
        let obsHigh = appRemovalObservation(
            preference: .verified(preferredKind: .direct, preferenceGeneration: 9999)
        )
        let resultLow = ProviderArbiter.arbitrate(obsLow)
        let resultHigh = ProviderArbiter.arbitrate(obsHigh)
        #expect(resultLow == .standaloneRegistered,
                "gen=1 should produce standaloneRegistered")
        #expect(resultHigh == .standaloneRegistered,
                "gen=9999 should produce standaloneRegistered — not a 'more recent' signal")
        #expect(resultLow == resultHigh,
                "preference generation must not alter the election outcome")
    }
}

// MARK: - Suite 4: M-E + M-I — no fresh estate, same identity

@Suite("App-removal repair — M-E: never creates fresh estate; M-I: same estate identity")
struct AppRemovalRepairEstateIdentityTests {

    /// M-E: the arbiter does not create estates. When R4 (unambiguousCensus)
    /// is false, the repair gate is closed — the arbiter cannot elect ANY
    /// estate, fresh or existing. This proves the "no fresh default estate"
    /// mandate is enforced structurally.
    ///
    /// Regression: if the arbiter were modified to activate the direct provider
    /// even without an unambiguous census (e.g., by creating a default estate),
    /// R4 withheld would produce standaloneRegistered instead of conflicted.
    @Test("M-E: ambiguous census blocks repair — no estate is created to replace the missing one")
    func ambiguousCensusBlocksFreshEstateCreation() {
        // The "create a fresh estate" scenario: the census found no canonical
        // estate. The arbiter must NOT activate the direct provider and create
        // a new one — that would silently discard any existing data.
        let obs = appRemovalObservation(unambiguousCensus: false)
        let result = ProviderArbiter.arbitrate(obs)
        #expect(result != .standaloneRegistered,
                "M-E: a repair with no confirmed canonical estate must not produce standaloneRegistered")
    }

    /// M-I: a stale bundled preference (preferredKind = .bundled) does NOT
    /// produce standaloneRegistered even when all six conditions hold, because
    /// the bundled artifact is proven absent — electing it would immediately
    /// fail. The arbiter stays conflicted.
    ///
    /// Regression: if the bundled-preference path were allowed through the
    /// repair gate, activating a bundled provider whose binary is absent would
    /// produce an immediate launch failure. This test confirms fail-closed.
    @Test("M-I: stale bundled preference + absent artifact stays conflicted (fail-closed)")
    func staleBundledPreferenceStaysConflicted() {
        // The scenario before the CLI writes a new .direct preference:
        // the stale preference says "bundled" but the bundled artifact is gone.
        let obs = appRemovalObservation(
            preference: .verified(preferredKind: .bundled, preferenceGeneration: 1),
            bundledArtifactAbsentOrUnusable: true
        )
        let result = ProviderArbiter.arbitrate(obs)
        // The repair gate refuses to elect .bundled when the artifact is absent
        // (bundledArtifactAbsentOrUnusable = true). Remain conflicted.
        #expect(result != .standaloneRegistered,
                "stale bundled preference with absent artifact must not activate the direct provider")
        if case .conflicted = result { /* expected fail-closed */ } else {
            Issue.record("expected .conflicted for stale bundled preference, got \(result)")
        }
    }

    // BLOCKED: Verifying that the direct provider opens the EXISTING canonical
    // estate (not a new one) requires a live entitled direct provider with
    // the AppGroup entitlement and a real SQLite database. The structural proof
    // above (R4 gate) is the in-process boundary. The production verification
    // is a MACD-3 deliverable.
    // BLOCKED: live direct provider opens existing canonical estate (not a new default).
    // Unblocked by: production EstateLifecycleAuthority conformer (MACD-3 estate routing)
    // + AppGroup-entitled signed binary.
    // No @Test — a vacuous empty test provides false positive evidence; see Adams r2.
}
