// TunnelReviewLedger.swift
//
// MXE-CT3 P2.5 — the review-ladder endorsement ledger carried in the
// tunnels table's nullable JSON `ext` column.
//
// Ladder: Rejected / Proposed / Endorsed / Accepted. A model (AI)
// reviewer may reject and endorse; ONLY the user accepts — edge
// activation stays human-authoritative. "Endorsed" is NOT a lifecycle
// case: it is bit 14 of `operationalBitmap` on a still-`.proposed`
// tunnel, and this ledger is the record behind that bit.
//
// ## Wire shape (identical in both ports, canonical serialization)
//
// ```json
// {
//   "endorsements": [{"at": "2026-08-07T12:00:00Z", "by": "claude", "tier": 2}],
//   "objections":   [{"at": "2026-08-07T12:05:00Z", "by": "apple-onboard", "tier": 2}],
//   "reviewedBy":   "owner"
// }
// ```
//
// - `endorsements` — one entry per DISTINCT endorser id ("one vote per
//   endorser"): re-endorsement by the same id updates `at`/`tier` only.
// - `objections` — model objections, same one-per-reviewer rule.
// - `reviewedBy` — identity of the most recent lifecycle reviewer
//   (user accept/reject via `respondToTunnel`, or the model reviewer
//   that withdrew the proposal). Recorded on every transition.
// - `tier` — the contradiction-tier lens the reviewer judged under
//   (1 typed / 2 lexical-structural / 3 lexical-value).
//
// ## Determinism contract
//
// Serialization is CANONICAL and must be byte-identical across the
// Swift and Rust ports for identical inputs (golden-fixture tested):
// - object keys sorted byte-lexicographically at EVERY level,
// - entry arrays sorted by `by` ascending (byte order),
// - compact output (no whitespace),
// - string escaping mirrors serde_json exactly: `\"`, `\\`, `\b`,
//   `\f`, `\n`, `\r`, `\t`, and `\u00xx` (lowercase hex) for all
//   other control characters; everything else is raw UTF-8,
// - empty arrays and nil `reviewedBy` are OMITTED,
// - timestamps are whole-second UTC ISO-8601 (`yyyy-MM-ddTHH:mm:ssZ`)
//   formatted by the shared civil-calendar algorithm below — never a
//   platform formatter, so both ports emit identical bytes.
//
// Cross-port caveat (documented, not load-bearing): non-integer
// numbers inside UNKNOWN keys round-trip via each port's
// shortest-representation float formatter; the ledger's own fields are
// strings and integers only, so ledger-managed content is always
// byte-identical.
//
// ## Tolerance contract
//
// - nil / empty `ext` parses to the empty ledger.
// - Unknown top-level keys are preserved verbatim on rewrite (the
//   `ext` column is the one forward-compat slot per entity — this
//   ledger must coexist with future tenants).
// - Malformed JSON, or a KNOWN key with the wrong shape, is
//   corruption: parsing throws `LocusKitError.invalidContent`
//   (fail-loud per house discipline — never silently overwritten).

import Foundation

// MARK: - Ledger entry

/// One endorsement or objection: who, when (canonical ISO-8601 UTC
/// whole seconds), and under which contradiction-tier lens.
public struct TunnelReviewEntry: Sendable, Equatable {
    /// Reviewer identity, e.g. "apple-onboard", "claude",
    /// "dream-adjudicator@1". The model FAMILY used by the review-queue
    /// diversity bonus is the prefix before the first "-" or ":".
    public let by: String
    /// Canonical ISO-8601 UTC timestamp (whole seconds). Kept as a
    /// string: the canonical format sorts lexicographically in
    /// chronological order, so recency comparisons never re-parse.
    public let atISO: String
    /// Contradiction-tier lens judged (1 typed / 2 structural / 3 value).
    public let tier: Int

    public init(by: String, atISO: String, tier: Int) {
        self.by = by
        self.atISO = atISO
        self.tier = tier
    }
}

// MARK: - Ledger

/// Parsed form of the tunnel `ext` review ledger. See the file header
/// for the wire shape, determinism, and tolerance contracts.
public struct TunnelReviewLedger: Sendable, Equatable {

