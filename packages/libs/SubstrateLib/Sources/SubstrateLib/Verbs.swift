// Verbs.swift
//
// The nine substrate verbs per cookbook § 10:
//   capture, reanchor, mutate, withdraw, expunge,
//   recall, propose, associate, learn.
//
// The verbs are the substrate's public mutation API. Each verb:
//
//   1. Validates preconditions (row-state automaton via § 9.9
//      DrawerStateValidator; isLegalRowState forbidden-
//      combination check per § 9.5 / I-22).
//   2. Computes the new row state.
//   3. Emits an audit event (§ 5) under the current HLC.
//   4. Updates derived state (matrix tier § 6; fingerprint
//      recompute via § 3.6).
//   5. Return shapes vary: `capture`, `propose`, `associate`, and
//      `learn` return `Result<RowId, SubstrateError>`; `reanchor`,
//      `mutate`, `withdraw`, and `expunge` return
//      `Result<(), SubstrateError>`; `recall` returns `[Row]`.
//
// This file is the verb orchestration layer. It imports the live
// `SubstrateTypes` package and this directory's own `RowStateAutomaton`.
//
// Production substrates re-implement the verb dispatch with
// platform-appropriate persistence (SQLite tail, mmap'd bit-slice
// tensor); this reference is the scalar oracle for verb semantics.
//
// Cookbook references:
//   § 9    Row-state finite-state automaton (preconditions)
//   § 10   The nine verbs (this file)
//   § 5    Audit log as CRDT (audit emissions)
//   § 6    Matrix tier (derived-state updates)
//   § 3    Fingerprint (recompute on bitmap mutation)

import Foundation
import SubstrateTypes

// MARK: - Noun types and row layout
//
// Phase 6.3 (decision 2026-05-28 §6.6): NounType and
// LatticeAnchor moved to SubstrateTypes. They remain visible
// here via `import SubstrateTypes`.

/// Row identifier alias. Canonically a `UUID`; Block 2a/2b
/// reference files spell this `RowId` for symmetry with the
/// Rust port's `RowId(u128)` newtype. They are wire-compatible
/// (UUID is 128 bits).
public typealias RowId = UUID

// Phase 6.6 (decision 2026-05-28 §6.6): Row moved to
// SubstrateTypes. Visible here via `import SubstrateTypes`.

// MARK: - Errors

public enum SubstrateError: Error, Equatable {
    case invalidStateTransition(from: RowState, to: RowState, verb: String)
    case missingLatticeAnchor
    case invalidNounType
    case rowNotFound(UUID)
    case forbiddenStateCombination(String)
    case alreadyTombstoned(UUID)
    case proposalRequired
    case nonProposalCannotUseProposalVerb
}

// MARK: - Audit event
//
// Phase 6.6 (decision 2026-05-28 §6.6): AuditEvent moved to
// SubstrateTypes. Visible here via `import SubstrateTypes`.

// MARK: - The Substrate

/// In-memory substrate reference. Production code persists `rows`
/// and `auditLog` to SQLite + the bit-slice tensor (§ 4.1-4.3);
/// the reference keeps them in memory for testability.
public struct Substrate {
    public let estateUuid: UUID
    public var rows: [UUID: Row]
    public var auditEvents: [AuditEvent]   // appended; treat as G-Set
    public var matrixF: MatrixF
    public var matrixO: MatrixO
    public var matrixT: MatrixT
    public var hlc: HLC
    public var rowCountActive: Int64       // not-tombstoned row count

    public init(estateUuid: UUID, hlc: HLC) {
        self.estateUuid = estateUuid
        self.rows = [:]
        self.auditEvents = []
        self.matrixF = MatrixF()
        self.matrixO = MatrixO()
        self.matrixT = MatrixT()
        self.hlc = hlc
        self.rowCountActive = 0
    }

    // ============================================================
    // § 10.1 — capture
    // ============================================================

