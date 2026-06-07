// VerbsTests.swift
//
// Per-type coverage for the nine substrate verbs (cookbook § 10),
// the Substrate composition reference in Verbs.swift. Mirrors the
// behavior set asserted by the Rust `glref-rust-verbs.rs` test
// module so the two legs pin the same verb semantics:
//
//   capture / propose / mutate / withdraw / expunge / recall, plus
//   HLC advancement on audit emission and the forbidden-combination
//   gate inside capture.
//
// PORT NOTE: the Rust port asserts deterministic RowId(u128) values
// across identical call sequences. The Swift reference assigns
// `UUID()` (random) per capture, so row-ID determinism is a Rust-only
// port property, NOT a Swift behavior. The Swift-faithful assertion
// here is row-ID uniqueness.

import Foundation
import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

@Suite("Substrate verbs (cookbook §10)")
struct VerbsTests {

    private func freshSubstrate() -> Substrate {
        Substrate(estateUuid: UUID(uuidString: "12345678-9ABC-DEF0-0000-000000000000")!,
                  hlc: HLC(physicalTime: 0, logicalCount: 0, nodeID: 1))
    }

    private let dummyFP = Fingerprint256.zero

    private func anchor() -> LatticeAnchor {
        LatticeAnchor(udcCode: 0x0a0a_0000_0000_0000, qidPointer: 0x1234)
    }

    // MARK: - capture

    @Test func testCaptureCreatesActiveRow() {
        var s = freshSubstrate()
        guard case .success(let id) = s.capture(
            nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP,
            actor: "test") else { Issue.record("expected capture success"); return }
        #expect(s.rows[id]?.state == .active)
        #expect(s.rowCountActive == 1)
        #expect(s.auditEvents.count == 1)
        #expect(s.auditEvents[0].verb == "capture")
    }

    @Test func testCaptureProposalCreatesPending() {
        var s = freshSubstrate()
        guard case .success(let id) = s.propose(
            adjectiveBitmap: 1, operationalBitmap: 0, provenanceBitmap: 0,
            latticeAnchor: anchor(), fingerprint: dummyFP, actor: "agent")
        else { Issue.record("expected propose success"); return }
        #expect(s.rows[id]?.state == .pending)
    }

    @Test func testCaptureWithoutAnchorFails() {
        var s = freshSubstrate()
        let res = s.capture(
            nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: LatticeAnchor(udcCode: 0, qidPointer: 0),
            fingerprint: dummyFP, actor: "test")
        #expect(res == .failure(.missingLatticeAnchor))
    }

    // MARK: - mutate

    @Test func testMutateConfirmPendingToAccepted() {
        var s = freshSubstrate()
        // state=pending(1), trust=canonical(3) so accepted+trust is
        // legal under S-1 (accepted ⇒ trust ≥ canonical).
        let adjPending: Int64 = 1 | (3 << 18)
        guard case .success(let id) = s.capture(
            nounType: .proposal, adjectiveBitmap: adjPending, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP,
            actor: "a") else { Issue.record("expected capture success"); return }
        // state=accepted(3), trust=canonical(3)
        let adjAccepted: Int64 = 3 | (3 << 18)
        guard case .success = s.mutate(
            rowId: id, mutationKind: .confirm, newAdjectiveBitmap: adjAccepted,
            actor: "user") else { Issue.record("expected mutate success"); return }
        #expect(s.rows[id]?.state == .accepted)
        #expect(s.auditEvents.count == 2)
        #expect(s.auditEvents[1].verb.contains("confirm"))
    }

    @Test func testMutateRejectsInvalidTransition() {
        var s = freshSubstrate()
        guard case .success(let id) = s.capture(
            nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP,
            actor: "a") else { Issue.record("expected capture success"); return }
        // Active → pending is not a legal transition.
        let adjPending: Int64 = 1
        let res = s.mutate(rowId: id, mutationKind: .confirm,
                           newAdjectiveBitmap: adjPending, actor: "user")
        guard case .failure(.invalidStateTransition) = res else {
            Issue.record("expected invalidStateTransition"); return
        }
    }

    // MARK: - forbidden-combination gate inside capture

    @Test func testForbiddenSecretPublicComboRejected() {
        var s = freshSubstrate()
        // sensitivity=48 (bits 6-11) AND exportability=32 (bits 12-17).
        let adj: Int64 = (48 << 6) | (32 << 12)
        let res = s.capture(
            nounType: .drawer, adjectiveBitmap: adj, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP,
            actor: "test")
        guard case .failure(.forbiddenStateCombination) = res else {
            Issue.record("expected forbiddenStateCombination"); return
        }
    }

    // MARK: - forbidden-combination gate inside mutate (canonical
    // rule set: the oracle delegates to ForbiddenCombinations.check,
    // so accepted rows are held to S-1 and S-4 — cookbook § 9.5.1 /
    // § 9.5.4 — exactly as on the LocusKit mutation path)