    /// Identity of the most recent lifecycle reviewer (accept/reject).
    public private(set) var reviewedBy: String?
    /// One entry per distinct endorser, kept sorted by `by` (byte order).
    public private(set) var endorsements: [TunnelReviewEntry]
    /// One entry per distinct model objector, kept sorted by `by`.
    public private(set) var objections: [TunnelReviewEntry]
    /// Unknown top-level `ext` keys, preserved verbatim on rewrite.
    /// Internal: shape is an implementation detail of the codec.
    var unknown: [(key: String, value: JSONCanonicalValue)]

    /// The three keys this ledger owns inside `ext`. Everything else is
    /// another tenant's and passes through untouched.
    static let ownedKeys: Set<String> = ["reviewedBy", "endorsements", "objections"]

    /// Empty ledger (fresh tunnel, no review activity).
    public init() {
        self.reviewedBy = nil
        self.endorsements = []
        self.objections = []
        self.unknown = []
    }

    // MARK: Parse (tolerant of unknown keys, fail-loud on corruption)

    /// Parse a tunnel's `ext` JSON into a ledger.
    ///
    /// nil / empty / whitespace-only `ext` yields the empty ledger.
    /// Malformed JSON, a non-object top level, or a KNOWN key with the
    /// wrong shape throws `LocusKitError.invalidContent` — corruption is
    /// surfaced, never silently overwritten. Unknown keys are captured
    /// for verbatim re-emission.
    public static func parse(_ ext: String?) throws -> TunnelReviewLedger {
        guard let ext, !ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TunnelReviewLedger()
        }
        let root: JSONCanonicalValue
        do {
            root = try JSONCanonicalValue.parse(ext)
        } catch {
            throw LocusKitError.invalidContent(
                "tunnel ext is not valid JSON (fail-loud, not overwritten): \(error)")
        }
        guard case .object(let pairs) = root else {
            throw LocusKitError.invalidContent(
                "tunnel ext must be a JSON object, got: \(ext.prefix(80))")
        }
        var ledger = TunnelReviewLedger()
        for (key, value) in pairs {
            switch key {
            case "reviewedBy":
                guard case .string(let s) = value else {
                    throw LocusKitError.invalidContent(
                        "tunnel ext reviewedBy must be a string")
                }
                ledger.reviewedBy = s
            case "endorsements":
                ledger.endorsements = try Self.entries(from: value, key: "endorsements")
            case "objections":
                ledger.objections = try Self.entries(from: value, key: "objections")
            default:
                ledger.unknown.append((key, value))
            }
        }
        // Canonical in-memory order matches the wire order.
        ledger.endorsements.sort { $0.by.utf8Lexicographic($1.by) }
        ledger.objections.sort { $0.by.utf8Lexicographic($1.by) }
        return ledger
    }

    private static func entries(
        from value: JSONCanonicalValue, key: String
    ) throws -> [TunnelReviewEntry] {
        guard case .array(let items) = value else {
            throw LocusKitError.invalidContent("tunnel ext \(key) must be an array")
        }
        return try items.map { item in
            guard case .object(let fields) = item else {
                throw LocusKitError.invalidContent(
                    "tunnel ext \(key) entries must be objects")
            }
            var by: String?
            var at: String?
            var tier: Int?
            for (k, v) in fields {
                switch (k, v) {
                case ("by", .string(let s)): by = s
                case ("at", .string(let s)): at = s
                case ("tier", .int(let n)): tier = Int(n)
                default:
                    // A known-key entry with an unexpected field is
                    // corruption of ledger-owned data — fail loud.
                    throw LocusKitError.invalidContent(
                        "tunnel ext \(key) entry has unexpected field \(k)")
                }
            }
            guard let by, let at, let tier else {
                throw LocusKitError.invalidContent(
                    "tunnel ext \(key) entry missing by/at/tier")
            }
            return TunnelReviewEntry(by: by, atISO: at, tier: tier)
        }
    }

    // MARK: Mutation (idempotent per reviewer)

    /// Record the lifecycle reviewer's identity (user accept/reject via
    /// `respondToTunnel`, or the model reviewer that withdrew).
    public mutating func recordReview(by reviewer: String) {
        reviewedBy = reviewer
    }

    /// Record an endorsement. One vote per distinct endorser: a repeat
    /// endorsement by the same id updates `at`/`tier` only and returns
    /// false (idempotent); a new endorser inserts sorted and returns true.
    @discardableResult
    public mutating func recordEndorsement(by: String, atISO: String, tier: Int) -> Bool {
        Self.upsert(&endorsements, TunnelReviewEntry(by: by, atISO: atISO, tier: tier))
    }

    /// Record a model objection. Same one-vote-per-reviewer rule as
    /// endorsements.
    @discardableResult
    public mutating func recordObjection(by: String, atISO: String, tier: Int) -> Bool {
        Self.upsert(&objections, TunnelReviewEntry(by: by, atISO: atISO, tier: tier))
    }

    private static func upsert(
        _ list: inout [TunnelReviewEntry], _ entry: TunnelReviewEntry
    ) -> Bool {
        if let i = list.firstIndex(where: { $0.by == entry.by }) {
            list[i] = entry
            return false
        }
        list.append(entry)
        list.sort { $0.by.utf8Lexicographic($1.by) }
        return true
    }

    // MARK: Derived facts

    /// Distinct endorser count — the base of the review-queue weight.
    public var distinctEndorserCount: Int { endorsements.count }

    /// True when the ledger holds BOTH a model endorsement and a model
    /// objection — the contested condition (bit 15).
    public var isContestedEvidence: Bool {
        !endorsements.isEmpty && !objections.isEmpty
    }

    /// Latest review activity (endorsement or objection) as canonical
    /// ISO — lexicographic max IS chronological max for this format.
    /// Nil when no model review has happened.
    public var latestActivityISO: String? {
        (endorsements + objections).map(\.atISO).max()
    }

    // MARK: Serialize (canonical)

    /// Canonical serialization per the determinism contract. Returns nil
    /// when the ledger holds nothing at all (no owned content AND no
    /// unknown tenant keys) so an untouched tunnel keeps `ext` NULL.
    public func serialized() -> String? {
        var pairs: [(String, JSONCanonicalValue)] = unknown
        if let reviewedBy {
            pairs.append(("reviewedBy", .string(reviewedBy)))
        }
        if !endorsements.isEmpty {
            pairs.append(("endorsements", Self.entriesValue(endorsements)))
        }
        if !objections.isEmpty {
            pairs.append(("objections", Self.entriesValue(objections)))
        }
        guard !pairs.isEmpty else { return nil }
        return JSONCanonicalValue.object(pairs).canonicalSerialized()
    }

    private static func entriesValue(_ entries: [TunnelReviewEntry]) -> JSONCanonicalValue {
        .array(entries.map { e in
            // Entry keys in byte order: at < by < tier. The canonical
            // serializer re-sorts anyway; listing them sorted keeps the
            // in-memory form and the wire form visibly identical.
            .object([
                ("at", .string(e.atISO)),
                ("by", .string(e.by)),
                ("tier", .int(Int64(e.tier)))
            ])
        })
    }

    // MARK: Canonical ISO-8601 (shared civil-calendar algorithm)

    /// Format a Date as canonical whole-second UTC ISO-8601.
    ///
    /// Truncates (floors) to whole seconds, then runs the same
    /// civil-from-days algorithm as the Rust twin
    /// (`tunnel_review_ledger::iso8601_seconds`) — a deliberate
    /// re-implementation instead of `ISO8601DateFormatter` so both ports
    /// emit identical bytes by construction, not by formatter luck.
    public static func isoTimestamp(_ date: Date) -> String {
        isoTimestamp(epochSeconds: Int64(date.timeIntervalSince1970.rounded(.down)))
    }

    /// Same, from raw epoch seconds. Algorithm: Howard Hinnant's
    /// `civil_from_days` (public domain), the standard days→(y,m,d)
    /// conversion; euclidean division keeps pre-1970 instants correct.
    public static func isoTimestamp(epochSeconds secs: Int64) -> String {
        let days = floorDiv(secs, 86_400)
        let sod = secs - days * 86_400 // seconds-of-day, always 0..<86400
        // civil_from_days
        let z = days + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097                                   // day-of-era 0..<146097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)             // day-of-year (Mar-based)
        let mp = (5 * doy + 2) / 153                                  // month index 0=Mar
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            y, m, d, sod / 3600, (sod % 3600) / 60, sod % 60)
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}

