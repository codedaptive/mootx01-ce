// UnifiedAuditLog.swift
//
// Per-estate unified audit log for GeniusLocusKit (mission GLK-03).
//
// The substrate composes two storage tiers under one estate —
// LocusKit (drawers, knowledge graph) and CorpusKit (RAG bundles).
// Each tier records its own append-only audit events. GLK-03
// unifies those two streams into one G-Set CRDT per estate so
// projection, asOf reconstruction, and recovery span both tiers
// rather than one kit at a time.
//
// Conceptual model (cookbook §5.1):
//
//   UnifiedAuditEntry  — immutable, content-addressed by SHA-256 over
//                        its wire encoding. Two replicas producing the
//                        same logical mutation produce identical IDs;
//                        the G-Set deduplicates them.
//   UnifiedAuditLog    — G-Set (grow-only set) keyed by entry ID.
//                        `add` is idempotent; `merge` is set union and
//                        therefore commutative, associative, and
//                        idempotent.
//   HLC         — local mirror of `SubstrateLib.HLC`. Held inside
//                        GeniusLocusKit because GeniusLocusKit's
//                        Package.swift does not pull SubstrateLib as a
//                        direct dependency; the byte shape matches the
//                        SubstrateLib reference so the conformance
//                        relationship is preserved when wired through.
//                        See blast-radius report for the dependency
//                        rationale.
//
// Cross-tier ordering (mission §"Known Ambiguities"):
//
//   HLC supplies a total order across both tiers per cookbook §5.2.
//   The fold sorts the union of entries lexicographically by
//   (physicalTime, logicalCount, nodeID) and applies them in that
//   order; the projection is therefore order-independent given HLC.
//
// Storage:
//
//   The composed kits keep their own per-tier audit storage. This
//   log is an in-memory CRDT structure inside GeniusLocusKit. Callers
//   feed it events; the projection and recovery paths consume the
//   log to produce per-estate state and to rebuild from the audit
//   history.

import Foundation
import SubstrateKernel
import OSLog
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
import SubstrateTypes

// MARK: - Tier provenance

/// Storage tier an audit entry originated from. Persisted as a stable
/// raw string so wire-formats and on-disk encodings round-trip cleanly
/// across kit versions.
public enum AuditTier: String, Sendable, Codable, Hashable, CaseIterable {
    case locus
    case rag
}

// MARK: - Local HLC

// MARK: - Value typing

/// Typed payload for an audit entry's before / after slots.
///
/// Both tiers express their state in one of these typed shapes — a
/// 64-bit bitmap, a string token, an integer, or `null` (capture /
/// retract boundary). Sites that need richer typing pack them through
/// `.bitmap` or `.bytes` and decode at the consumer.
public enum UnifiedAuditValue: Hashable, Sendable, Codable {
    case null
    case bitmap(UInt64)
    case integer(Int64)
    case string(String)
    case bytes([UInt8])

    fileprivate var wireBytes: [UInt8] {
        switch self {
        case .null:
            return [0x00]
        case .bitmap(let v):
            var out: [UInt8] = [0x01]
            for shift in stride(from: 0, through: 56, by: 8) {
                out.append(UInt8((v >> shift) & 0xFF))
            }
            return out
        case .integer(let v):
            var out: [UInt8] = [0x02]
            let u = UInt64(bitPattern: v)
            for shift in stride(from: 0, through: 56, by: 8) {
                out.append(UInt8((u >> shift) & 0xFF))
            }
            return out
        case .string(let s):
            var out: [UInt8] = [0x03]
            let utf8 = Array(s.utf8)
            let len = UInt32(utf8.count)
            for shift in stride(from: 0, through: 24, by: 8) {
                out.append(UInt8((len >> shift) & 0xFF))
            }
            out.append(contentsOf: utf8)
            return out
        case .bytes(let b):
            var out: [UInt8] = [0x04]
            let len = UInt32(b.count)
            for shift in stride(from: 0, through: 24, by: 8) {
                out.append(UInt8((len >> shift) & 0xFF))
            }
            out.append(contentsOf: b)
            return out
        }
    }
}

// MARK: - Verb

/// The nine cookbook verbs (§10) plus the two system verbs needed for
/// recovery and migration. Same set as `SubstrateLib.AuditVerb`; held
/// locally so GeniusLocusKit does not depend on SubstrateLib for this
/// vocabulary.
public enum UnifiedAuditVerb: String, Sendable, Codable, Hashable {
    case capture
    case recall
    case mutate
    case withdraw
    case expunge
    case reanchor
    case learn
    case propose
    case associate
    case migrate
    case dreamCompact