    /// Create a new row. State defaults to .active for non-proposal
    /// noun types and .pending for proposals.
    ///
    /// - Parameter ts: Caller-supplied epoch seconds for telemetry.
    ///   Pass `Date().timeIntervalSince1970` at the verb boundary.
    ///   Defaults to 0.0 so existing callers need no changes.
    ///   SubstrateLib never reads a clock internally — determinism
    ///   is preserved across all callers.
    @discardableResult
    public mutating func capture(
        nounType: NounType,
        adjectiveBitmap: Int64,
        operationalBitmap: Int64,
        provenanceBitmap: Int64,
        latticeAnchor: LatticeAnchor,
        fingerprint: Fingerprint256,
        lineageId: UUID? = nil,
        content: Data? = nil,
        actor: String = "capture",
        ts: Double = 0.0
    ) -> Result<UUID, SubstrateError> {
        if latticeAnchor.isNull { return .failure(.missingLatticeAnchor) }

        let initialState: RowState = (nounType == .proposal) ? .pending : .active

        // § 9.5 / I-22: forbidden combinations check.
        if let err = isLegalRowState(state: initialState,
                                      adjective: adjectiveBitmap,
                                      operational: operationalBitmap) {
            return .failure(err)
        }

        let rowId = UUID()
        let row = Row(id: rowId, nounType: nounType, state: initialState,
                       adjectiveBitmap: adjectiveBitmap,
                       operationalBitmap: operationalBitmap,
                       provenanceBitmap: provenanceBitmap,
                       fingerprint: fingerprint,
                       latticeAnchor: latticeAnchor,
                       lineageId: lineageId, content: content)
        rows[rowId] = row
        if initialState != .tombstoned { rowCountActive &+= 1 }

        // F-matrix increment: every (field, bit) the row has set
        // contributes +1.
        do {
            var f = self.matrixF
            let rowBitmaps = RowBitmaps(
                adjective: adjectiveBitmap,
                operational: operationalBitmap,
                provenance: provenanceBitmap)
            f.applyRow(delta: 1, bitVector: rowBitmaps.bitVector())
            self.matrixF = f
        }
        // O-matrix increment: every ordered pair of (field, value)
        // in the row contributes +1.
        let fieldValues = extractFieldValues(adj: adjectiveBitmap,
                                              op: operationalBitmap,
                                              prov: provenanceBitmap)
        matrixO.applyRow(delta: 1, fieldValues: fieldValues)

        // Audit emission.
        appendAudit(verb: "capture", rowId: rowId,
                     before: nil,
                     after: (adjectiveBitmap, operationalBitmap, provenanceBitmap),
                     beforeAnchor: nil, afterAnchor: latticeAnchor, actor: actor)

        // Telemetry — off-path cost: single atomic load + branch; no
        // metric constructed when monitoring is disabled (the default).
        emitVerbCaptureCount(nounTypeRaw: "\(nounType.rawValue)", ts: ts)

        return .success(rowId)
    }

    // ============================================================
    // § 10.2 — reanchor
    // ============================================================

    @discardableResult
    public mutating func reanchor(
        rowId: UUID,
        newLatticeAnchor: LatticeAnchor,
        actor: String = "reanchor",
        ts: Double = 0.0
    ) -> Result<(), SubstrateError> {
        guard var row = rows[rowId] else { return .failure(.rowNotFound(rowId)) }
        if row.state == .tombstoned { return .failure(.alreadyTombstoned(rowId)) }
        if newLatticeAnchor.isNull { return .failure(.missingLatticeAnchor) }

        let oldAnchor = row.latticeAnchor
        row.latticeAnchor = newLatticeAnchor
        // Production code recomputes Block 1 of fingerprint here.
        // The reference leaves fingerprint recompute to the caller
        // via Fingerprint256 + SimHash; the verb just records the
        // anchor change.
        rows[rowId] = row

        appendAudit(verb: "reanchor", rowId: rowId,
                     before: (row.adjectiveBitmap, row.operationalBitmap, row.provenanceBitmap),
                     after: (row.adjectiveBitmap, row.operationalBitmap, row.provenanceBitmap),
                     beforeAnchor: oldAnchor, afterAnchor: newLatticeAnchor, actor: actor)

        // Telemetry — off-path cost: single atomic load + branch.
        emitVerbReanchorCount(ts: ts)

        return .success(())
    }

    // ============================================================
    // § 10.3 — mutate
    // ============================================================

    public enum MutationKind: String {
        case confirm, reject, contest, supersede
        case automatedConfirm = "automated_confirm"
        case decay, expire
        case lineageAdvance = "lineage_advance"
        case actuatorConfirm = "actuator_confirm"
    }

