// PersistenceKitCoreTypeTests.swift

import Testing
import SubstrateTypes
import PersistenceKit
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

struct PersistenceKitCoreTypeTests {

    @Test func typedValueEquality() {
        #expect(TypedValue.int(42) == TypedValue.int(42))
        #expect(TypedValue.int(42) != TypedValue.int(43))
        #expect(TypedValue.int(42) != TypedValue.bitmap(42))  // distinct semantic types
        #expect(TypedValue.null.isNull)
        #expect(!TypedValue.int(0).isNull)
    }

    @Test func columnOrdering() {
        let a = Column(table: "drawers", name: "adjective")
        let b = Column(table: "drawers", name: "operational")
        let c = Column(table: "tunnels", name: "adjective")
        #expect(a < b)
        #expect(b < c)
    }

    @Test func predicateAllAndAny() {
        let p1: StoragePredicate = .eq(Column(table: "t", name: "c"), .int(1))
        let p2: StoragePredicate = .eq(Column(table: "t", name: "c"), .int(2))

        // .all([single]) → single
        if case .eq = StoragePredicate.all([p1]) {} else { Issue.record("expected unwrapped") }

        // .all([]) → .isTrue
        if case .isTrue = StoragePredicate.all([]) {} else { Issue.record("expected isTrue") }

        // .any([]) → .isFalse
        if case .isFalse = StoragePredicate.any([]) {} else { Issue.record("expected isFalse") }

        // .all containing .isFalse → .isFalse
        if case .isFalse = StoragePredicate.all([p1, .isFalse]) {} else { Issue.record("expected isFalse") }

        // .any containing .isTrue → .isTrue
        if case .isTrue = StoragePredicate.any([p1, .isTrue]) {} else { Issue.record("expected isTrue") }

        // .all multi-non-trivial → .and
        if case .and(let xs) = StoragePredicate.all([p1, p2]) {
            #expect(xs.count == 2)
        } else {
            Issue.record("expected .and")
        }
    }

    @Test func schemaDeclarationConstruction() {
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
        #expect(schema.kitID == "TestKit")
        #expect(schema.tables.count == 1)
        #expect(schema.tables[0].columns.count == 3)
    }

    @Test func storageErrorEquality() {
        #expect(
            StorageError.schemaMismatch(expected: 1, actual: 2)
                == StorageError.schemaMismatch(expected: 1, actual: 2)
        )
        #expect(
            StorageError.schemaMismatch(expected: 1, actual: 2)
                != StorageError.schemaMismatch(expected: 1, actual: 3)
        )
    }
}