    // Grant-lifecycle verbs — issued and resolved by the federation
    // layer, not by the substrate's own mutation path. Custody mode 3
    // (decay-derived key) and mode 4 (physical decay) produce the two
    // decay verbs at end-of-window. The names are defined here so the
    // chain verifier and projection fold recognise these entry kinds
    // before the federation grant mechanics ship (a later mission); the
    // mechanics themselves are out of GLK-03 scope.
    // See federation disclosure controls Appendix B.
    case grantIssued
    case grantRevoked
    case keyDecayed         // custody mode 3: Lagrange threshold crossed
    case physicalKeyDecayed // custody mode 4: SRAM cells decayed past threshold

    // sensitivity unlock verbs (2026-07-04, amended 2026-07-04).
    // Deliberately NOT the federation grantIssued/grantRevoked above —
    // those are reserved for the federation sharing feature (Appendix B)
    // and are a different concern (custody/decay, not a human approving
    // their OWN estate's restricted/secret tiers). Every sensitivity
    // grant, denial, and manual revocation gets one of these; there is
    // NO expiry verb — expiry is passive (the issued record carries its
    // own expiry timestamp in `afterValue`, so expiry is derivable from
    // the log without an expiry-time writer; out-of-band sensitivity grants).
    case sensitivityGrantIssued
    case sensitivityGrantDenied
    case sensitivityGrantRevoked
    case sensitivityReadUnderGrant
}

// MARK: - Entry

/// One immutable entry in the unified audit log.
///
/// `id` is a deterministic SHA-256 content hash over the wire encoding
/// of every other field. Two replicas producing the same logical
/// mutation produce identical IDs and the G-Set deduplicates them on
/// merge. `originRowID` carries the source row for derived mutations
/// (e.g. associations referring back to a captured drawer); when
/// absent the entry's own `rowID` is the origin.
public struct UnifiedAuditEntry: Hashable, Sendable, Codable {
    public let id: [UInt8]
    public let tier: AuditTier
    public let hlc: HLC
    public let verb: UnifiedAuditVerb
    public let rowID: UUID
    public let fieldPath: String
    public let beforeValue: UnifiedAuditValue
    public let afterValue: UnifiedAuditValue
    public let originRowID: UUID?

    public init(tier: AuditTier,
                hlc: HLC,
                verb: UnifiedAuditVerb,
                rowID: UUID,
                fieldPath: String,
                beforeValue: UnifiedAuditValue,
                afterValue: UnifiedAuditValue,
                originRowID: UUID? = nil) {
        self.tier = tier
        self.hlc = hlc
        self.verb = verb
        self.rowID = rowID
        self.fieldPath = fieldPath
        self.beforeValue = beforeValue
        self.afterValue = afterValue
        self.originRowID = originRowID
        self.id = Self.computeID(
            tier: tier, hlc: hlc, verb: verb, rowID: rowID,
            fieldPath: fieldPath, beforeValue: beforeValue,
            afterValue: afterValue, originRowID: originRowID
        )
    }

    /// Explicit-ID initializer for decode paths that must trust the
    /// wire ID rather than recompute it. Precondition matches the
    /// SHA-256 32-byte invariant.
    public init(id: [UInt8],
                tier: AuditTier,
                hlc: HLC,
                verb: UnifiedAuditVerb,
                rowID: UUID,
                fieldPath: String,
                beforeValue: UnifiedAuditValue,
                afterValue: UnifiedAuditValue,
                originRowID: UUID? = nil) {
        precondition(id.count == 32, "audit id must be 32-byte SHA-256")
        self.id = id
        self.tier = tier
        self.hlc = hlc
        self.verb = verb
        self.rowID = rowID
        self.fieldPath = fieldPath
        self.beforeValue = beforeValue
        self.afterValue = afterValue
        self.originRowID = originRowID
    }

