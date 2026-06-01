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
// here is row-ID uniqueness; the divergence is recorded in the
// completion report Discoveries.

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
        // state=pending(1), trust=imported(2) so accepted+trust is legal.
        let adjPending: Int64 = 1 | (2 << 18)
        guard case .success(let id) = s.capture(
            nounType: .proposal, adjectiveBitmap: adjPending, operationalBitmap: 0,
            provenanceBitmap: 0, latticeAnchor: anchor(), fingerprint: dummyFP,
            actor: "a") else { Issue.record("expected capture success"); return }
        // state=accepted(3), trust=imported(2)
        let adjAccepted: Int64 = 3 | (2 << 18)
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
