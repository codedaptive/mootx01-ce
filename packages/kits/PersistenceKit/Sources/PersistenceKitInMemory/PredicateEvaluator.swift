// PredicateEvaluator.swift

import Foundation
import PersistenceKit

enum PredicateEvaluator {
    static func evaluate(_ predicate: StoragePredicate, against row: [String: TypedValue]) -> Bool {
        switch predicate {
        case .and(let preds): return preds.allSatisfy { evaluate($0, against: row) }
        case .or(let preds): return preds.contains { evaluate($0, against: row) }
        case .not(let p): return !evaluate(p, against: row)
        case .isTrue: return true
        case .isFalse: return false
        case .eq(let col, let v):
            // UTF-8 byte equality via TypedValueComparator — matches SQLite BINARY collation
            // and the Rust leg's String::eq (byte-exact). Do NOT use TypedValue == (Swift
            // String == applies Unicode canonical normalisation, so precomposed "É" U+00C9
            // and decomposed "E\u{0301}" compare equal even though their byte sequences
            // differ). ?? 1: incompatible types return nil → treat as not-equal, consistent
            // with the prior TypedValue == behaviour for mismatched cases.
            // MX-TAB-Q1 resolution (2026-07-12): equality paths now share the same
            // byte-exact comparator as the ordering paths (lt/lte/gt/gte).
            return (TypedValueComparator.compare(row[col.name] ?? .null, v) ?? 1) == 0
        case .neq(let col, let v):
            return (TypedValueComparator.compare(row[col.name] ?? .null, v) ?? 1) != 0
        case .lt(let col, let v):
            return (TypedValueComparator.compare(row[col.name] ?? .null, v) ?? 1) < 0
        case .lte(let col, let v):
            return (TypedValueComparator.compare(row[col.name] ?? .null, v) ?? 1) <= 0
        case .gt(let col, let v):
            return (TypedValueComparator.compare(row[col.name] ?? .null, v) ?? -1) > 0
        case .gte(let col, let v):
            return (TypedValueComparator.compare(row[col.name] ?? .null, v) ?? -1) >= 0
        case .isNull(let col):
            return (row[col.name] ?? .null).isNull
        case .isNotNull(let col):
            return !(row[col.name] ?? .null).isNull
        case .in(let col, let values):
            let v = row[col.name] ?? .null
            // Closure form routes TEXT membership through byte-exact comparison
            // (same rationale as .eq above — Swift contains(_:) uses ==, which
            // is Unicode-canonical for String and would silently accept NFD/NFC
            // variants as equal when BINARY collation requires byte identity).
            return values.contains { TypedValueComparator.compare(v, $0) == 0 }
        case .like(let col, let pattern):
            guard case .text(let s) = row[col.name] ?? .null else { return false }
            return likeMatch(s, pattern: pattern)
        case .bitmaskAll(let col, let mask):
            guard let cv = intValue(row[col.name]) else { return false }
            return (cv & mask) == mask
        case .bitmaskAny(let col, let mask):
            guard let cv = intValue(row[col.name]) else { return false }
            return (cv & mask) != 0
        case .bitmaskNone(let col, let mask):
            guard let cv = intValue(row[col.name]) else { return false }
            return (cv & mask) == 0
        case .bitwiseEq(let col, let expected, let mask):
            guard let cv = intValue(row[col.name]) else { return false }
            return (cv & mask) == expected
        }
    }

