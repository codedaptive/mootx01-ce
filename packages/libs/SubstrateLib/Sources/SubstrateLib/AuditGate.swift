// AuditGate.swift
//
// The single write gate, plus the vocabulary validator that arms it.
// Every mutation to a row's bitmaps goes through `AuditGate.admit`. A
// consumer supplies the row identity and only the field values IT owns;
// the gate read-modify-writes those into the prior snapshot (preserving
// every bit not addressed), enforces the admitted vocabulary
// (basis ∪ the instance's frozen union — field existence AND legal
// value AND width), validates the result against the basis invariants
// (RowStateAutomaton: legal transition + I-22 forbidden combinations),
// assigns a deterministic content-ID, and emits one canonical snapshot
// AuditEvent.
//
// Corruption is unrepresentable through this interface. A write either
// lands in a declared field, with an in-range value that fits the
// field width, producing a legal transition and a legal combination,
// or it is refused. The vocabulary itself is validated once, at
// instantiation, by `VocabularyValidator.freeze` — overlapping slots,
// basis collisions, and malformed widths are rejected before any data
// exists, so a database can never run on a corrupt vocabulary. The two
// together — write gate and vocabulary freeze — are what make the
// guarantee total; either alone leaves a hole.
//
// Scope of the guarantee: structural integrity, not intent. The gate
// makes an illegal state impossible (out-of-range value, undeclared
// field, illegal transition, corrupt vocabulary). It does not prevent
// a wrong-but-legal value; that is a correct recording of a mistaken
// intent, and the audit log is what makes it recoverable.
//
// Purity: pure functions, no I/O. The open sequence reads the header,
// calls `VocabularyValidator.freeze`, arms the gate, raises write-ready,
// and drains the write queue behind that barrier. The gate and the
// validator perform no storage access; SubstrateLib stays zero-dep,
// pure, stateless.
//
// Mirror: rust/src/audit_gate.rs — (M8, I-7/I-11), shape
// settled on the Swift leg first, then mirrored with shared vectors.

import Foundation
import SubstrateTypes
import SubstrateKernel  // BitField, SHA256 (relocated 2026-05-29 four-package split)

// MARK: - Field slots

/// One declared field-slot in a bitmap column: where the field lives
/// (column, shift, width), its human label, and — the part that makes
/// corruption unrepresentable — its set of legal values. An empty
/// `legalValues` means "any value that fits the width" (used by basis
/// fields whose combinations the automaton governs rather than an
/// enumerated set).
public struct FieldSlot: Hashable, Sendable {
    public enum Column: UInt8, Sendable, Hashable {
        case adjective, operational, provenance
    }
    public let column: Column
    public let shift: Int
    public let width: Int
    public let label: String
    public let legalValues: Set<Int64>

    public init(column: Column, shift: Int, width: Int, label: String,
                legalValues: Set<Int64> = []) {
        self.column = column
        self.shift = shift
        self.width = width
        self.label = label
        self.legalValues = legalValues
    }

    /// The maximum value the width can hold (exclusive upper bound is
    /// `1 << width`). A field of width w holds [0, 2^w).
    public var capacity: Int64 { width >= 63 ? Int64.max : (Int64(1) << width) }

    /// The bits this slot occupies in its column, as a mask. Used by the
    /// vocabulary validator to detect overlap.
    public var bitMask: UInt64 {
        if width <= 0 { return 0 }
        if width >= 64 { return ~UInt64(0) }
        return ((UInt64(1) << width) - 1) << shift
    }

    /// Whether `value` is admissible for this slot: it must fit the
    /// width, and — if the slot enumerates legal values — be one of them.
    public func admits(value: Int64) -> Bool {
        if value < 0 || value >= capacity { return false }
        if legalValues.isEmpty { return true }
        return legalValues.contains(value)
    }
}

