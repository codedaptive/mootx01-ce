// InventorySnapshot.swift
//
// Narrow, immutable inventory capture for the LocusKit drawers and nodes
// tables. The snapshot is deliberately a storage primitive: authorization,
// strict domain decoding, and state identity belong to its callers.

import Foundation

public struct InventorySnapshotLimits: Sendable, Equatable {
    public static let production = InventorySnapshotLimits(
        maxRowsPerTable: 250_000,
        maxSerializedBytes: 128 * 1024 * 1024
    )

    public let maxRowsPerTable: Int
    public let maxSerializedBytes: Int

    public init(maxRowsPerTable: Int, maxSerializedBytes: Int) {
        precondition(maxRowsPerTable > 0 && maxRowsPerTable <= Self.productionRowLimit)
        precondition(maxSerializedBytes > 0 && maxSerializedBytes <= Self.productionByteLimit)
        self.maxRowsPerTable = maxRowsPerTable
        self.maxSerializedBytes = maxSerializedBytes
    }

    private static let productionRowLimit = 250_000
    private static let productionByteLimit = 128 * 1024 * 1024
}

public struct InventorySnapshot: Sendable {
    public let drawers: [StorageRow]
    public let nodes: [StorageRow]

    public init(drawers: [StorageRow], nodes: [StorageRow]) {
        self.drawers = drawers
        self.nodes = nodes
    }
}

public enum InventorySnapshotError: Error, Sendable, Equatable {
    case rowLimitExceeded(table: String, limit: Int)
    case byteLimitExceeded(limit: Int)
}

public extension InventorySnapshot {
    static let drawersTable = "drawers"
    static let nodesTable = "nodes"

    /// Count the canonical representation without constructing it. This must
    /// stay byte-identical to `DatabaseInventory.canonicalRowEncoding(_:)`:
    /// snapshot custody is permitted to retain a row only after this exact
    /// budget has been reserved.
    static func serializedByteCount(of row: StorageRow) -> Int {
        var total = 0
        // Column order changes the canonical bytes but not their length, so
        // avoid allocating a sorted dictionary view merely to count them.
        for (index, entry) in row.values.enumerated() {
            if index != 0 { total = saturatingAdd(total, 1) }
            total = saturatingAdd(total, entry.key.utf8.count)
            total = saturatingAdd(total, 1) // equals sign
            total = saturatingAdd(total, serializedByteCount(of: entry.value))
        }
        return total
    }

    private static func serializedByteCount(of value: TypedValue) -> Int {
        switch value {
        case .null: return 1
        case .bool: return 3
        case .int(let value), .bitmap(let value): return 2 + signedDecimalLength(value)
        case .float: return 18
        case .text(let value): return 3 + decimalLength(value.utf8.count) + value.utf8.count
        case .blob(let value): return saturatingAdd(3 + decimalLength(value.count), saturatingMultiply(value.count, 2))
        case .uuid: return 38
        case .timestamp(let value):
            return 2 + signedDecimalLength(Int64((value.timeIntervalSince1970 * 1000).rounded()))
        case .json(let value):
            let payloadLength = isValidUTF8(value) ? value.count : saturatingMultiply(value.count, 2)
            return saturatingAdd(3 + decimalLength(value.count), payloadLength)
        case .hlc(let value): return 2 + decimalLength(value.packed)
        case .fingerprint: return 66
        case .array(let values):
            var total = 4 // a:[ plus closing ]
            for (index, value) in values.enumerated() {
                if index != 0 { total = saturatingAdd(total, 1) }
                total = saturatingAdd(total, serializedByteCount(of: value))
            }
            return total
        }
    }

    private static func signedDecimalLength(_ value: Int64) -> Int {
        (value < 0 ? 1 : 0) + decimalLength(value.magnitude)
    }

    private static func decimalLength<T: BinaryInteger>(_ value: T) -> Int {
        var value = value.magnitude
        var length = 1
        while value >= 10 {
            value /= 10
            length += 1
        }
        return length
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    /// `String(data:encoding:)` would create the complete JSON text merely to
    /// learn whether canonical encoding uses text or hexadecimal. Validate the
    /// UTF-8 scalar sequence directly over Data's borrowed bytes instead.
    private static func isValidUTF8(_ data: Data) -> Bool {
        var index = data.startIndex
        func continuation(_ index: Data.Index) -> Bool {
            index < data.endIndex && (data[index] & 0xC0) == 0x80
        }
        while index < data.endIndex {
            let byte = data[index]
            index += 1
            switch byte {
            case 0x00...0x7F:
                continue
            case 0xC2...0xDF:
                guard continuation(index) else { return false }
                index += 1
            case 0xE0:
                guard index < data.endIndex, data[index] >= 0xA0, data[index] <= 0xBF,
                      continuation(index + 1) else { return false }
                index += 2
            case 0xE1...0xEC, 0xEE...0xEF:
                guard continuation(index), continuation(index + 1) else { return false }
                index += 2
            case 0xED:
                guard index < data.endIndex, data[index] >= 0x80, data[index] <= 0x9F,
                      continuation(index + 1) else { return false }
                index += 2
            case 0xF0:
                guard index < data.endIndex, data[index] >= 0x90, data[index] <= 0xBF,
                      continuation(index + 1), continuation(index + 2) else { return false }
                index += 3
            case 0xF1...0xF3:
                guard continuation(index), continuation(index + 1), continuation(index + 2) else { return false }
                index += 3
            case 0xF4:
                guard index < data.endIndex, data[index] >= 0x80, data[index] <= 0x8F,
                      continuation(index + 1), continuation(index + 2) else { return false }
                index += 3
            default:
                return false
            }
        }
        return true
    }
}
