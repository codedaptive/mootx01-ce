// ConflictProjection.swift
//
// Deterministic Contradiction Projection v0.1 — the substrate core
// (DCP M1; contract: docs_internal/analysis/DCP_M0_CONTRACT.md; spec
// E7EE4031). Pure value types and pure functions: no database, clock,
// network, locale, or random dependency anywhere in this file.
//
// The mathematical contract: a set of claims C is contradictory under
// rule set R exactly when R ∪ C is unsatisfiable. v0.1 proves the
// pairwise functional-dependency subset — same canonical key + same
// dimension + overlapping scope/time + mutually exclusive normalized
// values — and reports everything weaker as candidate evidence, never
// proof. Retrieval proposes; typed constraints prove; provenance
// explains; humans settle truth.
//
// The lexical ConflictCue (ConflictCue.swift) is UNCHANGED by this
// module: its output is candidate evidence for review, not proof.
//
// Twin: Rust `conflict_projection.rs`. Parity is behavioral — the
// shared golden corpus requires byte-identical canonical values,
// outcome classes, reason codes, and stable identities.

import Foundation
import CryptoKit

// MARK: - Typed values

/// A typed canonical value (M0 §3). `canonicalBytes` is the identity
/// serialization — byte-for-byte specified, shared with Rust, and free
/// of locale, floating point, and unordered collections.
public enum TypedConflictValue: Equatable, Sendable {
    case boolean(Bool)
    /// Base-10 integer.
    case integer(Int64)
    /// Exact decimal: integer mantissa and decimal exponent (scale).
    /// `1500000` is `(1500000, 0)`; `12.50` normalizes to `(125, 1)`.
    /// No floating point anywhere — comparison is exact after scale
    /// alignment, and serialization strips trailing fraction zeros.
    case decimal(mantissa: Int64, scale: UInt8)
    /// Whole seconds (exact unit conversion only: h×3600, min×60).
    case duration(seconds: Int64)
    /// Explicit-format calendar date.
    case date(year: Int, month: Int, day: Int)
    /// Epoch seconds.
    case instant(Int64)
    /// Numeric dot-separated version components.
    case version([Int])
    /// A member of a rule's closed enum set: (ruleID, canonical token).
    /// The token is NFC, lowercased, whitespace-collapsed, trimmed;
    /// membership was checked by the normalizer that built this value.
    case enumToken(ruleID: String, token: String)
    /// A canonical scoped entity identifier (NFC, trimmed).
    case entityID(String)
    /// A normalized string (NFC, trimmed, whitespace-collapsed, case
    /// preserved). Equality only — similarity never proves anything.
    case string(String)

    /// The M0 §3 canonical identity bytes.
    public var canonicalBytes: String {
        switch self {
        case .boolean(let b): return "b:\(b ? "true" : "false")"
        case .integer(let i): return "i:\(i)"
        case .decimal(let mantissa, let scale):
            // Strip trailing fraction zeros by reducing scale while the
            // mantissa divides by 10; integral values render undotted.
            var m = mantissa
            var s = Int(scale)
            while s > 0 && m % 10 == 0 { m /= 10; s -= 1 }
            if s == 0 { return "d:\(m)" }
            let negative = m < 0
            let digits = String(m.magnitude)
            let padded = String(repeating: "0", count: max(0, s + 1 - digits.count)) + digits
            let cut = padded.index(padded.endIndex, offsetBy: -s)
            let intPart = String(padded[..<cut])
            let fracPart = String(padded[cut...])
            return "d:\(negative ? "-" : "")\(intPart).\(fracPart)"
        case .duration(let secs): return "dur:\(secs)"
        case .date(let y, let m, let d):
            return String(format: "dt:%04d-%02d-%02d", y, m, d)
        case .instant(let t): return "ts:\(t)"
        case .version(let comps):
            return "v:" + comps.map(String.init).joined(separator: ".")
        case .enumToken(let ruleID, let token): return "e:\(ruleID)#\(token)"
        case .entityID(let id): return "id:\(id)"
        case .string(let s): return "s:\(s)"
        }
    }