    private static func intValue(_ v: TypedValue?) -> Int64? {
        guard let v else { return nil }
        switch v {
        case .int(let i): return i
        case .bitmap(let i): return i
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    private static func likeMatch(_ string: String, pattern: String) -> Bool {
        // Convert SQL LIKE pattern to regex: % → .*, _ → .
        var regex = "^"
        for ch in pattern {
            switch ch {
            case "%": regex += ".*"
            case "_": regex += "."
            default:
                let s = String(ch)
                regex += NSRegularExpression.escapedPattern(for: s)
            }
        }
        regex += "$"
        guard let re = try? NSRegularExpression(pattern: regex) else { return false }
        let range = NSRange(string.startIndex..., in: string)
        return re.firstMatch(in: string, range: range) != nil
    }
}

enum TypedValueComparator {
    static func compare(_ a: TypedValue, _ b: TypedValue) -> Int? {
        switch (a, b) {
        case (.null, .null): return 0
        case (.null, _): return -1
        case (_, .null): return 1
        case (.bool(let x), .bool(let y)):
            return (x ? 1 : 0) - (y ? 1 : 0)
        case (.int(let x), .int(let y)):
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.bitmap(let x), .bitmap(let y)):
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.float(let x), .float(let y)):
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.text(let x), .text(let y)):
            // UTF-8 byte order — matching SQLite BINARY collation and the Rust leg's
            // `String::cmp` (byte-lexicographic). Do NOT use Swift String `<` or `==`:
            // Swift compares after Unicode canonical normalization, so two byte-inequal
            // strings (e.g. precomposed "é" vs decomposed "e\u{0301}") may compare
            // equal or in different order than their bytes. The byte-equality check
            // preserves strict three-way semantics: 0 only when bytes are identical,
            // not merely when strings are canonically equivalent.
            // Collation locked to byte order for cross-backend/cross-leg parity
            // (MX-TAB-Q1 — resolved 2026-07-12).
            if x.utf8.elementsEqual(y.utf8) { return 0 }
            return x.utf8.lexicographicallyPrecedes(y.utf8) ? -1 : 1
        case (.timestamp(let x), .timestamp(let y)):
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.uuid(let x), .uuid(let y)):
            return x.uuidString == y.uuidString ? 0 : (x.uuidString < y.uuidString ? -1 : 1)
        case (.hlc(let x), .hlc(let y)):
            // HLC order is (physicalTime, logicalCount, nodeID) — compare via
            // the HLC Comparable. The packed integer does NOT preserve this
            // order (its layout puts node and logical above physical —
            // HLC_PACKED_ORDER_UNSOUND), so packed comparison is wrong here.
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.blob(let x), .blob(let y)):
            // Byte-wise lexicographic compare — mirrors Rust Vec<u8> Ord and SQLite
            // BLOB affinity ordering. Used by .eq/.neq/.in (equality contract) and
            // .lt/.lte/.gt/.gte (ordering predicates) on blob columns.
            if x == y { return 0 }
            return x.lexicographicallyPrecedes(y) ? -1 : 1
        case (.json(let x), .json(let y)):
            // json is pre-encoded bytes; compare byte-wise, same as blob.
            // The kit invariant is that json values are stored as the caller-supplied
            // bytes — equality means identical bytes, NOT JSON semantic equivalence.
            // Mirrors Rust Vec<u8> Ord for the same reason.
            if x == y { return 0 }
            return x.lexicographicallyPrecedes(y) ? -1 : 1
        case (.fingerprint(let x), .fingerprint(let y)):
            // Block-wise compare in declaration order (block0 … block3 = bits 0–255).
            // Little-endian wire format: block0 carries bits 0–63. Comparing block0
            // first produces a lexicographic order over the 32-byte representation
            // that matches byte-array comparison of the wire format, and mirrors the
            // Rust leg's block-by-block Ordering::then chain.
            let xWords = [x.block0, x.block1, x.block2, x.block3]
            let yWords = [y.block0, y.block1, y.block2, y.block3]
            for (bx, by) in zip(xWords, yWords) {
                if bx != by { return bx < by ? -1 : 1 }
            }
            return 0
        case (.array(let xs), .array(let ys)):
            // Element-wise recursive compare; length is the tiebreak (shorter < longer
            // when all shared elements are equal). Returns nil if any element pair is
            // incomparable (mismatched TypedValue cases), propagating nil upward
            // consistent with the mismatched-type contract of the overall comparator.
            for (xe, ye) in zip(xs, ys) {
                guard let cmp = TypedValueComparator.compare(xe, ye) else { return nil }
                if cmp != 0 { return cmp }
            }
            return xs.count == ys.count ? 0 : (xs.count < ys.count ? -1 : 1)
        default:
            return nil
        }
    }
}