    /// Capture a pending proposal carrying `upper` (sensitivity /
    /// exportability / trust bits), then confirm it to accepted with
    /// the same upper bits. Returns the mutate result so tests can
    /// assert the oracle's accepted-row verdict.
    private func confirmToAccepted(upperBits upper: Int64)
            -> Result<(), SubstrateError>? {
        var s = freshSubstrate()
        guard case .success(let id) = s.capture(
            nounType: .proposal, adjectiveBitmap: upper | 1, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP,
            actor: "a") else {
            Issue.record("expected pending capture success"); return nil
        }
        return s.mutate(rowId: id, mutationKind: .confirm,
                        newAdjectiveBitmap: upper | 3, actor: "user")
    }

    @Test func testAcceptedVerbatimTrustRejected() {
        // S-1: accepted + trust=verbatim(0) → illegal (both the old
        // and the canonical policy forbade it).
        guard case .failure(.forbiddenStateCombination) =
                confirmToAccepted(upperBits: 0 << 18) else {
            Issue.record("expected forbiddenStateCombination"); return
        }
    }

    @Test func testAcceptedObservedTrustRejected() {
        // S-1: accepted + trust=observed(1) → illegal (was legal
        // under the pre-convergence oracle).
        guard case .failure(.forbiddenStateCombination) =
                confirmToAccepted(upperBits: 1 << 18) else {
            Issue.record("expected forbiddenStateCombination"); return
        }
    }

    @Test func testAcceptedImportedTrustRejected() {
        // S-1: accepted + trust=imported(2) → illegal (was legal
        // under the pre-convergence oracle).
        guard case .failure(.forbiddenStateCombination) =
                confirmToAccepted(upperBits: 2 << 18) else {
            Issue.record("expected forbiddenStateCombination"); return
        }
    }

    @Test func testAcceptedCanonicalTrustAllowed() {
        // S-1 boundary, inclusive: accepted + trust=canonical(3) → legal.
        guard case .success = confirmToAccepted(upperBits: 3 << 18) else {
            Issue.record("expected mutate success"); return
        }
    }

    @Test func testAcceptedRestrictedSensitivityRejected() {
        // S-4: accepted + sensitivity=restricted(32) → illegal even
        // with canonical trust (was legal under the pre-convergence
        // oracle, which had no S-4).
        guard case .failure(.forbiddenStateCombination) =
                confirmToAccepted(upperBits: (32 << 6) | (3 << 18)) else {
            Issue.record("expected forbiddenStateCombination"); return
        }
    }

    @Test func testAcceptedElevatedSensitivityAllowed() {
        // S-4 boundary, inclusive: accepted + sensitivity=elevated(16) → legal.
        guard case .success =
                confirmToAccepted(upperBits: (16 << 6) | (3 << 18)) else {
            Issue.record("expected mutate success"); return
        }
    }

    // MARK: - parity: the Verbs oracle agrees with
    // ForbiddenCombinations.check (the authority; the enumerated
    // cases above are the human-readable cross-check)

    /// True iff `ForbiddenCombinations.check` throws for the tuple.
    private func canonicalRejects(state: RowState, adjective: Int64) -> Bool {
        let fields = BitmapFields(
            adjective: UInt64(bitPattern: adjective),
            operational: 0, provenance: 0)
        do {
            try ForbiddenCombinations.check(state: state, fields: fields)
            return false
        } catch { return true }
    }

