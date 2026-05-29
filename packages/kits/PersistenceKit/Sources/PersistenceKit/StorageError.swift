// StorageError.swift

import Foundation

public enum StorageError: Error, Sendable, Equatable {
    case backendUnavailable(reason: String)
    case schemaMismatch(expected: Int, actual: Int)
    case migrationFailed(version: Int, reason: String)
    case constraintViolation(detail: String)
    case poolExhausted(timeout: TimeInterval)
    case transactionConflict(detail: String)
    case typeMismatch(column: String, expected: ColumnType, actual: String)
    case rowNotFound(table: String, key: String)
    case duplicateKey(table: String, key: String)
    case invalidQuery(detail: String)
    case appendOnlyViolation(table: String)
    case backendError(underlying: String)
}