// MARK: - Ledger equality ignores tenant-key bookkeeping order

public extension TunnelReviewLedger {
    static func == (lhs: TunnelReviewLedger, rhs: TunnelReviewLedger) -> Bool {
        // Canonical bytes are the identity — two ledgers are equal iff
        // they serialize identically (covers unknown keys without
        // exposing their storage shape).
        lhs.serialized() == rhs.serialized()
    }
}

// MARK: - Canonical JSON value

/// Minimal JSON model with a canonical serializer, shared by the ledger
/// codec. Exists (instead of `JSONSerialization`) because the output
/// must be byte-identical to the Rust port: `JSONSerialization` escapes
/// forward slashes, its `.sortedKeys` ordering is a platform detail,
/// and neither is contractual. This serializer is the contract.
enum JSONCanonicalValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONCanonicalValue])
    // Pairs preserve parse order; canonicalSerialized() sorts by key.
    indirect case object([(key: String, value: JSONCanonicalValue)])

    static func == (lhs: JSONCanonicalValue, rhs: JSONCanonicalValue) -> Bool {
        lhs.canonicalSerialized() == rhs.canonicalSerialized()
    }

    // MARK: Parse (via JSONSerialization, then typed)

    /// Parse a JSON document string. Throws on malformed input.
    static func parse(_ text: String) throws -> JSONCanonicalValue {
        let data = Data(text.utf8)
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return from(any: any)
    }

    private static func from(any: Any) -> JSONCanonicalValue {
        switch any {
        case is NSNull:
            return .null
        case let n as NSNumber:
            // NSNumber collapses Bool/Int/Double — recover the JSON type.
            // CFBoolean detection first: `n as? Bool` alone would also
            // match 0/1 integers.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .bool(n.boolValue)
            }
            // JSONSerialization parses integer tokens to non-float
            // objCTypes and float tokens (e.g. "2.0") to "d"/"f" — use
            // that to keep the source token class through round-trips.
            let objCType = String(cString: n.objCType)
            if objCType != "d" && objCType != "f" {
                return .int(n.int64Value)
            }
            return .double(n.doubleValue)
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map(from(any:)))
        case let o as [String: Any]:
            // Sort at parse time: parse order from JSONSerialization
            // dictionaries is arbitrary, canonical order is not.
            let pairs = o
                .map { (key: $0.key, value: from(any: $0.value)) }
                .sorted { $0.key.utf8Lexicographic($1.key) }
            return .object(pairs)
        default:
            // JSONSerialization only produces the cases above; this arm
            // is unreachable but total.
            return .null
        }
    }

    // MARK: Canonical serialization

    /// Compact, sorted-key, serde_json-escaping-compatible output. See
    /// the determinism contract in the file header.
    func canonicalSerialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            if d.rounded() == d, abs(d) < 9.007199254740992e15 {
                // Integral doubles emit as "<n>.0" in both ports (Rust
                // f64 Display does the same), keeping the float/int
                // token distinction stable through round-trips.
                out += "\(Int64(d)).0"
            } else {
                // Shortest round-trip representation. Swift's Double
                // description and Rust's f64 Display both use
                // shortest-repr algorithms; documented as best-effort
                // for unknown-key floats (ledger fields never hit this).
                out += "\(d)"
            }
        case .string(let s):
            Self.writeEscaped(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let pairs):
            let sorted = pairs.sorted { $0.key.utf8Lexicographic($1.key) }
            out += "{"
            for (i, pair) in sorted.enumerated() {
                if i > 0 { out += "," }
                Self.writeEscaped(pair.key, into: &out)
                out += ":"
                pair.value.write(into: &out)
            }
            out += "}"
        }
    }

    /// serde_json-compatible string escaping: `\"`, `\\`, `\b`, `\f`,
    /// `\n`, `\r`, `\t`, `\u00xx` (lowercase hex) for other control
    /// characters; all other scalars raw.
    private static func writeEscaped(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20:
                out += String(format: "\\u%04x", c.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

// MARK: - Byte-order string comparison

extension String {
    /// UTF-8 byte-lexicographic strict less-than — matches Rust
    /// `String::cmp` and SQLite BINARY collation. Swift's `<` compares
    /// after Unicode normalization and MUST NOT be used for canonical
    /// key ordering (same rule as PredicateEvaluator's text compare).
    func utf8Lexicographic(_ other: String) -> Bool {
        var a = self.utf8.makeIterator()
        var b = other.utf8.makeIterator()
        while true {
            switch (a.next(), b.next()) {
            case (nil, nil): return false
            case (nil, _): return true
            case (_, nil): return false
            case (let x?, let y?):
                if x != y { return x < y }
            }
        }
    }
}