    @Test func testOracleParityWithCanonicalCheck() {
        // Representative grid over the adjective fields .check reads:
        // trust (bits 18-23) spans the S-1 boundary, sensitivity
        // (bits 6-11) spans the S-4 boundary and secret(48),
        // exportability (bits 12-17) spans public(32) for I-22.
        // The oracle is private, so parity is driven through its two
        // callers — capture (state .active / .pending) and mutate
        // (state .accepted) — proving the public verb surface is
        // faithful to the canonical rule set.
        let trusts: [Int64] = [0, 1, 2, 3, 4]
        let sensitivities: [Int64] = [0, 16, 32, 48]
        let exportabilities: [Int64] = [0, 32]

        for trust in trusts {
            for sens in sensitivities {
                for exp in exportabilities {
                    let upper = (sens << 6) | (exp << 12) | (trust << 18)

                    // Leg 1 — capture path, state .active (state bits 0).
                    var s1 = freshSubstrate()
                    let captured = s1.capture(
                        nounType: .drawer, adjectiveBitmap: upper,
                        operationalBitmap: 0, provenanceBitmap: 0,
                        latticeAnchor: anchor(), fingerprint: dummyFP,
                        actor: "parity")
                    let captureLegal: Bool
                    switch captured {
                    case .success: captureLegal = true
                    case .failure(.forbiddenStateCombination): captureLegal = false
                    case .failure(let other):
                        Issue.record("unexpected capture failure \(other) for adjective \(upper)")
                        continue
                    }
                    #expect(captureLegal == !canonicalRejects(state: .active, adjective: upper),
                            "capture/.check parity broken for adjective \(upper)")

                    // Leg 2 — mutate path, pending → accepted.
                    var s2 = freshSubstrate()
                    switch s2.capture(
                        nounType: .proposal, adjectiveBitmap: upper | 1,
                        operationalBitmap: 0, provenanceBitmap: 0,
                        latticeAnchor: anchor(), fingerprint: dummyFP,
                        actor: "parity") {
                    case .success(let id):
                        let mutated = s2.mutate(
                            rowId: id, mutationKind: .confirm,
                            newAdjectiveBitmap: upper | 3, actor: "parity")
                        let mutateLegal: Bool
                        switch mutated {
                        case .success: mutateLegal = true
                        case .failure(.forbiddenStateCombination): mutateLegal = false
                        case .failure(let other):
                            Issue.record("unexpected mutate failure \(other) for adjective \(upper | 3)")
                            continue
                        }
                        #expect(mutateLegal == !canonicalRejects(state: .accepted, adjective: upper | 3),
                                "mutate/.check parity broken for adjective \(upper | 3)")
                    case .failure(.forbiddenStateCombination):
                        // Pending capture itself blocked (I-22 tuples):
                        // must agree with .check at .pending.
                        #expect(canonicalRejects(state: .pending, adjective: upper | 1),
                                "pending capture rejected a tuple .check permits: \(upper | 1)")
                    case .failure(let other):
                        Issue.record("unexpected pending capture failure \(other) for adjective \(upper | 1)")
                    }
                }
            }
        }
    }

    // MARK: - expunge

    @Test func testExpungeTombstonesAndClearsContent() {
        var s = freshSubstrate()
        guard case .success(let id) = s.capture(
            nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP,
            content: Data("hello".utf8), actor: "test")
        else { Issue.record("expected capture success"); return }
        guard case .success = s.expunge(rowId: id, reason: "GDPR-request", actor: "user")
        else { Issue.record("expected expunge success"); return }
        #expect(s.rows[id]?.state == .tombstoned)
        #expect(s.rows[id]?.content == nil)
        #expect(s.rowCountActive == 0)
    }

    @Test func testExpungeTombstonedRowFails() {
        var s = freshSubstrate()
        guard case .success(let id) = s.capture(
            nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP,
            actor: "test") else { Issue.record("expected capture success"); return }
        guard case .success = s.expunge(rowId: id, reason: "first", actor: "user")
        else { Issue.record("expected first expunge success"); return }
        let res = s.expunge(rowId: id, reason: "second", actor: "user")
        guard case .failure(.alreadyTombstoned) = res else {
            Issue.record("expected alreadyTombstoned"); return
        }
    }

    // MARK: - withdraw

    @Test func testWithdrawActiveToWithdrawn() {
        var s = freshSubstrate()
        guard case .success(let id) = s.capture(
            nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP,
            actor: "test") else { Issue.record("expected capture success"); return }
        guard case .success = s.withdraw(rowId: id, actor: "user")
        else { Issue.record("expected withdraw success"); return }
        #expect(s.rows[id]?.state == .withdrawn)
        // Re-confirm to active per cookbook (withdrawn, confirm → active).
        let adjActive: Int64 = 0
        guard case .success = s.mutate(
            rowId: id, mutationKind: .confirm, newAdjectiveBitmap: adjActive,
            actor: "user") else { Issue.record("expected re-confirm success"); return }
        #expect(s.rows[id]?.state == .active)
    }

    // MARK: - recall

    @Test func testRecallFiltersByPredicate() {
        var s = freshSubstrate()
        _ = s.capture(nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
                      provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP, actor: "a")
        _ = s.capture(nounType: .ambientSample, adjectiveBitmap: 0, operationalBitmap: 0,
                      provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP, actor: "a")
        let drawers = s.recall(matching: { $0.nounType == .drawer })
        #expect(drawers.count == 1)
    }

    // MARK: - HLC advancement on audit emission

    @Test func testAuditEventsAdvanceHLC() {
        var s = freshSubstrate()
        let h0 = s.hlc
        _ = s.capture(nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
                      provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP, actor: "a")
        let h1 = s.hlc
        _ = s.capture(nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
                      provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP, actor: "a")
        let h2 = s.hlc
        #expect(h0 < h1)
        #expect(h1 < h2)
    }

    // MARK: - row identity (Swift-faithful counterpart to the Rust
    // deterministic_row_ids test; see PORT NOTE at top of file)

    @Test func testCaptureRowIdsAreUnique() {
        var s = freshSubstrate()
        guard case .success(let id1) = s.capture(
            nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP, actor: "a"),
              case .success(let id2) = s.capture(
            nounType: .drawer, adjectiveBitmap: 0, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP, actor: "a")
        else { Issue.record("expected two capture successes"); return }
        // Swift assigns a fresh UUID per row; two captures never collide.
        #expect(id1 != id2)
        #expect(s.rows.count == 2)
    }
}