    /// Build the canonical wire-encoding bytes that feed the content
    /// hash. Encoding is little-endian and length-prefixed; round-trip
    /// stability matters because two replicas must produce identical
    /// bytes for the same logical entry.
    fileprivate static func wireBytes(
        tier: AuditTier,
        hlc: HLC,
        verb: UnifiedAuditVerb,
        rowID: UUID,
        fieldPath: String,
        beforeValue: UnifiedAuditValue,
        afterValue: UnifiedAuditValue,
        originRowID: UUID?
    ) -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: Array(tier.rawValue.utf8))
        out.append(0x1F)
        out.append(contentsOf: hlc.wireBytes)
        out.append(contentsOf: Array(verb.rawValue.utf8))
        out.append(0x1F)
        withUnsafeBytes(of: rowID.uuid) { buf in
            out.append(contentsOf: buf)
        }
        let pathBytes = Array(fieldPath.utf8)
        let pathLen = UInt32(pathBytes.count)
        for shift in stride(from: 0, through: 24, by: 8) {
            out.append(UInt8((pathLen >> shift) & 0xFF))
        }
        out.append(contentsOf: pathBytes)
        out.append(contentsOf: beforeValue.wireBytes)
        out.append(contentsOf: afterValue.wireBytes)
        if let origin = originRowID {
            out.append(0x01)
            withUnsafeBytes(of: origin.uuid) { buf in
                out.append(contentsOf: buf)
            }
        } else {
            out.append(0x00)
        }
        return out
    }

    fileprivate static func computeID(
        tier: AuditTier,
        hlc: HLC,
        verb: UnifiedAuditVerb,
        rowID: UUID,
        fieldPath: String,
        beforeValue: UnifiedAuditValue,
        afterValue: UnifiedAuditValue,
        originRowID: UUID?
    ) -> [UInt8] {
        let bytes = wireBytes(
            tier: tier, hlc: hlc, verb: verb, rowID: rowID,
            fieldPath: fieldPath, beforeValue: beforeValue,
            afterValue: afterValue, originRowID: originRowID
        )
        return UnifiedAuditSHA256.hash(bytes)
    }

    /// Returns true if this entry's `id` matches the SHA-256 of its
    /// wire encoding — i.e., the entry is self-consistent. A legitimate
    /// locally-produced entry always passes; an externally-supplied entry
    /// whose id was crafted to collide with a different entry fails.
    ///
    /// Used by `UnifiedAuditLog` on every ingress path (add, merge,
    /// decode) as the structural defence against same-id/different-content
    /// CRDT forgery (codex a477800).
    fileprivate func contentIDMatches() -> Bool {
        let expected = Self.computeID(
            tier: tier, hlc: hlc, verb: verb, rowID: rowID,
            fieldPath: fieldPath, beforeValue: beforeValue,
            afterValue: afterValue, originRowID: originRowID
        )
        return expected == id
    }
}

// MARK: - G-Set log

/// Grow-only set of `UnifiedAuditEntry` per cookbook §5.1.
///
/// CRDT properties:
///   - idempotent: re-adding an entry with the same `id` is a no-op.
///   - commutative + associative: `merge` is set union over entry IDs.
///   - convergent: two replicas that exchange entries until quiescent
///     hold identical entry sets and therefore project to identical
///     state (cookbook §5.4).
///
/// The log is a value type (struct) so callers may store it inside an
/// actor or hand snapshots across actor boundaries cheaply. Mutation
/// goes through `add` / `merge` only; reads are pure projections.
public struct UnifiedAuditLog: Sendable {

    /// Backing store keyed by entry content hash for O(1) dedupe.
    /// `[UInt8]` keys are wrapped through `HashKey` for use in a
    /// dictionary; the dictionary is the canonical G-Set.
    public private(set) var entries: [UnifiedAuditEntryKey: UnifiedAuditEntry]

    /// Count of entries rejected on THIS log's ingress (`add` calls that
    /// failed the content-id check) since the log was constructed.
    ///
    /// AUDIT-ALERT-RESTORE (2026-07-09, Bob's option-1 ruling): secfix
    /// 5101e112 made ingress rejection silent (log-only), which made
    /// NEURONKIT_SPEC C-4/C-12 (the maintenance daemon alerts on
    /// tampering) structurally unreachable — a rejected entry never
    /// reaches `AuditChainVerifier`, so the daemon's chain walk always
    /// saw a clean log and never proposed. This counter restores
    /// observability at the ingress boundary itself: every `add` call
    /// that rejects an entry increments it, regardless of which caller
    /// invoked `add` (directly, via `add(contentsOf:)`, via `merge`, or
    /// via `Codable` decode). `MaintenanceDaemon.runCycle` reads this
    /// count off the log snapshot `currentAuditLog(in:)` returns and
    /// emits an integrity proposal when it is greater than zero — see
    /// `MaintenanceDecision.decide` step 0.
    ///
    /// Monotonic for the lifetime of this value: it only increases, is
    /// NOT part of the CRDT state (see the custom `==` below, which
    /// compares `entries` only), and is not carried across `merge` —
    /// merging only re-adds entries that already survived the SOURCE
    /// log's own ingress, so a source log's rejections are not
    /// double-counted into the destination log.
    public private(set) var rejectedEntryCount: Int = 0