    @discardableResult
    public mutating func mutate(
        rowId: UUID,
        mutationKind: MutationKind,
        newAdjectiveBitmap: Int64,
        newOperationalBitmap: Int64? = nil,
        newProvenanceBitmap: Int64? = nil,
        actor: String = "mutate",
        ts: Double = 0.0
    ) -> Result<(), SubstrateError> {
        guard var row = rows[rowId] else { return .failure(.rowNotFound(rowId)) }
        if row.state == .tombstoned { return .failure(.alreadyTombstoned(rowId)) }

        let newState = extractState(adjective: newAdjectiveBitmap)
        let verbToken = mutationKind.rawValue

        // § 9.9 automaton precondition check.
        if !RowStateAutomaton.canTransition(from: row.state, to: newState,
                                             viaVerb: verbToken) {
            return .failure(.invalidStateTransition(
                from: row.state, to: newState, verb: verbToken))
        }
        // § 9.5 / I-22 forbidden-combination check.
        let nextOperational = newOperationalBitmap ?? row.operationalBitmap
        if let err = isLegalRowState(state: newState,
                                      adjective: newAdjectiveBitmap,
                                      operational: nextOperational) {
            return .failure(err)
        }

        let beforeBitmaps = (row.adjectiveBitmap, row.operationalBitmap, row.provenanceBitmap)
        let wasActive = row.state != .tombstoned
        row.state = newState
        row.adjectiveBitmap = newAdjectiveBitmap
        if let op = newOperationalBitmap   { row.operationalBitmap = op }
        if let pr = newProvenanceBitmap    { row.provenanceBitmap  = pr }
        let afterBitmaps = (row.adjectiveBitmap, row.operationalBitmap, row.provenanceBitmap)
        rows[rowId] = row

        let nowActive = row.state != .tombstoned
        if wasActive && !nowActive { rowCountActive &-= 1 }
        else if !wasActive && nowActive { rowCountActive &+= 1 }

        // Matrix update: delta against old vs new bitmaps.
        do {
            var f = self.matrixF
            let beforeRowBitmaps = RowBitmaps(
                adjective: beforeBitmaps.0,
                operational: beforeBitmaps.1,
                provenance: beforeBitmaps.2)
            f.applyRow(delta: -1, bitVector: beforeRowBitmaps.bitVector())
            let afterRowBitmaps = RowBitmaps(
                adjective: afterBitmaps.0,
                operational: afterBitmaps.1,
                provenance: afterBitmaps.2)
            f.applyRow(delta: 1, bitVector: afterRowBitmaps.bitVector())
            self.matrixF = f
        }
        matrixO.applyRow(delta: -1,
                          fieldValues: extractFieldValues(adj: beforeBitmaps.0,
                                                            op: beforeBitmaps.1,
                                                            prov: beforeBitmaps.2))
        matrixO.applyRow(delta: 1,
                          fieldValues: extractFieldValues(adj: afterBitmaps.0,
                                                            op: afterBitmaps.1,
                                                            prov: afterBitmaps.2))

        appendAudit(verb: "mutate." + verbToken, rowId: rowId,
                     before: beforeBitmaps, after: afterBitmaps,
                     beforeAnchor: row.latticeAnchor, afterAnchor: row.latticeAnchor,
                     actor: actor)

        // Telemetry — off-path cost: single atomic load + branch.
        emitVerbMutateCount(mutationKindToken: verbToken, ts: ts)

        return .success(())
    }

    // ============================================================
    // § 10.4 — withdraw
    // ============================================================

    @discardableResult
    public mutating func withdraw(
        rowId: UUID,
        actor: String = "withdraw",
        ts: Double = 0.0
    ) -> Result<(), SubstrateError> {
        guard var row = rows[rowId] else { return .failure(.rowNotFound(rowId)) }
        if !RowStateAutomaton.canTransition(from: row.state, to: .withdrawn,
                                             viaVerb: "withdraw") {
            return .failure(.invalidStateTransition(
                from: row.state, to: .withdrawn, verb: "withdraw"))
        }
        let before = (row.adjectiveBitmap, row.operationalBitmap, row.provenanceBitmap)
        // Replace state field (bits 0-5 of adjective bitmap, raw 18) with 18.
        row.state = .withdrawn
        row.adjectiveBitmap = setStateField(row.adjectiveBitmap, to: 18)
        rows[rowId] = row
        let after = (row.adjectiveBitmap, row.operationalBitmap, row.provenanceBitmap)

        // Matrix update: delta against old vs new bitmaps. Withdraw changes
        // the state field in the adjective bitmap, so both MatrixF (bit-slice)
        // and MatrixO (field-value ordinal) must reflect the new state or
        // downstream bitmap queries will produce stale bucket counts (WS2-F5).
        do {
            var f = self.matrixF
            let beforeRowBitmaps = RowBitmaps(
                adjective: before.0,
                operational: before.1,
                provenance: before.2)
            f.applyRow(delta: -1, bitVector: beforeRowBitmaps.bitVector())
            let afterRowBitmaps = RowBitmaps(
                adjective: after.0,
                operational: after.1,
                provenance: after.2)
            f.applyRow(delta: 1, bitVector: afterRowBitmaps.bitVector())
            self.matrixF = f
        }
        matrixO.applyRow(delta: -1,
                          fieldValues: extractFieldValues(adj: before.0,
                                                            op: before.1,
                                                            prov: before.2))
        matrixO.applyRow(delta: 1,
                          fieldValues: extractFieldValues(adj: after.0,
                                                            op: after.1,
                                                            prov: after.2))

        appendAudit(verb: "withdraw", rowId: rowId,
                     before: before,
                     after: after,
                     beforeAnchor: row.latticeAnchor, afterAnchor: row.latticeAnchor,
                     actor: actor)

        // Telemetry — off-path cost: single atomic load + branch.
        emitVerbWithdrawCount(ts: ts)

        return .success(())
    }

