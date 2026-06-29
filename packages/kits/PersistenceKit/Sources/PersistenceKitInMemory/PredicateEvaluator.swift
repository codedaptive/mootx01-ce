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
            return (row[col.name] ?? .null) == v
        case .neq(let col, let v):
            return (row[col.name] ?? .null) != v
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
            return values.contains(v)
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
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.timestamp(let x), .timestamp(let y)):
            return x == y ? 0 : (x < y ? -1 : 1)
        case (.uuid(let x), .uuid(let y)):
            return x.uuidString == y.uuidString ? 0 : (x.uuidString < y.uuidString ? -1 : 1)
        case (.hlc(let x), .hlc(let y)):
            // HLC.packed provides a total order over (physicalTime, logicalCount, nodeID).
            let xp = x.packed
            let yp = y.packed
            return xp == yp ? 0 : (xp < yp ? -1 : 1)
        default:
            return nil
        }
    }
}