    /// Initialise from an array of entries. Each entry is validated via
    /// `add`; forged entries (id does not match SHA-256 of wire encoding)
    /// are silently dropped. Honest locally-constructed entries always
    /// pass because `UnifiedAuditEntry.init` computes the id itself.
    public init(entries: [UnifiedAuditEntry] = []) {
        self.entries = [:]
        for e in entries { add(e) }
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// Add a single entry. Idempotent for honest entries.
    ///
    /// Security (codex a477800): the entry's content id is recomputed
    /// from its wire encoding on every call. If the recomputed id does
    /// not match `entry.id`, the entry is rejected with an error-level
    /// log, `rejectedEntryCount` is incremented, and the entry is not
    /// inserted. This prevents a peer supplying a forged
    /// (same-id, different-content) entry from overwriting an honest
    /// one in the G-Set, which would break CRDT convergence and
    /// constitute audit forgery. Federation peer-log merge relies on
    /// this defence; any future non-local audit ingress must route
    /// through `add` or `merge` to obtain it.
    public mutating func add(_ entry: UnifiedAuditEntry) {
        guard entry.contentIDMatches() else {
            Self.logger.error(
                "audit entry rejected on add: id does not match SHA-256 of wire encoding (codex a477800)"
            )
            rejectedEntryCount += 1
            return
        }
        entries[UnifiedAuditEntryKey(id: entry.id)] = entry
    }

    /// Add many entries. Equivalent to repeated `add`; each entry is
    /// individually validated.
    public mutating func add<S: Sequence>(contentsOf seq: S) where S.Element == UnifiedAuditEntry {
        for e in seq { add(e) }
    }

    /// CRDT join. Merging two G-Sets is set union over entry IDs.
    ///
    /// FEDERATION BOUNDARY NOTE: This method is the structural gate
    /// that future federation peer-log merge relies on. Every entry
    /// from a peer-supplied log must route through `merge` (or `add`)
    /// to obtain the content-id verification below. Do not add
    /// alternative ingress paths that bypass this check.
    ///
    /// Each entry's SHA-256 content id is recomputed before insertion.
    /// Forged or corrupted entries are rejected, preserving CRDT
    /// convergence and audit integrity (codex a477800).
    public mutating func merge(_ other: UnifiedAuditLog) {
        for (_, v) in other.entries {
            add(v)  // validated ingress — forged entries dropped
        }
    }

    /// All entries in HLC order, regardless of tier. Stable secondary
    /// keys (tier rawValue, then id) keep ordering deterministic even
    /// for entries that share an HLC.
    public var orderedEntries: [UnifiedAuditEntry] {
        entries.values.sorted { Self.compareOrdering($0, $1) }
    }

    /// Entries restricted to a single tier, in HLC order.
    public func entries(tier: AuditTier) -> [UnifiedAuditEntry] {
        entries.values.filter { $0.tier == tier }
            .sorted { Self.compareOrdering($0, $1) }
    }

    /// Entries scoped to one row, in HLC order. Rows are tier-scoped
    /// (a LocusKit row UUID and a CorpusKit row UUID live in different
    /// namespaces), so the caller passes the tier the row belongs to.
    public func entries(forRow rowID: UUID, tier: AuditTier) -> [UnifiedAuditEntry] {
        entries.values.filter { $0.rowID == rowID && $0.tier == tier }
            .sorted { Self.compareOrdering($0, $1) }
    }

    /// Entries strictly newer than `cutoff`. Used by sync to ship the
    /// delta to a peer.
    public func entries(since cutoff: HLC) -> [UnifiedAuditEntry] {
        entries.values.filter { $0.hlc > cutoff }
            .sorted { Self.compareOrdering($0, $1) }
    }

    /// Entries with HLC at or before `asOf`. Drives the asOf
    /// reconstruction in `AuditProjection`.
    public func entries(asOf cutoff: HLC) -> [UnifiedAuditEntry] {
        entries.values.filter { $0.hlc <= cutoff }
            .sorted { Self.compareOrdering($0, $1) }
    }

    /// Total ordering across tiers. Primary: HLC. Tie-breakers exist so
    /// two entries with identical HLC and different content still order
    /// deterministically — a corner case but the projection requires it.
    fileprivate static func compareOrdering(_ a: UnifiedAuditEntry, _ b: UnifiedAuditEntry) -> Bool {
        if a.hlc != b.hlc { return a.hlc < b.hlc }
        if a.tier != b.tier { return a.tier.rawValue < b.tier.rawValue }
        return Self.compareBytes(a.id, b.id)
    }

    private static func compareBytes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        let count = min(lhs.count, rhs.count)
        for i in 0..<count {
            if lhs[i] != rhs[i] { return lhs[i] < rhs[i] }
        }
        return lhs.count < rhs.count
    }
}