// MARK: - SubstrateLib adjective vocabulary enums
//
// SubstrateLib-local enum types for the four adjective-axis fields.
// AuditGate.basis derives its legalValues from these enums at compile
// time, so adding a case automatically extends the gate vocabulary
// without a manual integer-array update.
//
// Raw values are identical to the LocusKit counterparts in
// LocusKit/Adjectives.swift (State, AdjectiveSensitivity,
// AdjectiveExportability, Trust). The layer below LocusKit cannot
// import those types (dependency graph points the other way), so
// SubstrateLib maintains its own copies. GuardianPairParityTests
// (LocusKit/Tests) enforces cross-layer parity at CI time.

// @guardian-pair: state-basis AuditState.allCases <-> State.allCases (raw set equality)
enum AuditState: Int, CaseIterable {
    case active = 0, pending = 1, contested = 2, accepted = 3
    case superseded = 16, decayed = 17, withdrawn = 18, expired = 19
    case rejected = 32, tombstoned = 33
}

// @guardian-pair: sensitivity-basis AuditSensitivity.allCases <-> AdjectiveSensitivity.allCases (raw set equality)
enum AuditSensitivity: Int, CaseIterable {
    case normal = 0, elevated = 16, restricted = 32, secret = 48
}

// @guardian-pair: exportability-basis AuditExportability.allCases <-> AdjectiveExportability.allCases (raw set equality)
enum AuditExportability: Int, CaseIterable {
    case private_ = 0, public_ = 32
}

// @guardian-pair: trust-basis AuditTrust.allCases <-> Trust.allCases (raw set equality)
enum AuditTrust: Int, CaseIterable {
    case verbatim = 0, observed = 1, imported = 2, canonical = 3
    case derived = 4, proposed = 5, ambient = 6
}

// MARK: - Vocabulary

/// The admitted vocabulary for an instance: the substrate basis plus
/// the frozen per-instance union of wired consumers. Constructed only
/// through `VocabularyValidator.freeze`, which guarantees the union is
/// non-overlapping, basis-disjoint, and width-sane.
public struct Vocabulary: Sendable {

    /// Substrate-owned slots, universal across every instance and every
    /// federation peer — the slots the fold and the access path
    /// interpret, so they must be identical everywhere (the federation
    /// minimum). Adjective layout per cookbook §2.3 (F11): state 0-5,
    /// sensitivity 6-11, exportability 12-17, trust 18-23, flags 24-25.
    /// Basis fields derive their legal value sets from the SubstrateLib
    /// adjective enums (AuditState, AuditSensitivity, AuditExportability,
    /// AuditTrust) via `allCases.map { $0.rawValue }`. State additionally
    /// gets the verb-consistency check in `admit`.
    public static let basis: Set<FieldSlot> = [
        // Enumerated value sets per cookbook §2.3: a basis field admits
        // only its declared raws, so the gate refuses a non-scale-gapped
        // sensitivity/trust the way it refuses an undeclared field. State
        // additionally gets the verb-consistency check in `admit`.
        //
        // legalValues are derived from the SubstrateLib-local adjective
        // enums (AuditState, AuditSensitivity, AuditExportability,
        // AuditTrust). Adding a case to one of those enums automatically
        // extends the gate vocabulary without a manual integer update.
        // Cross-layer parity vs LocusKit's types is enforced by
        // GuardianPairParityTests in LocusKitTests.
        FieldSlot(column: .adjective, shift: 0,  width: 6, label: "state",
                  legalValues: Set(AuditState.allCases.map { Int64($0.rawValue) })),
        FieldSlot(column: .adjective, shift: 6,  width: 6, label: "sensitivity",
                  legalValues: Set(AuditSensitivity.allCases.map { Int64($0.rawValue) })),
        FieldSlot(column: .adjective, shift: 12, width: 6, label: "exportability",
                  legalValues: Set(AuditExportability.allCases.map { Int64($0.rawValue) })),
        FieldSlot(column: .adjective, shift: 18, width: 6, label: "trust",
                  legalValues: Set(AuditTrust.allCases.map { Int64($0.rawValue) })),
        // flags: a 3-bit bitset spanning adjective bits 24-26, any
        // value fits the width.
        //   bit 24 = state_extension     (cookbook §2.3; hint that the
        //            state field references a structured extension tier)
        //   bit 25 = lineage_clustering  (cookbook §2.3)
        //   bit 26 = dreaming_recalc_required (cookbook §2.3, F17):
        //            worklist marker set on tombstone-via-expunge,
        //            cleared by the dreaming pass after graph
        //            reconciliation.
        // Widened from width 2 to width 3 in F17 second pass to admit
        // bit 26 as a gated write target (the cookbook listed bit 26 in
        // F17 first pass; this aligns the basis to that reality). The
        // per-bit meaning lives at the kit-level accessor (LocusKit's
        // Drawer.dreamingRecalcRequired); the substrate carries the
        // bits transparently. Sealed (bit 27) is deliberately NOT in
        // this slot — its set-once integrity-triangle lifecycle is
        // owned by the Clock Triangle decision and lands with the
        // dreaming-pass wiring (see gated capture genesis
        // 2026-05-28, line 92).
        FieldSlot(column: .adjective, shift: 24, width: 3, label: "flags"),
    ]

