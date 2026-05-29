// PersistenceKitCoreTypeTests.swift

import XCTest
import SubstrateTypes
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

final class PersistenceKitCoreTypeTests: XCTestCase {

    func testTypedValueEquality() {
        XCTAssertEqual(TypedValue.int(42), TypedValue.int(42))
        XCTAssertNotEqual(TypedValue.int(42), TypedValue.int(43))
        XCTAssertNotEqual(TypedValue.int(42), TypedValue.bitmap(42))  // distinct semantic types
        XCTAssertTrue(TypedValue.null.isNull)
        XCTAssertFalse(TypedValue.int(0).isNull)
    }

    func testColumnOrdering() {
        let a = Column(table: "drawers", name: "adjective")
        let b = Column(table: "drawers", name: "operational")
        let c = Column(table: "tunnels", name: "adjective")
        XCTAssertLessThan(a, b)
        XCTAssertLessThan(b, c)
    }

    func testPredicateAllAndAny() {
        let p1: StoragePredicate = .eq(Column(table: "t", name: "c"), .int(1))
        let p2: StoragePredicate = .eq(Column(table: "t", name: "c"), .int(2))

        // .all([single]) → single
        if case .eq = StoragePredicate.all([p1]) {} else { XCTFail("expected unwrapped") }

        // .all([]) → .isTrue
        if case .isTrue = StoragePredicate.all([]) {} else { XCTFail("expected isTrue") }

        // .any([]) → .isFalse
        if case .isFalse = StoragePredicate.any([]) {} else { XCTFail("expected isFalse") }

        // .all containing .isFalse → .isFalse
        if case .isFalse = StoragePredicate.all([p1, .isFalse]) {} else { XCTFail("expected isFalse") }

        // .any containing .isTrue → .isTrue
        if case .isTrue = StoragePredicate.any([p1, .isTrue]) {} else { XCTFail("expected isTrue") }

        // .all multi-non-trivial → .and
        if case .and(let xs) = StoragePredicate.all([p1, p2]) {
            XCTAssertEqual(xs.count, 2)
        } else {
            XCTFail("expected .and")
        }
    }

    func testSchemaDeclarationConstruction() {
        let schema = SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "drawers",
                    columns: [.uuid("row_id"), .bitmap("adjective"), .text("content")],
                    primaryKey: ["row_id"]
                )
            ]
        )
        XCTAssertEqual(schema.kitID, "TestKit")
        XCTAssertEqual(schema.tables.count, 1)
        XCTAssertEqual(schema.tables[0].columns.count, 3)
    }

    func testStorageErrorEquality() {
        XCTAssertEqual(
            StorageError.schemaMismatch(expected: 1, actual: 2),
            StorageError.schemaMismatch(expected: 1, actual: 2)
        )
        XCTAssertNotEqual(
            StorageError.schemaMismatch(expected: 1, actual: 2),
            StorageError.schemaMismatch(expected: 1, actual: 3)
        )
    }
}
