// Verbs.swift
//
// The nine substrate verbs per cookbook § 10:
//   capture, reanchor, mutate, withdraw, expunge,
//   recall, propose, associate, learn.
//
// The verbs are the substrate's public mutation API. This reference:
//
//   - Validates row-state preconditions (DrawerStateValidator, isLegalRowState)
//   - Emits audit events under the current HLC
//   - Updates F and O matrices on capture/mutate/expunge
//   - Returns Result<RowId, SubstrateError>
//
// Note: MatrixT is not updated here; `reanchor` leaves fingerprint
// recompute to the caller; `associate` discards endpoint/signal/weight
// arguments before creating the association row.
//
// This file is the COMPOSITION REFERENCE. It assumes the prior
// reference files are wired in as a package:
//   - glref-swift-Fingerprint256, HyperplaneFamily, SimHash
//   - glref-swift-HLC, GSetAuditLog
//   - glref-swift-RowStateAutomaton
//   - glref-swift-MatrixF, MatrixC, MatrixO, MatrixT
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

// MARK: - Noun types and row layout

public enum NounType: UInt8, Sendable {
    case drawer = 0
    case tunnel = 1
    case kgFact = 2
    case diaryEntry = 3
    case proposal = 4
    case association = 5
    case learnedReference = 6
    case ambientSample = 7
}

/// Lattice anchor reference per § 2.7 / I-16. Sixteen bytes:
/// 8-byte UDC code + 8-byte Q-ID pointer (or null).
public struct LatticeAnchor: Hashable, Sendable {
    public let udcCode: UInt64
    public let qidPointer: UInt64       // 0 indicates null

    public init(udcCode: UInt64, qidPointer: UInt64 = 0) {
        self.udcCode = udcCode
        self.qidPointer = qidPointer
    }

    public var isNull: Bool {
        return udcCode == 0 && qidPointer == 0
    }

    /// Convenience factory used by Block 2a/2b code that
    /// references UDC codes as dotted strings (e.g. "613.71"
    /// for "medicine / body care"). Hashes the string with FNV-1a
    /// 64-bit so two callers using the same string produce the
    /// same anchor.
    public static func udc(_ udcString: String) -> LatticeAnchor {
        var h: UInt64 = 0xCBF29CE484222325
        for byte in udcString.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x100000001B3
        }
        return LatticeAnchor(udcCode: h, qidPointer: 0)
    }
}

/// Row identifier alias. Canonically a `UUID`; Block 2a/2b
/// reference files spell this `RowId` for symmetry with the
/// Rust port's `RowId(u128)` newtype. They are wire-compatible
/// (UUID is 128 bits).
public typealias RowId = UUID

/// A substrate row at its current state. Mirrors the row layout
/// in cookbook § 2.1.
public struct Row: Sendable {
    public let id: UUID
    public let nounType: NounType
    public var state: RowStateValue          // see § 9.1
    public var adjectiveBitmap: Int64
    public var operationalBitmap: Int64
    public var provenanceBitmap: Int64
    public var fingerprint: Fingerprint256
    public var latticeAnchor: LatticeAnchor
    public var lineageId: UUID?
    public var content: Data?

    public init(id: UUID, nounType: NounType, state: RowStateValue,
                adjectiveBitmap: Int64, operationalBitmap: Int64,
                provenanceBitmap: Int64, fingerprint: Fingerprint256,
                latticeAnchor: LatticeAnchor,
                lineageId: UUID? = nil, content: Data? = nil) {
        self.id = id
        self.nounType = nounType
        self.state = state
        self.adjectiveBitmap = adjectiveBitmap
        self.operationalBitmap = operationalBitmap
        self.provenanceBitmap = provenanceBitmap
        self.fingerprint = fingerprint
        self.latticeAnchor = latticeAnchor
        self.lineageId = lineageId
        self.content = content
    }
}

/// The ten substrate states from § 9.1. Mirrors RowStateAutomaton.
public enum RowStateValue: UInt8, Sendable {
    case active = 0
    case pending = 1
    case contested = 2
    case accepted = 3
    case superseded = 16
    case decayed = 17
    case withdrawn = 18
    case expired = 19
    case rejected = 32
    case tombstoned = 33
}

// MARK: - Errors

public enum SubstrateError: Error, Equatable {
    case invalidStateTransition(from: RowStateValue, to: RowStateValue, verb: String)
    case missingLatticeAnchor
    case invalidNounType
    case rowNotFound(UUID)
    case forbiddenStateCombination(String)
    case alreadyTombstoned(UUID)
    case proposalRequired
    case nonProposalCannotUseProposalVerb
}