    // ============================================================
    // § 10.5 — expunge
    // ============================================================

    @discardableResult
    public mutating func expunge(
        rowId: UUID,
        reason: String,
        actor: String = "expunge",
        ts: Double = 0.0
    ) -> Result<(), SubstrateError> {
        guard var row = rows[rowId] else { return .failure(.rowNotFound(rowId)) }
        if row.state == .tombstoned { return .failure(.alreadyTombstoned(rowId)) }
        // S-3 (cookbook § 9.5): accepted rows are audit-grade and must
        // survive intact. The expunge path is closed for them.
        if row.state == .accepted {
            return .failure(.invalidStateTransition(
                from: .accepted, to: .tombstoned, verb: "expunge"))
        }
        let before = (row.adjectiveBitmap, row.operationalBitmap, row.provenanceBitmap)
        let wasActive = row.state != .tombstoned
        row.state = .tombstoned
        row.adjectiveBitmap = setStateField(row.adjectiveBitmap, to: 33)
        row.content = nil  // verbatim content zeroized at expunge
        rows[rowId] = row
        if wasActive { rowCountActive &-= 1 }

        // Matrix decrement: row no longer contributes.
        do {
            var f = self.matrixF
            let beforeRowBitmaps = RowBitmaps(
                adjective: before.0,
                operational: before.1,
                provenance: before.2)
            f.applyRow(delta: -1, bitVector: beforeRowBitmaps.bitVector())
            self.matrixF = f
        }
        matrixO.applyRow(delta: -1,
                          fieldValues: extractFieldValues(adj: before.0,
                                                            op: before.1,
                                                            prov: before.2))

        appendAudit(verb: "expunge", rowId: rowId,
                     before: before,
                     after: (row.adjectiveBitmap, row.operationalBitmap, row.provenanceBitmap),
                     beforeAnchor: row.latticeAnchor, afterAnchor: row.latticeAnchor,
                     actor: actor + ":" + reason)

        // Telemetry — off-path cost: single atomic load + branch.
        emitVerbExpungeCount(ts: ts)

        return .success(())
    }

    // ============================================================
    // § 10.6 — recall (read-only)
    // ============================================================

    /// Filter rows by an arbitrary predicate. Production code uses
    /// the bit-slice tensor (§ 4.1); this reference uses the
    /// in-memory dict. Recall never mutates; no audit row.
    ///
    /// - Parameter ts: Caller-supplied epoch seconds for telemetry.
    ///   Defaults to 0.0; pass `Date().timeIntervalSince1970` at the
    ///   verb boundary. Never read a clock inside this method.
    public func recall(matching predicate: (Row) -> Bool,
                        asOf hlc: HLC? = nil,
                        ts: Double = 0.0) -> [Row] {
        let candidates: [Row]
        if let cutoff = hlc {
            // asOf reconstruction is the audit-log projection
            // (§ 5.3); the reference here simply filters by
            // events whose HLC ≤ cutoff. Production code projects
            // forward from the truncated audit log.
            let eventsByRow = Dictionary(grouping: auditEvents.filter { $0.hlc <= cutoff },
                                          by: { $0.rowId })
            candidates = rows.values.compactMap { row -> Row? in
                guard !(eventsByRow[row.id]?.isEmpty ?? true) else { return nil }
                return row
            }
        } else {
            candidates = Array(rows.values)
        }
        let result = candidates.filter(predicate)

        // Telemetry — off-path cost: single atomic load + branch.
        // Emitted after filtering so result_count is accurate.
        emitVerbRecallCount(resultCount: result.count, ts: ts)

        return result
    }