    /// Consumer-contributed slots, frozen at instantiation.
    public let union: Set<FieldSlot>

    /// Fileprivate: only `VocabularyValidator.freeze` constructs a
    /// Vocabulary, so an unvalidated union cannot reach the gate.
    fileprivate init(validatedUnion: Set<FieldSlot>) { self.union = validatedUnion }

    /// Look up the declared slot at a given (column, shift, width), if
    /// any. A write must target a slot that exists exactly.
    public func slot(for target: FieldSlot) -> FieldSlot? {
        if let b = Vocabulary.basis.first(where: { $0.column == target.column && $0.shift == target.shift && $0.width == target.width }) {
            return b
        }
        return union.first(where: { $0.column == target.column && $0.shift == target.shift && $0.width == target.width })
    }
}

// MARK: - Vocabulary validation / freeze

public enum VocabularyError: Error, Sendable, Equatable {
    /// Two slots (in the same column) occupy overlapping bits.
    case overlap(String, String)
    /// A union slot collides with a basis slot's bits.
    case basisCollision(String)
    /// A slot's width is non-positive or exceeds its column (64 bits),
    /// or its shift+width runs past the column.
    case malformedWidth(String)
    /// A legal value does not fit the slot width.
    case valueExceedsWidth(String, Int64)
}

/// Validates a proposed consumer union and freezes it into a
/// `Vocabulary`, or rejects it. Run once, at instantiation, before any
/// data exists. A database that froze a corrupt vocabulary would be
/// lost, so this is where vocabulary corruption is caught.
public enum VocabularyValidator {

    public static func freeze(union proposed: Set<FieldSlot>) -> Result<Vocabulary, VocabularyError> {
        // 1. Each slot is width-sane and its enumerated values fit.
        for s in proposed {
            if s.width <= 0 || s.shift < 0 || s.shift + s.width > 64 {
                return .failure(.malformedWidth(s.label))
            }
            for v in s.legalValues where v < 0 || v >= s.capacity {
                return .failure(.valueExceedsWidth(s.label, v))
            }
        }
        // 2. No union slot collides with a basis slot (same column bits).
        for s in proposed {
            for b in Vocabulary.basis where b.column == s.column && (b.bitMask & s.bitMask) != 0 {
                return .failure(.basisCollision(s.label))
            }
        }
        // 3. No two union slots overlap within a column.
        let list = Array(proposed)
        for i in 0..<list.count {
            for j in (i + 1)..<list.count {
                let a = list[i], b = list[j]
                if a.column == b.column && (a.bitMask & b.bitMask) != 0 {
                    return .failure(.overlap(a.label, b.label))
                }
            }
        }
        return .success(Vocabulary(validatedUnion: proposed))
    }
}

// MARK: - Write request

/// A consumer's requested change to one field-slot. The consumer
/// supplies only the slots it owns; the gate preserves the rest.
public struct FieldWrite: Sendable {
    public let slot: FieldSlot
    public let value: Int64
    public init(slot: FieldSlot, value: Int64) {
        self.slot = slot
        self.value = value
    }
}

