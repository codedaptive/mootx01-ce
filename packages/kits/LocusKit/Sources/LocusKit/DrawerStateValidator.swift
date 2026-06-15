import Foundation
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import SubstrateLib
import SubstrateTypes

/// Validates a proposed `State` transition against cookbook §9.2 via
/// `SubstrateLib.RowStateAutomaton` — the single canonical implementation
/// of the row-state finite-state automaton (mandate M1: SubstrateLib
/// owns substrate math; LocusKit consumes).
///
/// F14 cascade (2026-05-27): replaced LocusKit's parallel `TransitionVerb`
/// enum and `isLegal` table (which permitted 4 transitions cookbook §9
/// disallows — `contested→superseded`, `withdrawn/expired/superseded→active`,
/// `any→accepted`, and `any→tombstoned` including the S-3 violation
/// `accepted→tombstoned`). All four tighten under SubstrateLib's
/// transition map, which encodes the cookbook §9.2 spec exactly.
///
/// This is a pure function — no I/O, no side effects. It is called by
/// `DrawerStore.mutateState` before any SQLite write so an illegal
/// transition surfaces as a thrown error and zero rows change. S-3
/// (cookbook §9.5: Accepted MUST NOT transition to Tombstoned) is
/// enforced by SubstrateLib's transition table omitting the entry.
///
/// For safety-invariant enforcement on the FIELD level (S-1: Accepted
/// requires trust ≥ Canonical; forbidden bitmap combinations per I-22),
/// callers can route directly through `RowStateAutomaton.validate(from:on:targetingFields:)`
/// with the row's adjective/operational/provenance bitmaps. This file
/// only validates transition legality, not field-level invariants.
public enum DrawerStateValidator {

    /// Validate a proposed state transition.
    ///
    /// - Parameters:
    ///   - from: current state of the row.
    ///   - to: proposed new state. Must equal the state produced by
    ///     applying `via` to `from` per cookbook §9.2's transition map.
    ///   - via: the verb initiating the transition. Use `RowVerb` cases
    ///     directly (cookbook canonical verb namespace).
    /// - Throws: `LocusKitError.disciplineViolation` if the `(from, via)`
    ///   pair has no entry in cookbook §9.2 OR if the entry's target
    ///   state differs from the passed `to`.
    public static func validate(
        from: State,
        to: State,
        via: RowVerb
    ) throws {
        // Bridge LocusKit.State → SubstrateLib.RowState (raws identical
        // per cookbook §2.3; both share the F11 scale-gapped layout).
        guard let priorRowState = RowState(rawValue: UInt8(from.rawValue)) else {
            throw LocusKitError.disciplineViolation(
                from: from.rawValue,
                to: to.rawValue,
                reason: "internal: cannot bridge State.\(from) (raw \(from.rawValue)) to RowState"
            )
        }
        // Cookbook §9.2 transition lookup — Option<RowState>.
        guard let nextRowState = RowStateAutomaton.transition(from: priorRowState, on: via) else {
            throw LocusKitError.disciplineViolation(
                from: from.rawValue,
                to: to.rawValue,
                reason: "no legal transition \(from) via .\(via) in cookbook §9.2"
            )
        }
        // Verb determines target; the caller's `to` must agree.
        guard Int(nextRowState.rawValue) == to.rawValue else {
            throw LocusKitError.disciplineViolation(
                from: from.rawValue,
                to: to.rawValue,
                reason: "verb .\(via) from \(from) produces \(nextRowState) (raw \(nextRowState.rawValue)), not \(to)"
            )
        }
    }

    /// S-1 cascade (2026-05-27): validate transition AND field-level
    /// invariants in one shot. Routes through SubstrateLib's
    /// `RowStateAutomaton.validate(from:on:targetingFields:)` which
    /// composes `transition()` with `ForbiddenCombinations.check`,
    /// enforcing cookbook §9.5.1 (accepted ⇒ trust ≥ canonical) and
    /// §9.5.2 (withdrawn/rejected raw-value invariants).
    ///
    /// `DrawerStore.mutateState` calls this overload; legality-only
    /// callers (e.g. `StateTransitionTests`) continue using the
    /// 3-argument overload above.
    ///
    /// - Parameters:
    ///   - from: current state of the row.
    ///   - to: proposed new state.
    ///   - via: the verb initiating the transition.
    ///   - fields: POST-WRITE BitmapFields (caller MUST pass the
    ///     adjective bitmap with the new state already encoded in
    ///     bits 0–5; SubstrateLib's S-2 check reads back the state
    ///     from the bitmap and asserts it matches the next state).
    /// - Throws: `LocusKitError.disciplineViolation` on illegal
    ///   transition OR on field invariant violation. Invariant
    ///   violations surface with `reason` prefixed `"invariant violation: "`.
    public static func validate(
        from: State,
        to: State,
        via: RowVerb,
        targetingFields fields: BitmapFields
    ) throws {
        guard let priorRowState = RowState(rawValue: UInt8(from.rawValue)) else {
            throw LocusKitError.disciplineViolation(
                from: from.rawValue,
                to: to.rawValue,
                reason: "internal: cannot bridge State.\(from) (raw \(from.rawValue)) to RowState"
            )
        }

        let nextRowState: RowState
        do {
            nextRowState = try RowStateAutomaton.validate(
                from: priorRowState, on: via, targetingFields: fields)
        } catch RowStateError.illegalTransition(let s, let v) {
            throw LocusKitError.disciplineViolation(
                from: from.rawValue,
                to: to.rawValue,
                reason: "no legal transition \(s) via .\(v) in cookbook §9.2"
            )
        } catch RowStateError.violatesInvariant(let msg) {
            throw LocusKitError.disciplineViolation(
                from: from.rawValue,
                to: to.rawValue,
                reason: "invariant violation: \(msg)"
            )
        }

        // Verb determines target; the caller's `to` must agree.
        guard Int(nextRowState.rawValue) == to.rawValue else {
            throw LocusKitError.disciplineViolation(
                from: from.rawValue,
                to: to.rawValue,
                reason: "verb .\(via) from \(from) produces \(nextRowState) (raw \(nextRowState.rawValue)), not \(to)"
            )
        }
    }
}