    // ============================================================
    // § 10.7 — propose
    // ============================================================

    @discardableResult
    public mutating func propose(
        adjectiveBitmap: Int64,
        operationalBitmap: Int64,
        provenanceBitmap: Int64,
        latticeAnchor: LatticeAnchor,
        fingerprint: Fingerprint256,
        actor: String = "mcp_agent",
        ts: Double = 0.0
    ) -> Result<UUID, SubstrateError> {
        // Thread ts through to capture so the telemetry timestamp is the
        // caller-supplied wall time rather than always 0.0 (Rust already
        // carries ts through all nine verb paths; this closes the parity gap).
        return capture(nounType: .proposal,
                        adjectiveBitmap: adjectiveBitmap,
                        operationalBitmap: operationalBitmap,
                        provenanceBitmap: provenanceBitmap,
                        latticeAnchor: latticeAnchor,
                        fingerprint: fingerprint,
                        actor: actor,
                        ts: ts)
    }

    // ============================================================
    // § 10.8 — associate
    // ============================================================

    @discardableResult
    public mutating func associate(
        rowA: UUID, rowB: UUID,
        signalSourcesBitset: UInt16,
        weight: Float,
        adjectiveBitmap: Int64,
        operationalBitmap: Int64,
        provenanceBitmap: Int64,
        latticeAnchor: LatticeAnchor,
        fingerprint: Fingerprint256,
        actor: String = "dreaming_daemon",
        ts: Double = 0.0
    ) -> Result<UUID, SubstrateError> {
        // Reference: an Association is just a noun-typed row.
        // The signal_sources_seen bitset and the endpoint refs
        // live in the operational + provenance bitmaps and the
        // lattice anchor's representation, which in production
        // would also include foreign-key columns to rowA/rowB.
        // The reference encodes this as raw arguments; production
        // adds the FK book-keeping.
        //
        // ADMIN — drop site for `weight`. It arrives computed (the vector
        // similarity signal derives it free from the proximity-gate
        // Hamming distance) but is VESTIGIAL past this gate: an
        // association row carries no weight column, so the value is not
        // persisted. The parameter stays on the signature on purpose — a
        // pre-2.0 gauntlet experiment will test whether feeding weight
        // into recall improves results. Until that runs it is accepted
        // and discarded, never silently fabricated.
        _ = rowA; _ = rowB; _ = signalSourcesBitset; _ = weight
        // Thread ts through to capture so the telemetry timestamp is the
        // caller-supplied wall time (Rust already carries ts through all nine
        // verb paths; this closes the parity gap).
        return capture(nounType: .association,
                        adjectiveBitmap: adjectiveBitmap,
                        operationalBitmap: operationalBitmap,
                        provenanceBitmap: provenanceBitmap,
                        latticeAnchor: latticeAnchor,
                        fingerprint: fingerprint,
                        actor: actor,
                        ts: ts)
    }

    // ============================================================
    // § 10.9 — learn
    // ============================================================

    @discardableResult
    public mutating func learn(
        adjectiveBitmap: Int64,
        operationalBitmap: Int64,
        provenanceBitmap: Int64,
        latticeAnchor: LatticeAnchor,
        fingerprint: Fingerprint256,
        actor: String = "learn",
        ts: Double = 0.0
    ) -> Result<UUID, SubstrateError> {
        // Thread ts through to capture so the telemetry timestamp is the
        // caller-supplied wall time (Rust already carries ts through all nine
        // verb paths; this closes the parity gap).
        return capture(nounType: .learnedReference,
                        adjectiveBitmap: adjectiveBitmap,
                        operationalBitmap: operationalBitmap,
                        provenanceBitmap: provenanceBitmap,
                        latticeAnchor: latticeAnchor,
                        fingerprint: fingerprint,
                        actor: actor,
                        ts: ts)
    }

    // MARK: - Internals