// MARK: - Result

public enum GateViolation: Error, Sendable {
    /// A written slot is not declared in basis ∪ union for this instance.
    case undeclaredField(label: String)
    /// The value is out of the field's legal set or does not fit width.
    case illegalValue(label: String, value: Int64)
    /// The resulting transition is illegal or the combination forbidden
    /// (I-22). Carries the underlying RowStateAutomaton error.
    case basisViolation(Error)
    /// The state encoded in the write does not match what `verb` produces
    /// (state is verb-driven), or a capture used a non-capture verb or an
    /// illegal initial state.
    case stateInconsistentWithVerb(verb: String)
}

extension GateViolation: CustomStringConvertible {
    /// English messages at the ARIA boundary. No Swift type-chain noise
    /// (GateViolation case names, RowStateAutomaton case names) must appear
    /// in user-visible error text. Parity with Rust GateViolation::Display.
    ///
    /// For basisViolation, the underlying error is surfaced via its own
    /// description so RowStateAutomaton.illegalTransition produces
    /// "illegal state transition: <state> --<verb>-->" — the canonical
    /// form the describe_gate_rejection parser expects.
    public var description: String {
        switch self {
        case .undeclaredField(let label):
            return "undeclared field '\(label)' in write request"
        case .illegalValue(let label, let value):
            return "illegal value \(value) for field '\(label)'"
        case .basisViolation(let error):
            // RowStateAutomaton errors already carry English text via their
            // description (or localizedDescription). Prefix with "illegal state
            // transition: " to produce the canonical sentinel the Aria parser
            // uses. This mirrors Rust's GateViolation::BasisViolation arm.
            return "illegal state transition: \(error)"
        case .stateInconsistentWithVerb(let verb):
            return "state encoded in write is inconsistent with verb '\(verb)'"
        }
    }
}

// MARK: - The gate

public enum AuditGate {

