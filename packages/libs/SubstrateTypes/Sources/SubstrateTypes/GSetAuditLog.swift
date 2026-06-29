// GSetAuditLog.swift
//
// Grow-only set CRDT audit log per cookbook § 5.1.
//
// The audit log is the substrate's source of truth. Visible
// drawer state is a projection over the log; the log itself is
// append-only and CRDT-merge-safe.
//
// G-Set (grow-only set) semantics: entries can be added but
// never removed. Two replicas merge their G-Sets via set union
// and converge to the same state regardless of message order
// (cookbook § 5.4 convergence proof).
//
// Each entry carries:
//   - HLC timestamp (cookbook § 5.2) for total ordering
//   - Verb (cookbook § 10) saying what mutation occurred
//   - Row ID + before/after field deltas
//   - Provenance (origin of the mutation)
//
// CRDT join operator: set union over entries keyed by content-hash
// `id` (SHA-256 over wire fields). Idempotent because identical
// entries deduplicate; commutative and associative because set
// union is. Projection over the joined set is deterministic
// because HLC gives a total order to apply entries.

import Foundation

/// One immutable entry in the audit log.
///
/// `id` is a deterministic content hash: SHA-256 over the wire
/// encoding of (hlc, verb, rowID, fieldPath, beforeValue,
/// afterValue, originRowID). Two replicas producing the same
/// logical mutation produce identical IDs and the G-Set
/// deduplicates them.
public struct AuditEntry: Hashable, Sendable, Codable {
    public let id: [UInt8]                       // 32-byte content hash
    public let hlc: HLC
    public let verb: AuditVerb
    public let rowID: UUID
    public let fieldPath: String                 // e.g. "adjective.state"
    public let beforeValue: AuditValue?          // nil at capture boundaries
    public let afterValue: AuditValue?           // nil at retract boundaries
    public let originRowID: UUID?                // for derived mutations

    public init(id: [UInt8], hlc: HLC, verb: AuditVerb,
                rowID: UUID, fieldPath: String,
                beforeValue: AuditValue?, afterValue: AuditValue?,
                originRowID: UUID? = nil) {
        precondition(id.count == 32, "audit id must be 32-byte SHA-256")
        self.id = id
        self.hlc = hlc
        self.verb = verb
        self.rowID = rowID
        self.fieldPath = fieldPath
        self.beforeValue = beforeValue
        self.afterValue = afterValue
        self.originRowID = originRowID
    }
}

/// The nine cookbook verbs (§ 10) plus migration / system verbs.
public enum AuditVerb: String, Sendable, Codable {
    case capture
    case mutate
    case retract
    case sync
    case pair
    case unpair
    case derive
    case decay
    case promote
    case migrate            // schema migration (cookbook § 16)
    case dreamCompact       // dreaming-daemon § 15 compaction
}

/// Typed audit value. Fields can be bitmaps (UInt64), strings,
/// fingerprints, or integers. F16.B (2026-05-27): the previous
/// `null` case has been removed in favor of `Optional<AuditValue>`
/// at the AuditEntry level — nil represents the capture / retract
/// boundary semantics that .null formerly carried.
///
/// Wire format: externally-tagged single-key object with camelCase
/// variant names. Example outputs:
///
///   {"bitmap": 42}
///   {"string": "hello"}
///   {"fingerprint": {"block0": 1, ...}}
///   {"integer": -1}
///
/// The custom Codable below replaces Swift's auto-synthesized
/// `{"bitmap": {"_0": 42}}` format (with positional `_0` keys)
/// with the externally-tagged shape Rust serde produces natively
/// via `#[serde(rename_all = "camelCase")]`. Both ports converge
/// on the same wire format.
public enum AuditValue: Hashable, Sendable, Codable {
    case bitmap(UInt64)
    case string(String)
    case fingerprint(Fingerprint256)
    case integer(Int64)