    /// Exact equivalence — canonical-byte equality. (Equivalent units
    /// were folded by the normalizer; `1h` and `60min` both became
    /// `dur:3600` before ever reaching a comparison.)
    public func isEquivalent(to other: TypedConflictValue) -> Bool {
        canonicalBytes == other.canonicalBytes
    }
}

// MARK: - Time

/// Validity basis (M0 §5). Closed semantics; `unknown` is distinct
/// from all-time.
public enum TemporalBasis: Equatable, Sendable {
    case point(epochSeconds: Int64)
    case interval(from: Int64, to: Int64)
    case unknown

    public var canonicalBytes: String {
        switch self {
        case .point(let t): return "t:pt:\(t)"
        case .interval(let a, let b): return "t:iv:\(a):\(b)"
        case .unknown: return "t:unknown"
        }
    }

    /// Closed-interval overlap; `nil` when either side is unknown
    /// (unknown is a tri-state, never coerced to a boolean).
    public func overlaps(_ other: TemporalBasis) -> Bool? {
        func range(_ b: TemporalBasis) -> (Int64, Int64)? {
            switch b {
            case .point(let t): return (t, t)
            case .interval(let a, let z): return (a, z)
            case .unknown: return nil
            }
        }
        guard let a = range(self), let b = range(other) else { return nil }
        return a.0 <= b.1 && b.0 <= a.1
    }

    /// Malformed interval (from > to) — an InvalidInput condition.
    public var isMalformed: Bool {
        if case .interval(let a, let b) = self { return a > b }
        return false
    }
}

// MARK: - Signature

/// Claim standing at projection time.
public enum ConflictClaimStatus: String, Equatable, Sendable {
    case asserted, proposed, withdrawn, rejected
}

/// A source-grounded normalized claim (M0 §3, spec §6).
public struct ConflictSignature: Equatable, Sendable {
    public let key: String
    public let dimension: String
    public let value: TypedConflictValue
    public let sourceDrawerID: String
    /// Transaction time (KGFact.filedAt), epoch seconds.
    public let transactionTime: Int64
    public let validity: TemporalBasis
    public let status: ConflictClaimStatus
    public let ruleID: String
    public let ruleVersion: Int
    public let extractorID: String?
    public let evidenceLocator: String?

    public init(
        key: String, dimension: String, value: TypedConflictValue,
        sourceDrawerID: String, transactionTime: Int64,
        validity: TemporalBasis, status: ConflictClaimStatus,
        ruleID: String, ruleVersion: Int,
        extractorID: String? = nil, evidenceLocator: String? = nil
    ) {
        self.key = key
        self.dimension = dimension
        self.value = value
        self.sourceDrawerID = sourceDrawerID
        self.transactionTime = transactionTime
        self.validity = validity
        self.status = status
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.extractorID = extractorID
        self.evidenceLocator = evidenceLocator
    }

    /// M0 §3 identity input, before hashing. Domain-separated.
    public var stableIDInput: String {
        "dcp1|\(ruleID)@\(ruleVersion)|\(key)|\(dimension)|"
            + "\(value.canonicalBytes)|\(sourceDrawerID)|\(validity.canonicalBytes)"
    }

    /// SHA-256 of `stableIDInput`, lowercase hex.
    public var stableID: String {
        ConflictIdentity.sha256Hex(stableIDInput)
    }
}

enum ConflictIdentity {
    static func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Pair-order-invariant result identity (M0 §3): the two stable
    /// IDs sorted lexicographically, joined with `+`, re-digested.
    static func pairID(_ a: String, _ b: String) -> String {
        let sorted = [a, b].sorted()
        return sha256Hex("dcp1|pair|\(sorted[0])+\(sorted[1])")
    }
}

// MARK: - Reason codes

/// Stable API spellings (M0 §4 — exactly the spec §11 list).
public enum ConflictReason: String, Equatable, Sendable, CaseIterable {
    case sameCoordinate = "same_coordinate"
    case valueEquivalent = "value_equivalent"
    case valuesExclusive = "values_exclusive"
    case cardinalityMulti = "cardinality_multi"
    case scopeMismatch = "scope_mismatch"
    case scopeUnknown = "scope_unknown"
    case validityOverlap = "validity_overlap"
    case validityDisjoint = "validity_disjoint"
    case validityUnknown = "validity_unknown"
    case acceptedSupersession = "accepted_supersession"
    case sourceBelowThreshold = "source_below_threshold"
    case parseAmbiguous = "parse_ambiguous"
    case ruleUnknown = "rule_unknown"
    case bucketTruncated = "bucket_truncated"
}