// MARK: - Audit event

/// A single audit row. Cookbook § 5.1 (G-Set CRDT). Stored by
/// GSetAuditLog under HLC ordering.
public struct AuditEvent: Sendable {
    public let estateUuid: UUID
    public let rowId: UUID
    public let hlc: HLC
    public let verb: String
    public let beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?
    public let afterBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)
    public let beforeLatticeAnchor: LatticeAnchor?
    public let afterLatticeAnchor: LatticeAnchor
    public let actor: String   // capture | mcp_agent | dreaming_daemon | actuator | ...

    public init(estateUuid: UUID, rowId: UUID, hlc: HLC, verb: String,
                beforeBitmaps: (adjective: Int64, operational: Int64, provenance: Int64)?,
                afterBitmaps: (adjective: Int64, operational: Int64, provenance: Int64),
                beforeLatticeAnchor: LatticeAnchor?,
                afterLatticeAnchor: LatticeAnchor,
                actor: String) {
        self.estateUuid = estateUuid
        self.rowId = rowId
        self.hlc = hlc
        self.verb = verb
        self.beforeBitmaps = beforeBitmaps
        self.afterBitmaps = afterBitmaps
        self.beforeLatticeAnchor = beforeLatticeAnchor
        self.afterLatticeAnchor = afterLatticeAnchor
        self.actor = actor
    }
}

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
        actor: String = "capture"
    ) -> Result<UUID, SubstrateError> {
        if latticeAnchor.isNull { return .failure(.missingLatticeAnchor) }

        let initialState: RowStateValue = (nounType == .proposal) ? .pending : .active

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
            f.applyRow(delta: 1) { field, bit in
                self.rowHasBit(adj: adjectiveBitmap, op: operationalBitmap,
                               prov: provenanceBitmap, field: field, bit: bit)
            }
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

        return .success(rowId)
    }

    // ============================================================
    // § 10.2 — reanchor
    // ============================================================

    @discardableResult
    public mutating func reanchor(
        rowId: UUID,
        newLatticeAnchor: LatticeAnchor,
        actor: String = "reanchor"
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
        actor: String = "mutate"
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
            f.applyRow(delta: -1) { field, bit in
                self.rowHasBit(adj: beforeBitmaps.0, op: beforeBitmaps.1,
                               prov: beforeBitmaps.2, field: field, bit: bit)
            }
            f.applyRow(delta: 1) { field, bit in
                self.rowHasBit(adj: afterBitmaps.0, op: afterBitmaps.1,
                               prov: afterBitmaps.2, field: field, bit: bit)
            }
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
        return .success(())
    }

    // ============================================================
    // § 10.4 — withdraw
    // ============================================================

    @discardableResult
    public mutating func withdraw(
        rowId: UUID,
        actor: String = "withdraw"
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
        appendAudit(verb: "withdraw", rowId: rowId,
                     before: before,
                     after: (row.adjectiveBitmap, row.operationalBitmap, row.provenanceBitmap),
                     beforeAnchor: row.latticeAnchor, afterAnchor: row.latticeAnchor,
                     actor: actor)
        return .success(())
    }

    // ============================================================
    // § 10.5 — expunge
    // ============================================================

    @discardableResult
    public mutating func expunge(
        rowId: UUID,
        reason: String,
        actor: String = "expunge"
    ) -> Result<(), SubstrateError> {
        guard var row = rows[rowId] else { return .failure(.rowNotFound(rowId)) }
        if row.state == .tombstoned { return .failure(.alreadyTombstoned(rowId)) }
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
            f.applyRow(delta: -1) { field, bit in
                self.rowHasBit(adj: before.0, op: before.1,
                               prov: before.2, field: field, bit: bit)
            }
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
        return .success(())
    }

    // ============================================================
    // § 10.6 — recall (read-only)
    // ============================================================

    /// Filter rows by an arbitrary predicate. Production code uses
    /// the bit-slice tensor (§ 4.1); this reference uses the
    /// in-memory dict. Recall never mutates; no audit row.
    public func recall(matching predicate: (Row) -> Bool,
                        asOf hlc: HLC? = nil) -> [Row] {
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
        return candidates.filter(predicate)
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
        actor: String = "mcp_agent"
    ) -> Result<UUID, SubstrateError> {
        return capture(nounType: .proposal,
                        adjectiveBitmap: adjectiveBitmap,
                        operationalBitmap: operationalBitmap,
                        provenanceBitmap: provenanceBitmap,
                        latticeAnchor: latticeAnchor,
                        fingerprint: fingerprint,
                        actor: actor)
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
        actor: String = "dreaming_daemon"
    ) -> Result<UUID, SubstrateError> {
        // Reference: an Association is just a noun-typed row.
        // The signal_sources_seen bitset and the endpoint refs
        // live in the operational + provenance bitmaps and the
        // lattice anchor's representation, which in production
        // would also include foreign-key columns to rowA/rowB.
        // The reference encodes this as raw arguments; production
        // adds the FK book-keeping.
        _ = rowA; _ = rowB; _ = signalSourcesBitset; _ = weight
        return capture(nounType: .association,
                        adjectiveBitmap: adjectiveBitmap,
                        operationalBitmap: operationalBitmap,
                        provenanceBitmap: provenanceBitmap,
                        latticeAnchor: latticeAnchor,
                        fingerprint: fingerprint,
                        actor: actor)
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
        actor: String = "learn"
    ) -> Result<UUID, SubstrateError> {
        return capture(nounType: .learnedReference,
                        adjectiveBitmap: adjectiveBitmap,
                        operationalBitmap: operationalBitmap,
                        provenanceBitmap: provenanceBitmap,
                        latticeAnchor: latticeAnchor,
                        fingerprint: fingerprint,
                        actor: actor)
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
        let event = AuditEvent(
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

    /// Simplified forbidden-combination check (§ 9.5 / I-22 subset).
    /// Checks two conditions: secret-cannot-be-public and
    /// accepted-cannot-be-verbatim. Tombstone-completed enforcement
    /// and other I-22 checks are deferred to the production layer.
    /// Returns nil on success or the relevant error on failure.
    private func isLegalRowState(state: RowStateValue,
                                  adjective: Int64,
                                  operational: Int64) -> SubstrateError? {
        let sensitivity = Int((adjective >> 6) & 0x3F)
        let exportability = Int((adjective >> 12) & 0x3F)
        let trust = Int((adjective >> 18) & 0x3F)

        // (1) tombstoned must have the expunge-completed bit set;
        // we don't model that bit explicitly in the reference, so
        // skip in this layer (production enforces).

        // (2) secret cannot be public.
        if sensitivity == 48 && exportability == 32 {
            return .forbiddenStateCombination("secret cannot be public")
        }
        // (3) accepted cannot be verbatim.
        if state == .accepted && trust == 0 {
            return .forbiddenStateCombination("accepted cannot be verbatim")
        }
        return nil
    }

    private func rowHasBit(adj: Int64, op: Int64, prov: Int64,
                            field: Int, bit: Int) -> Bool {
        // Reference v0.36: 36 fields, 6 bits each, packed across
        // adjective (fields 0-11), operational (12-23), provenance
        // (24-35). The substrate is bit-sliced over those three
        // 64-bit columns. Bit position WITHIN a field is `bit`.
        let bitmap: Int64
        let localField: Int
        if field < 12 {
            bitmap = adj; localField = field
        } else if field < 24 {
            bitmap = op; localField = field - 12
        } else {
            bitmap = prov; localField = field - 24
        }
        let bitOffset = localField * 6 + bit
        return (bitmap >> bitOffset) & 1 == 1
    }

    private func extractFieldValues(adj: Int64, op: Int64, prov: Int64)
            -> [(field: UInt8, value: UInt8)] {
        // For each of the 36 fields, extract its 6-bit value.
        var out = [(UInt8, UInt8)]()
        out.reserveCapacity(36)
        for f in 0..<36 {
            let bitmap: Int64
            let localField: Int
            if f < 12 { bitmap = adj; localField = f }
            else if f < 24 { bitmap = op; localField = f - 12 }
            else { bitmap = prov; localField = f - 24 }
            let shift = localField * 6
            let v = Int((bitmap >> shift) & 0x3F)
            out.append((UInt8(f), UInt8(v)))
        }
        return out
    }

    private func extractState(adjective: Int64) -> RowStateValue {
        let raw = UInt8(adjective & 0x3F)
        return RowStateValue(rawValue: raw) ?? .active
    }

    private func setStateField(_ bitmap: Int64, to raw: UInt8) -> Int64 {
        // Clear bottom 6 bits, then OR in raw.
        let cleared = bitmap & ~Int64(0x3F)
        return cleared | Int64(raw)
    }
}

// MARK: - Stub protocols / dependencies
//
// The reference depends on RowStateAutomaton, MatrixF, MatrixO,
// MatrixT, HLC, Fingerprint256 from the sibling reference files.
// Those are now imported directly when this file compiles inside
// the GeniusLocusReference Swift package; previously this file
// re-declared placeholder versions for standalone-readability,
// which conflicted at link time.

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