    private enum CodingKeys: String, CodingKey {
        case bitmap, string, fingerprint, integer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try container.decodeIfPresent(UInt64.self, forKey: .bitmap) {
            self = .bitmap(v)
        } else if let v = try container.decodeIfPresent(String.self, forKey: .string) {
            self = .string(v)
        } else if let v = try container.decodeIfPresent(Fingerprint256.self, forKey: .fingerprint) {
            self = .fingerprint(v)
        } else if let v = try container.decodeIfPresent(Int64.self, forKey: .integer) {
            self = .integer(v)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .bitmap, in: container,
                debugDescription: "AuditValue must have exactly one of: bitmap, string, fingerprint, integer")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .bitmap(let v):       try container.encode(v, forKey: .bitmap)
        case .string(let v):       try container.encode(v, forKey: .string)
        case .fingerprint(let v):  try container.encode(v, forKey: .fingerprint)
        case .integer(let v):      try container.encode(v, forKey: .integer)
        }
    }
}

/// G-Set audit log. Pure CRDT semantics: only `add` and `merge`
/// mutate; everything else reads.
public struct GSetAuditLog: Sendable, Codable {

    /// Backing store keyed by content hash for O(1) dedupe.
    private(set) public var entries: [[UInt8]: AuditEntry]

    public init(entries: [AuditEntry] = []) {
        var store: [[UInt8]: AuditEntry] = [:]
        for e in entries {
            store[e.id] = e
        }
        self.entries = store
    }

    // MARK: - Codable
    //
    // F16.B (2026-05-27): the wire format is `{"entries": [...]}`
    // — an array of AuditEntry sorted by `id` byte-lex for
    // determinism. The internal HashMap keying is an O(1)-dedup
    // optimization and is not part of the wire format. Swift's
    // default Codable for `[[UInt8]: AuditEntry]` produces an
    // array-of-alternating-key-value-pairs encoding which is both
    // ugly and not the conceptually-correct G-Set representation
    // (a Set, encoded over the wire as a sorted array).

    private enum CodingKeys: String, CodingKey { case entries }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entryArray = try container.decode([AuditEntry].self, forKey: .entries)
        var store: [[UInt8]: AuditEntry] = [:]
        for e in entryArray {
            store[e.id] = e
        }
        self.entries = store
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sorted = entries.values.sorted {
            $0.id.lexicographicallyPrecedes($1.id)
        }
        try container.encode(sorted, forKey: .entries)
    }

    /// Add a single entry. Idempotent: re-adding an entry with
    /// the same content hash is a no-op.
    public mutating func add(_ entry: AuditEntry) {
        entries[entry.id] = entry
    }

    /// CRDT join. Merging two G-Sets is set union of entries.
    /// Commutative, associative, idempotent — the three CRDT
    /// properties that guarantee convergence.
    public mutating func merge(_ other: GSetAuditLog) {
        for (id, entry) in other.entries {
            entries[id] = entry
        }
    }

    public var count: Int { return entries.count }

    /// All entries in HLC order. Projection (cookbook § 5.3)
    /// applies these to a fresh state to compute the visible
    /// estate.
    public var orderedEntries: [AuditEntry] {
        return entries.values.sorted { $0.hlc < $1.hlc }
    }

    /// Entries scoped to a single row, in HLC order. Drives
    /// the row-state automaton (cookbook § 9).
    public func entries(forRow rowID: UUID) -> [AuditEntry] {
        return entries.values
            .filter { $0.rowID == rowID }
            .sorted { $0.hlc < $1.hlc }
    }

    /// Entries since a given HLC, exclusive. Used by the sync
    /// protocol to ship the delta to a peer.
    public func entries(since cutoff: HLC) -> [AuditEntry] {
        return entries.values
            .filter { $0.hlc > cutoff }
            .sorted { $0.hlc < $1.hlc }
    }
}

// MARK: - Convergence proof sketch (cookbook § 5.4)
//
// Lemma: For any two replicas R1 and R2 of an estate with audit
// logs G1 and G2, after exchanging messages until quiescent, both
// hold identical state.
//
// Proof:
//   1. G-Set merge is set union of entries by content hash.
//   2. Set union is commutative, associative, and idempotent.
//   3. After quiescence, G1 = G2 = G1 ∪ G2 (every entry from
//      either replica is in both, dedupes by id).
//   4. Projection over G is deterministic: orderedEntries yields
//      a total HLC order, applied left-to-right to a fresh state.
//   5. Two replicas projecting the same G in the same order
//      produce the same state.   ∎
//
// The proof relies on three properties of HLC:
//   - causality:  if A causally precedes B, HLC(A) < HLC(B)
//   - total order: any two HLCs compare unambiguously
//   - stable seed: estate manifest fixes node IDs at creation,
//                   making the tiebreaker stable across replicas