// MARK: - Equatable

extension UnifiedAuditLog: Equatable {
    /// Structural equality over the G-Set only. `rejectedEntryCount` is
    /// deliberately excluded: it is per-ingress-operation telemetry, not
    /// CRDT state, and including it would break the convergence property
    /// tests rely on (two logs holding the same entries must compare
    /// equal regardless of how many rejected-entry `add` calls either one
    /// happened to observe on the way there).
    public static func == (lhs: UnifiedAuditLog, rhs: UnifiedAuditLog) -> Bool {
        lhs.entries == rhs.entries
    }
}

// MARK: - Entry key

/// Hashable wrapper around the 32-byte content hash. `[UInt8]` is
/// `Hashable` in Swift but the wrapper makes intent explicit and lets
/// the dictionary type signature read cleanly at call sites.
public struct UnifiedAuditEntryKey: Hashable, Sendable, Codable {
    public let id: [UInt8]
    public init(id: [UInt8]) {
        precondition(id.count == 32, "entry key must be 32-byte SHA-256")
        self.id = id
    }
}

// MARK: - SHA-256
/// Content-hash facade for audit entries. F18.3 (2026-05-27): the
/// self-contained SHA-256 that lived here was removed in favor of the
/// canonical `SHA256` (FIPS 180-4, NIST-vector gated). The
/// facade name is kept so call sites and tests are unchanged; the math
/// is now centralized in the substrate per the atomic-centralization rule.
enum UnifiedAuditSHA256 {
    static func hash(_ bytes: [UInt8]) -> [UInt8] {
        return SHA256.hash(bytes)
    }
}

// MARK: - Codable (custom — validates entry content IDs on every path)
//
// The synthesised `Codable` for `[UnifiedAuditEntryKey: UnifiedAuditEntry]`
// (a non-String-keyed dictionary) encodes as alternating-key-value pairs and
// decodes directly into the backing store, bypassing `add`. Custom encode /
// decode is therefore required so the security verification in `add` runs for
// any entry that enters the log via the serialisation path as well (codex a477800).
//
// Wire format: `{"entries": [<UnifiedAuditEntry>, ...]}` — array sorted by
// entry id (byte-lexicographic) for determinism. Mirrors the `GSetAuditLog`
// wire shape in SubstrateTypes.

extension UnifiedAuditLog: Codable {

    private enum CodingKeys: String, CodingKey { case entries }

    /// Decode a log from the wire format, validating every entry's
    /// SHA-256 content id on ingress. Forged or corrupted entries are
    /// silently dropped; the caller receives only honest entries.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entryArray = try container.decode([UnifiedAuditEntry].self, forKey: .entries)
        self.entries = [:]
        for e in entryArray {
            add(e)  // each entry verified via content-id check
        }
    }

    /// Encode the log as a sorted array of entries for determinism and
    /// human readability. The backing dictionary's iteration order is
    /// unspecified; sorting by id gives a stable wire encoding.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let sorted = entries.values.sorted { Self.compareBytes($0.id, $1.id) }
        try container.encode(sorted, forKey: .entries)
    }
}

// MARK: - Logger

extension UnifiedAuditLog {
    /// Module logger. Held as a static so callers do not allocate a
    /// new logger per access. Fleet-standard subsystem and category
    /// per CLAUDE.md.
    static let logger = Logger(
        subsystem: "com.mootx01.kit",
        category: "GeniusLocusKit.UnifiedAuditLog"
    )
}