    /// Admit a write. Pure: validates vocabulary + value, merges into
    /// `prior`, validates the basis, assigns a deterministic content-ID,
    /// and returns the canonical snapshot event — or a violation,
    /// leaving the caller to abort its transaction.
    public static func admit(
        estateUuid: UUID,
        rowId: UUID,
        nounType: NounType,
        verb: RowVerb,
        prior: BitmapFields?,
        priorLatticeAnchor: LatticeAnchor?,
        writes: [FieldWrite],
        afterLatticeAnchor: LatticeAnchor,
        vocabulary: Vocabulary,
        hlc: HLC,
        actor: String
    ) -> Result<AuditEvent, GateViolation> {

        // 1. Vocabulary + value gate: each written slot must be declared
        //    exactly, and its value must be in-range and (if enumerated)
        //    legal. Width is enforced by `admits`; an over-wide value is
        //    rejected, never silently truncated.
        for w in writes {
            guard let declared = vocabulary.slot(for: w.slot) else {
                return .failure(.undeclaredField(label: w.slot.label))
            }
            guard declared.admits(value: w.value) else {
                return .failure(.illegalValue(label: declared.label, value: w.value))
            }
        }

        // 2. Read-modify-write: start from prior (or zero), write only the
        //    addressed slots, preserve everything else.
        let base = prior ?? BitmapFields(adjective: 0, operational: 0, provenance: 0)
        var adjective = Int64(bitPattern: base.adjective)
        var operational = Int64(bitPattern: base.operational)
        var provenance = Int64(bitPattern: base.provenance)
        for w in writes {
            switch w.slot.column {
            case .adjective:
                adjective = BitField.writeField(w.value, into: adjective, shift: w.slot.shift, width: w.slot.width)
            case .operational:
                operational = BitField.writeField(w.value, into: operational, shift: w.slot.shift, width: w.slot.width)
            case .provenance:
                provenance = BitField.writeField(w.value, into: provenance, shift: w.slot.shift, width: w.slot.width)
            }
        }

        // 3. Basis gate. State is verb-driven: the state the write encodes
        //    must be exactly what `verb` produces, so a write cannot move a
        //    row to a state its verb did not authorize.
        let priorState = RowState(rawValue: UInt8(BitField.extractField(
            Int64(bitPattern: base.adjective), shift: 0, width: 6))) ?? .active
        let merged = BitmapFields(adjective: UInt64(bitPattern: adjective),
                                  operational: UInt64(bitPattern: operational),
                                  provenance: UInt64(bitPattern: provenance))
        let writtenState = RowState(rawValue: UInt8(BitField.extractField(adjective, shift: 0, width: 6)))
        if prior == nil {
            // Capture: no prior to transition from. Require the capture verb
            // and a legal initial state, then check forbidden combinations.
            guard verb == .capture, let ws = writtenState, ws == .active || ws == .pending else {
                return .failure(.stateInconsistentWithVerb(verb: verb.rawValue))
            }
            do { try ForbiddenCombinations.check(state: ws, fields: merged) }
            catch { return .failure(.basisViolation(error)) }
        } else {
            // Mutation: the verb's transition gives the only legal next state
            // (legality + forbidden combinations via validate); the written
            // state must equal it.
            let next: RowState
            do { next = try RowStateAutomaton.validate(from: priorState, on: verb, targetingFields: merged) }
            catch { return .failure(.basisViolation(error)) }
            guard writtenState == next else {
                return .failure(.stateInconsistentWithVerb(verb: verb.rawValue))
            }
        }

        // 4. Deterministic content-ID over the wire fields, including the
        //    verb name. Identical logical events compute the same ID
        //    across configurations, so the G-Set deduplicates and
        //    federation peers converge regardless of vocabulary
        //    (Appendix C: name-keyed identity). Stable ID replaces the
        //    random UUID so "receive the same event twice is a no-op"
        //    actually holds.
        let eventID = contentID(estateUuid: estateUuid, rowId: rowId, hlc: hlc,
                                verb: verb.rawValue,
                                after: (adjective, operational, provenance),
                                afterAnchor: afterLatticeAnchor)

        let event = AuditEvent(
            eventID: eventID,
            estateUuid: estateUuid,
            rowId: rowId,
            hlc: hlc,
            verb: verb.rawValue,
            beforeBitmaps: prior.map { (Int64(bitPattern: $0.adjective),
                                        Int64(bitPattern: $0.operational),
                                        Int64(bitPattern: $0.provenance)) },
            afterBitmaps: (adjective, operational, provenance),
            beforeLatticeAnchor: priorLatticeAnchor,
            afterLatticeAnchor: afterLatticeAnchor,
            actor: actor)
        return .success(event)
    }

    /// Deterministic event identity: SHA-256 over a stable wire encoding
    /// of the identifying fields, folded into a UUID. By name, not by
    /// ordinal, so identity is vocabulary-set-independent.
    static func contentID(
        estateUuid: UUID, rowId: UUID, hlc: HLC, verb: String,
        after: (Int64, Int64, Int64), afterAnchor: LatticeAnchor
    ) -> UUID {
        var bytes: [UInt8] = []
        func put(_ u: UUID) { withUnsafeBytes(of: u.uuid) { bytes.append(contentsOf: $0) } }
        func put64(_ v: UInt64) { for s in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((v >> s) & 0xFF)) } }
        put(estateUuid); put(rowId)
        bytes.append(contentsOf: hlc.wireBytes)
        bytes.append(contentsOf: Array(verb.utf8)); bytes.append(0)
        put64(UInt64(bitPattern: after.0)); put64(UInt64(bitPattern: after.1)); put64(UInt64(bitPattern: after.2))
        put64(afterAnchor.udcCode); put64(afterAnchor.qidPointer)
        let h = SHA256.hash(bytes)
        // Fold the 32-byte digest into a 16-byte UUID (first 16 bytes;
        // collision-resistant for identity purposes).
        let u = (h[0],h[1],h[2],h[3],h[4],h[5],h[6],h[7],h[8],h[9],h[10],h[11],h[12],h[13],h[14],h[15])
        return UUID(uuid: u)
    }
}
