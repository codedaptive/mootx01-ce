// RowStateAutomatonTests.swift
//
// Per-type coverage for the row-state finite-state automaton
// (cookbook § 9) in RowStateAutomaton.swift: the transition table,
// `validate`, and the I-22 / S-1 / S-5 forbidden-combination checks.
//
// Mirrors the behavior set asserted by the Rust
// `glref-rust-row_state.rs` test module (mod tests + i22_tests) so
// the two legs pin the same automaton semantics.

import Testing
@testable import SubstrateLib
import SubstrateML
import SubstrateKernel
import SubstrateTypes

@Suite("RowStateAutomaton transitions + forbidden combinations (cookbook §9)")
struct RowStateAutomatonTests {

    /// Cookbook v0.6 §2.3 packing: state bits 0-5, sensitivity bits
    /// 6-11, exportability bits 12-17, trust bits 18-23.
    private func fields(stateRaw: UInt64 = 0, trustRaw: UInt64 = 0,
                        sensRaw: UInt64 = 0) -> BitmapFields {
        let adj = stateRaw | (sensRaw << 6) | (trustRaw << 18)
        return BitmapFields(adjective: adj, operational: 0, provenance: 0)
    }

    // MARK: - transition table

    @Test func testPendingToActiveViaObserve() {
        #expect(RowStateAutomaton.transition(from: .pending, on: .observe) == .active)
    }

    @Test func testAcceptedCannotBeTombstoned() {
        // S-3: enforced by absence from the transition table.
        #expect(RowStateAutomaton.transition(from: .accepted, on: .tombstone) == nil)
    }

    @Test func testMutateActiveStaysActive() {
        #expect(RowStateAutomaton.transition(from: .active, on: .mutate) == .active)
    }

    @Test func testDecayedCanReviveOnObserve() {
        #expect(RowStateAutomaton.transition(from: .decayed, on: .observe) == .active)
    }

    @Test func testAllClusterBStatesReviveOnObserve() {
        // revive surface (cookbook §9.3): every Cluster-B historical state
        // restores to active via .observe. Superseded is admitted here; the
        // lineage-conflict rule is enforced at LocusKit's revive guard.
        for from: RowState in [.decayed, .withdrawn, .expired, .superseded] {
            #expect(RowStateAutomaton.transition(from: from, on: .observe) == .active,
                    "\(from) should revive to .active via .observe")
        }
    }

    @Test func testTerminalClusterCStatesDoNotRevive() {
        // Rejected/tombstoned have no .observe → .active edge; revive is
        // refused at the automaton. Accepted is live audit-grade, not
        // historical — also no revive edge.
        #expect(RowStateAutomaton.transition(from: .rejected, on: .observe) == nil)
        #expect(RowStateAutomaton.transition(from: .tombstoned, on: .observe) == nil)
        #expect(RowStateAutomaton.transition(from: .accepted, on: .observe) == nil)
    }

    @Test func testValidateRejectsIllegalTransitions() {
        // Pending --promote--> is illegal (must observe first).
        do {
            _ = try RowStateAutomaton.validate(from: .pending, on: .promote,
                                               targetingFields: fields())
            Issue.record("expected illegalTransition")
        } catch RowStateError.illegalTransition {
            // expected
        } catch {
            Issue.record("expected illegalTransition, got \(error)")
        }
    }

    // MARK: - S-1: accepted requires canonical trust

    @Test func testAcceptedRequiresCanonicalTrust() {
        // §2.3 raws: accepted=3, trust.verbatim=0, trust.canonical=3.
        // accepted with trust=verbatim(0) must fail.
        do {
            try ForbiddenCombinations.check(
                state: .accepted,
                fields: fields(stateRaw: UInt64(RowState.accepted.rawValue), trustRaw: 0, sensRaw: 0))
            Issue.record("expected S-1 violation for accepted + trust=verbatim")
        } catch RowStateError.violatesInvariant {
            // expected
        } catch {
            Issue.record("expected violatesInvariant, got \(error)")
        }
        // Same row with trust=canonical(3) must pass.
        #expect(throws: Never.self) {
            try ForbiddenCombinations.check(
                state: .accepted,
                fields: fields(stateRaw: UInt64(RowState.accepted.rawValue), trustRaw: 3, sensRaw: 0))
        }
    }

    // MARK: - S-5 (defused): tombstone preserves bitmaps

    @Test func testTombstonedPreservesBitmaps() {
        // S-5 defused 2026-05-27: bitmaps are audit substrate and MUST
        // persist on tombstone; the content blob is what gets zeroed.
        // Non-zero metadata must be ACCEPTED until F17 reinstates the
        // expunge_completed_flag check.
        #expect(throws: Never.self) {
            try ForbiddenCombinations.check(
                state: .tombstoned,
                fields: BitmapFields(adjective: 1, operational: 0, provenance: 0))
        }
        #expect(throws: Never.self) {
            try ForbiddenCombinations.check(
                state: .tombstoned,
                fields: BitmapFields(adjective: 0, operational: 0, provenance: 0xCAFE))
        }
    }

    // MARK: - I-22: secret cannot be exportable

    @Test func testI22SecretCannotBeExportable() {
        // sensitivity=secret(48) bits 6-11, exportability=public(32) bits 12-17.
        let adj: UInt64 = (48 << 6) | (32 << 12)
        do {
            try ForbiddenCombinations.check(
                state: .active,
                fields: BitmapFields(adjective: adj, operational: 0, provenance: 0))
            Issue.record("expected I-22 violation")
        } catch RowStateError.violatesInvariant {
            // expected
        } catch {
            Issue.record("expected violatesInvariant, got \(error)")
        }
    }

    @Test func testI22SecretNonPublicOk() {
        // secret(48), exportability=private(0) → legal.
        let adj: UInt64 = 48 << 6
        #expect(throws: Never.self) {
            try ForbiddenCombinations.check(
                state: .active,
                fields: BitmapFields(adjective: adj, operational: 0, provenance: 0))
        }
    }
}
