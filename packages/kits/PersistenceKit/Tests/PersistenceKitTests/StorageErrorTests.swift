// StorageErrorTests.swift
//
// Part 2 coverage gap: PersistenceKitCoreTypeTests asserted Equatable only on
// the schemaMismatch case. StorageError's Equatable conformance carries payloads
// of several shapes (Int, String, TimeInterval, ColumnType), and the encryption
// invariant tests rely on .constraintViolation matching. This suite pins
// per-case equality, payload sensitivity, and cross-case inequality.

import Testing
import Foundation
import PersistenceKit

struct StorageErrorTests {

    @Test func samePayloadEquals() {
        #expect(StorageError.backendUnavailable(reason: "x") == .backendUnavailable(reason: "x"))
        #expect(StorageError.migrationFailed(version: 2, reason: "boom") == .migrationFailed(version: 2, reason: "boom"))
        #expect(StorageError.constraintViolation(detail: "c") == .constraintViolation(detail: "c"))
        #expect(StorageError.poolExhausted(timeout: 5.0) == .poolExhausted(timeout: 5.0))
        #expect(StorageError.typeMismatch(column: "c", expected: .int, actual: "text")
                == .typeMismatch(column: "c", expected: .int, actual: "text"))
        #expect(StorageError.rowNotFound(table: "t", key: "k") == .rowNotFound(table: "t", key: "k"))
        #expect(StorageError.appendOnlyViolation(table: "ledger") == .appendOnlyViolation(table: "ledger"))
        #expect(StorageError.backendError(underlying: "e") == .backendError(underlying: "e"))
    }

    @Test func differingPayloadDiffers() {
        #expect(StorageError.backendUnavailable(reason: "x") != .backendUnavailable(reason: "y"))
        #expect(StorageError.poolExhausted(timeout: 5.0) != .poolExhausted(timeout: 30.0))
        #expect(StorageError.appendOnlyViolation(table: "a") != .appendOnlyViolation(table: "b"))
        // The expected ColumnType participates in equality.
        #expect(StorageError.typeMismatch(column: "c", expected: .int, actual: "text")
                != .typeMismatch(column: "c", expected: .bool, actual: "text"))
    }

    @Test func differentCasesDiffer() {
        #expect(StorageError.schemaMismatch(expected: 1, actual: 2) != .backendError(underlying: "x"))
        #expect(StorageError.constraintViolation(detail: "d") != .invalidQuery(detail: "d"))
        #expect(StorageError.transactionConflict(detail: "t") != .duplicateKey(table: "t", key: "t"))
    }
}