// MARK: - Rules

/// Predicate cardinality (spec §8).
public enum ConflictCardinality: Equatable, Sendable {
    case single
    case set
    case bag
    case unknown
}

/// A versioned dimension rule (spec §8). v0.1 rules are code, not data.
public struct ConflictRule: Sendable {
    public let ruleID: String
    public let version: Int
    public let dimension: String
    public let aliases: [String]
    public let cardinality: ConflictCardinality
    /// Normalize a raw object string to a typed value; nil = the value
    /// does not parse under this rule (InvalidInput at evaluation).
    public let normalize: @Sendable (String) -> TypedConflictValue?

    public init(
        ruleID: String, version: Int, dimension: String,
        aliases: [String] = [], cardinality: ConflictCardinality,
        normalize: @escaping @Sendable (String) -> TypedConflictValue?
    ) {
        self.ruleID = ruleID
        self.version = version
        self.dimension = dimension
        self.aliases = aliases
        self.cardinality = cardinality
        self.normalize = normalize
    }
}

/// Total registry: always answers, with `UnknownRule` for anything not
/// registered. UnknownRule can never prove a contradiction.
public struct ConflictRuleRegistry: Sendable {
    /// The sentinel identity of the unknown rule.
    public static let unknownRuleID = "dim.unknown"

    private let byDimension: [String: ConflictRule]

    public init(rules: [ConflictRule]) {
        var map: [String: ConflictRule] = [:]
        for rule in rules {
            map[ConflictNormalize.dimensionKey(rule.dimension)] = rule
            for alias in rule.aliases {
                map[ConflictNormalize.dimensionKey(alias)] = rule
            }
        }
        self.byDimension = map
    }

    /// Total lookup: a registered rule, or nil meaning UnknownRule.
    public func rule(forDimension dimension: String) -> ConflictRule? {
        byDimension[ConflictNormalize.dimensionKey(dimension)]
    }

    /// The v0.1 registry (M0 §2): the four planted enum dimensions and
    /// the two meeting-decision dimensions.
    public static let v01: ConflictRuleRegistry = {
        func enumRule(_ ruleID: String, _ dimension: String, _ members: [String]) -> ConflictRule {
            let canon = Set(members.map(ConflictNormalize.enumToken))
            return ConflictRule(
                ruleID: ruleID, version: 1, dimension: dimension,
                cardinality: .single
            ) { raw in
                let token = ConflictNormalize.enumToken(raw)
                guard canon.contains(token) else { return nil }
                return .enumToken(ruleID: ruleID, token: token)
            }
        }
        return ConflictRuleRegistry(rules: [
            enumRule("dim.person.employer", "employer",
                     ["Acme Robotics", "Northwind Analytics", "Beta Corp",
                      "Vireo Systems", "Halcyon Labs"]),
            enumRule("dim.person.city", "city",
                     ["Lisbon", "Toronto", "Osaka", "Nairobi", "Reykjavik"]),
            enumRule("dim.person.role", "role",
                     ["staff engineer", "engineering manager",
                      "principal architect", "director of platform",
                      "technical lead"]),
            enumRule("dim.person.primary_language", "primary language",
                     ["Swift", "Rust", "Elixir", "OCaml", "Zig"]),
            ConflictRule(
                ruleID: "dim.decision.launch_date", version: 1,
                dimension: "decision:launch_date", cardinality: .single,
                normalize: { ConflictNormalize.isoDate($0).map {
                    .date(year: $0.0, month: $0.1, day: $0.2) } }),
            ConflictRule(
                ruleID: "dim.decision.budget_ceiling", version: 1,
                dimension: "decision:budget_ceiling", cardinality: .single,
                normalize: { ConflictNormalize.usdDecimal($0) }),
        ])
    }()
}

// MARK: - Normalizers

/// Deterministic normalization helpers (M0 §3). No locale, no Date().
public enum ConflictNormalize {