    private mutating func appendAudit(
        verb: String, rowId: UUID,
        before: (Int64, Int64, Int64)?,
        after: (Int64, Int64, Int64),
        beforeAnchor: LatticeAnchor?,
        afterAnchor: LatticeAnchor,
        actor: String
    ) {
        hlc = hlc.advanced()
        // Deterministic event identity: SHA-256 over the same wire
        // encoding as Rust's audit_gate::content_id and Swift's
        // AuditGate.contentID. Replaces the random UUID() default so
        // the same logical event computes the same ID across languages,
        // enabling G-Set deduplication and federation convergence.
        let eventID = AuditGate.contentID(
            estateUuid: estateUuid, rowId: rowId, hlc: hlc,
            verb: verb, after: after, afterAnchor: afterAnchor)
        let event = AuditEvent(
            eventID: eventID,
            estateUuid: estateUuid,
            rowId: rowId,
            hlc: hlc,
            verb: verb,
            beforeBitmaps: before,
            afterBitmaps: after,
            beforeLatticeAnchor: beforeAnchor,
            afterLatticeAnchor: afterAnchor,
            actor: actor
        )
        auditEvents.append(event)
    }

    /// Forbidden-combination check (§ 9.5 / I-22). Returns nil on
    /// success or the relevant error on failure.
    ///
    /// Delegates to `ForbiddenCombinations.check` — the single
    /// SubstrateLib rule set (I-22 + S-1 + S-2 + S-4) — so the verb
    /// oracle is faithful to the LocusKit mutation path, which
    /// reaches the same check via `RowStateAutomaton.validate`.
    /// `.check` reads only the adjective field; provenance is unused
    /// here, so 0 is faithful.
    private func isLegalRowState(state: RowState,
                                  adjective: Int64,
                                  operational: Int64) -> SubstrateError? {
        let fields = BitmapFields(
            adjective: UInt64(bitPattern: adjective),
            operational: UInt64(bitPattern: operational),
            provenance: 0)
        do {
            try ForbiddenCombinations.check(state: state, fields: fields)
            return nil
        } catch RowStateError.violatesInvariant(let message) {
            return .forbiddenStateCombination(message)
        } catch {
            // `.check` throws only `RowStateError.violatesInvariant`
            // today; surface anything new rather than swallow it.
            return .forbiddenStateCombination(String(describing: error))
        }
    }

    private func rowHasBit(adj: Int64, op: Int64, prov: Int64,
                            field: Int, bit: Int) -> Bool {
        // Phase 5 (decision 2026-05-28 §6.5): thin wrapper around
        // RowBitmaps.bit(field:bit:). The 36/6/12 literals live
        // exactly once now, in RowBitmaps.
        return RowBitmaps(adjective: adj, operational: op, provenance: prov)
            .bit(field: field, bit: bit)
    }

    private func extractFieldValues(adj: Int64, op: Int64, prov: Int64)
            -> [(field: UInt8, value: UInt8)] {
        // Phase 5 (decision 2026-05-28 §6.5): thin wrapper around
        // RowBitmaps.fieldValues().
        return RowBitmaps(adjective: adj, operational: op, provenance: prov)
            .fieldValues()
    }

    private func extractState(adjective: Int64) -> RowState {
        let raw = UInt8(adjective & 0x3F)
        return RowState(rawValue: raw) ?? .active
    }

    private func setStateField(_ bitmap: Int64, to raw: UInt8) -> Int64 {
        // Clear bottom 6 bits, then OR in raw.
        let cleared = bitmap & ~Int64(0x3F)
        return cleared | Int64(raw)
    }
}

// MARK: - Type dependencies
//
// MatrixF, MatrixO, MatrixT, HLC, and Fingerprint256 are imported from
// the sibling SubstrateTypes package. RowStateAutomaton is defined
// locally in this SubstrateLib source directory.

// MARK: - Verb properties (informally verified)
//
//   capture:        creates exactly one row, exactly one audit row,
//                   increments F by row's bit count, increments O
//                   by row's field-pair count.
//   mutate:         delta-symmetric on F (old subtracted, new added)
//                   and O. Idempotent if new == old.
//   withdraw:       state → withdrawn; no other field changes.
//   expunge:        state → tombstoned; content zeroized; matrices
//                   decremented as if row never existed.
//   recall:         pure function; no mutation; no audit row.
//   propose:        capture with noun_type=proposal → state=pending.
//   associate:      capture with noun_type=association.
//   learn:          capture with noun_type=learned_reference.
//   reanchor:       mutates lattice_anchor only; emits audit; F/O
//                   unchanged at this level (production recomputes
//                   Block 1 of fingerprint and adjusts F/O for
//                   lattice-derived fields).