    /// NFC + trim + collapse internal whitespace to single spaces.
    public static func collapse(_ raw: String) -> String {
        let nfc = raw.precomposedStringWithCanonicalMapping
        let trimmed = nfc.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    /// Enum-token canonical form: collapsed + lowercased.
    public static func enumToken(_ raw: String) -> String {
        collapse(raw).lowercased()
    }

    /// Dimension/key canonical form for registry lookup and coordinate
    /// identity: collapsed + lowercased.
    public static func dimensionKey(_ raw: String) -> String {
        collapse(raw).lowercased()
    }

    /// Strict ISO date `YYYY-MM-DD` only; anything else (including
    /// ambiguous `03/04/26`) is nil → parse_ambiguous upstream.
    public static func isoDate(_ raw: String) -> (Int, Int, Int)? {
        let s = collapse(raw)
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        return (y, m, d)
    }

    /// USD decimal with exact `k`/`m` suffix scaling (×1e3 / ×1e6) and
    /// an optional `USD`/`$` marker. `1.5m USD` → d:1500000. Exact
    /// integer arithmetic only.
    public static func usdDecimal(_ raw: String) -> TypedConflictValue? {
        var s = collapse(raw).lowercased()
        s = s.replacingOccurrences(of: "usd", with: "")
        s = s.replacingOccurrences(of: "$", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        var multiplier: Int64 = 1
        if s.hasSuffix("k") { multiplier = 1_000; s = String(s.dropLast()) }
        else if s.hasSuffix("m") { multiplier = 1_000_000; s = String(s.dropLast()) }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let negative = s.hasPrefix("-")
        if negative { s = String(s.dropFirst()) }
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else { return nil }
        guard let intPart = Int64(pieces[0]) else { return nil }
        var mantissa = intPart
        var scale = 0
        if pieces.count == 2 {
            let frac = pieces[1]
            guard frac.count <= 6, let fracVal = Int64(frac) else { return nil }
            scale = frac.count
            var scaled = mantissa
            for _ in 0..<scale { scaled = scaled * 10 }
            mantissa = scaled + fracVal
        }
        mantissa *= multiplier
        // Fold the multiplier into the mantissa (scale unchanged), then
        // reduce: canonicalBytes strips trailing zeros anyway; keep the
        // exact pair.
        if negative { mantissa = -mantissa }
        return .decimal(mantissa: mantissa, scale: UInt8(scale))
    }

    /// Exact duration: `<n>h`/`<n> h`/`<n>min`/`<n>s` → seconds; whole
    /// units only.
    public static func duration(_ raw: String) -> TypedConflictValue? {
        let s = collapse(raw).lowercased().replacingOccurrences(of: " ", with: "")
        func value(_ suffix: String, _ mult: Int64) -> TypedConflictValue? {
            guard s.hasSuffix(suffix), let n = Int64(s.dropLast(suffix.count))
            else { return nil }
            return .duration(seconds: n * mult)
        }
        return value("min", 60) ?? value("h", 3600) ?? value("s", 1)
    }
}

// MARK: - Outcomes

/// Exactly one primary outcome per evaluated pair (M0 §6 precedence).
public enum ConflictOutcomeKind: String, Equatable, Sendable {
    case invalidInput = "invalid_input"
    case irrelevant = "irrelevant"
    case agreement = "agreement"
    case compatiblePlurality = "compatible_plurality"
    case historicalSuccession = "historical_succession"
    case provenContradiction = "proven_contradiction"
    case candidateReview = "candidate_review"
}

/// The evaluation record (spec §11): identity, provenance, basis, and
/// reason codes. The explanation is BUILT from reason codes by the
/// caller; this type carries no generated prose.
public struct ConflictOutcome: Equatable, Sendable {
    public let kind: ConflictOutcomeKind
    /// Pair-order-invariant stable result identity.
    public let resultID: String
    public let ruleID: String
    public let ruleVersion: Int
    public let key: String
    public let dimension: String
    public let sourceDrawerIDs: [String]
    public let valueDigests: [String]
    public let reasons: [ConflictReason]
}

// MARK: - Evaluator

/// Pairwise pure evaluation (spec §5 predicate list, M0 §6 precedence).
/// Storage- and tunnel-independent: accepted-supersession context is a
/// caller-supplied boolean (M3 resolves tunnels; this stays pure).
public enum ConflictEvaluator {

    public static func evaluate(
        _ a: ConflictSignature,
        _ b: ConflictSignature,
        registry: ConflictRuleRegistry,
        acceptedSupersession: Bool = false
    ) -> ConflictOutcome {
        func outcome(_ kind: ConflictOutcomeKind, _ reasons: [ConflictReason]) -> ConflictOutcome {
            ConflictOutcome(
                kind: kind,
                resultID: ConflictIdentity.pairID(a.stableID, b.stableID),
                ruleID: a.ruleID,
                ruleVersion: a.ruleVersion,
                key: a.key,
                dimension: a.dimension,
                sourceDrawerIDs: [a.sourceDrawerID, b.sourceDrawerID].sorted(),
                valueDigests: [
                    ConflictIdentity.sha256Hex("dcp1|value|" + a.value.canonicalBytes),
                    ConflictIdentity.sha256Hex("dcp1|value|" + b.value.canonicalBytes),
                ].sorted(),
                reasons: reasons)
        }

        // 1. InvalidInput: malformed temporal basis, empty identity
        //    fields, or withdrawn/rejected standing offered as input
        //    (projection filters these; receiving one is a contract
        //    violation, not a silent skip).
        if a.validity.isMalformed || b.validity.isMalformed
            || a.key.isEmpty || b.key.isEmpty
            || a.sourceDrawerID.isEmpty || b.sourceDrawerID.isEmpty
            || a.status == .withdrawn || a.status == .rejected
            || b.status == .withdrawn || b.status == .rejected {
            return outcome(.invalidInput, [.parseAmbiguous])
        }

        // 2. Irrelevant: different coordinate (key or dimension).
        let keyA = ConflictNormalize.dimensionKey(a.key)
        let keyB = ConflictNormalize.dimensionKey(b.key)
        let dimA = ConflictNormalize.dimensionKey(a.dimension)
        let dimB = ConflictNormalize.dimensionKey(b.dimension)
        if keyA != keyB {
            return outcome(.irrelevant, [.scopeMismatch])
        }
        if dimA != dimB {
            return outcome(.irrelevant, [.scopeMismatch])
        }

        var reasons: [ConflictReason] = [.sameCoordinate]

        // Rule lookup is total: unknown rule → CandidateReview (a
        // lexical or unregistered dimension can never prove).
        guard let rule = registry.rule(forDimension: a.dimension) else {
            return outcome(.candidateReview, reasons + [.ruleUnknown])
        }

        // 3. Agreement: equivalent normalized values.
        if a.value.isEquivalent(to: b.value) {
            return outcome(.agreement, reasons + [.valueEquivalent])
        }

        // 4. CompatiblePlurality: the rule permits both.
        switch rule.cardinality {
        case .set, .bag:
            return outcome(.compatiblePlurality, reasons + [.cardinalityMulti])
        case .unknown:
            return outcome(.candidateReview, reasons + [.ruleUnknown])
        case .single:
            break
        }

        // 5. HistoricalSuccession: accepted ordering, or disjoint
        //    validity, makes both historically coherent. Recency alone
        //    is NEVER supersession — the flag comes from an accepted
        //    tunnel resolved by the caller.
        if acceptedSupersession {
            return outcome(.historicalSuccession, reasons + [.acceptedSupersession])
        }
        switch a.validity.overlaps(b.validity) {
        case .some(false):
            return outcome(.historicalSuccession, reasons + [.validityDisjoint])
        case .some(true):
            reasons.append(.validityOverlap)
        case .none:
            // Unknown validity: v0.1 policy `unknown-pair-concurrent`
            // (M0 §5) — BOTH unknown is treated as concurrent with the
            // reason recorded; unknown-vs-known stays review.
            if case .unknown = a.validity, case .unknown = b.validity {
                reasons.append(.validityUnknown)
            } else {
                return outcome(.candidateReview, reasons + [.validityUnknown])
            }
        }

        // 6. ProvenContradiction: single-valued, non-equivalent,
        //    concurrent.
        return outcome(.provenContradiction, reasons + [.valuesExclusive])
    }
}
