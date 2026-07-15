// InMemoryComparatorTests.swift
//
// Regression tests for finding #7: TypedValueComparator previously returned
// nil for .blob / .json / .fingerprint / .array, causing .eq to NEVER match,
// .neq to ALWAYS return true, and .in to NEVER match for those types in the
// InMemory backend.
//
// Tests exercise the public RowStore predicate API (insert + query/count with
// .eq, .neq, .in) so behaviour is verified end-to-end through the evaluator,
// not through the internal comparator directly.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitInMemory
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

struct InMemoryComparatorTests {

    // MARK: - Schema helpers

    /// A flexible single-table schema whose columns cover every
    /// TypedValue case not previously handled by TypedValueComparator:
    /// blob, json, fingerprint, and a blob column repurposed for array
    /// values (ColumnType has no .array variant; InMemory stores any
    /// TypedValue regardless of declared column type).
    func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "ComparatorTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("id"),
                        .blob("blob_col"),
                        .json("json_col"),
                        .fingerprint("fp_col"),
                        // No .array ColumnType; InMemory doesn't validate
                        // TypedValue against the declared column type, so
                        // we declare this as blob and store arrays.
                        .blob("arr_col", nullable: true)
                    ],
                    primaryKey: ["id"]
                )
            ]
        )
    }

    func makeStorage() async throws -> InMemoryStorage {
        let s = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await s.open(schema: makeSchema())
        return s
    }

    private func col(_ name: String) -> Column {
        Column(table: "items", name: name)
    }

    // MARK: - blob

    @Test func blobEqMatchesIdenticalBytes() async throws {
        let s = try await makeStorage()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let other   = Data([0x00, 0x01, 0x02, 0x03])
        let id1 = UUID(); let id2 = UUID()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(id1), "blob_col": .blob(payload)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(id2), "blob_col": .blob(other)])

        // .eq must match only the identical bytes
        let eq = try await s.rowStore.query(
            table: "items", where: .eq(col("blob_col"), .blob(payload)))
        #expect(eq.count == 1, "blob .eq must match the row with identical bytes")
        #expect(eq[0]["id"] == .uuid(id1))
    }

    @Test func blobNeqFalseForEqualBytes() async throws {
        let s = try await makeStorage()
        let payload = Data([0x01, 0x02, 0x03])
        let id = UUID()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(id), "blob_col": .blob(payload)])

        // .neq with the SAME value must return 0 matching rows
        let neq = try await s.rowStore.count(
            table: "items", where: .neq(col("blob_col"), .blob(payload)))
        #expect(neq == 0, "blob .neq against identical bytes must not match")
    }

    @Test func blobNeqTrueForDifferentBytes() async throws {
        let s = try await makeStorage()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "blob_col": .blob(Data([0xAA]))])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "blob_col": .blob(Data([0xBB]))])

        let neq = try await s.rowStore.count(
            table: "items", where: .neq(col("blob_col"), .blob(Data([0xAA]))))
        #expect(neq == 1, "blob .neq must match rows with different bytes")
    }

    @Test func blobInMatchesMembership() async throws {
        let s = try await makeStorage()
        let a = Data([0x01]); let b = Data([0x02]); let c = Data([0x03])
        let idA = UUID(); let idB = UUID(); let idC = UUID()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idA), "blob_col": .blob(a)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idB), "blob_col": .blob(b)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idC), "blob_col": .blob(c)])

        let inResult = try await s.rowStore.query(
            table: "items",
            where: .in(col("blob_col"), [.blob(a), .blob(c)]))
        #expect(inResult.count == 2, "blob .in must match rows whose value is in the set")
        let returnedIDs = Set(inResult.compactMap { $0["id"] })
        #expect(returnedIDs.contains(.uuid(idA)))
        #expect(returnedIDs.contains(.uuid(idC)))
        #expect(!returnedIDs.contains(.uuid(idB)))
    }

    // MARK: - json

    @Test func jsonEqMatchesIdenticalBytes() async throws {
        let s = try await makeStorage()
        let payload = Data(#"{"key":"value"}"#.utf8)
        let other   = Data(#"{"key":"other"}"#.utf8)
        let id1 = UUID(); let id2 = UUID()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(id1), "json_col": .json(payload)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(id2), "json_col": .json(other)])

        let eq = try await s.rowStore.query(
            table: "items", where: .eq(col("json_col"), .json(payload)))
        #expect(eq.count == 1, "json .eq must match the row with identical bytes")
        #expect(eq[0]["id"] == .uuid(id1))
    }

    @Test func jsonNeqFalseForEqualBytes() async throws {
        let s = try await makeStorage()
        let payload = Data(#"{"x":1}"#.utf8)
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "json_col": .json(payload)])

        let neq = try await s.rowStore.count(
            table: "items", where: .neq(col("json_col"), .json(payload)))
        #expect(neq == 0, "json .neq against identical bytes must not match")
    }

    @Test func jsonNeqTrueForDifferentBytes() async throws {
        let s = try await makeStorage()
        let p1 = Data(#"{"v":1}"#.utf8)
        let p2 = Data(#"{"v":2}"#.utf8)
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "json_col": .json(p1)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "json_col": .json(p2)])

        let neq = try await s.rowStore.count(
            table: "items", where: .neq(col("json_col"), .json(p1)))
        #expect(neq == 1, "json .neq must match rows with different bytes")
    }

    @Test func jsonInMatchesMembership() async throws {
        let s = try await makeStorage()
        let a = Data(#"{"n":1}"#.utf8)
        let b = Data(#"{"n":2}"#.utf8)
        let c = Data(#"{"n":3}"#.utf8)
        let idA = UUID(); let idB = UUID(); let idC = UUID()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idA), "json_col": .json(a)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idB), "json_col": .json(b)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idC), "json_col": .json(c)])

        let inResult = try await s.rowStore.query(
            table: "items",
            where: .in(col("json_col"), [.json(a), .json(b)]))
        #expect(inResult.count == 2, "json .in must match rows whose value is in the set")
        let ids = Set(inResult.compactMap { $0["id"] })
        #expect(ids.contains(.uuid(idA)))
        #expect(ids.contains(.uuid(idB)))
        #expect(!ids.contains(.uuid(idC)))
    }

    // MARK: - fingerprint

    @Test func fingerprintEqMatchesIdenticalValue() async throws {
        let s = try await makeStorage()
        let fp1 = Fingerprint256(block0: 0xAAAA, block1: 0xBBBB, block2: 0xCCCC, block3: 0xDDDD)
        let fp2 = Fingerprint256(block0: 0x1111, block1: 0x2222, block2: 0x3333, block3: 0x4444)
        let id1 = UUID(); let id2 = UUID()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(id1), "fp_col": .fingerprint(fp1)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(id2), "fp_col": .fingerprint(fp2)])

        let eq = try await s.rowStore.query(
            table: "items", where: .eq(col("fp_col"), .fingerprint(fp1)))
        #expect(eq.count == 1, "fingerprint .eq must match the row with identical blocks")
        #expect(eq[0]["id"] == .uuid(id1))
    }

    @Test func fingerprintNeqFalseForEqualValue() async throws {
        let s = try await makeStorage()
        let fp = Fingerprint256(block0: 10, block1: 20, block2: 30, block3: 40)
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "fp_col": .fingerprint(fp)])

        let neq = try await s.rowStore.count(
            table: "items", where: .neq(col("fp_col"), .fingerprint(fp)))
        #expect(neq == 0, "fingerprint .neq against identical value must not match")
    }

    @Test func fingerprintNeqTrueForDifferentValue() async throws {
        let s = try await makeStorage()
        let fpA = Fingerprint256(block0: 1, block1: 0, block2: 0, block3: 0)
        let fpB = Fingerprint256(block0: 2, block1: 0, block2: 0, block3: 0)
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "fp_col": .fingerprint(fpA)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "fp_col": .fingerprint(fpB)])

        let neq = try await s.rowStore.count(
            table: "items", where: .neq(col("fp_col"), .fingerprint(fpA)))
        #expect(neq == 1, "fingerprint .neq must match rows with different block values")
    }

    @Test func fingerprintInMatchesMembership() async throws {
        let s = try await makeStorage()
        let fpA = Fingerprint256(block0: 100, block1: 0, block2: 0, block3: 0)
        let fpB = Fingerprint256(block0: 200, block1: 0, block2: 0, block3: 0)
        let fpC = Fingerprint256(block0: 300, block1: 0, block2: 0, block3: 0)
        let idA = UUID(); let idB = UUID(); let idC = UUID()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idA), "fp_col": .fingerprint(fpA)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idB), "fp_col": .fingerprint(fpB)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idC), "fp_col": .fingerprint(fpC)])

        let inResult = try await s.rowStore.query(
            table: "items",
            where: .in(col("fp_col"), [.fingerprint(fpA), .fingerprint(fpC)]))
        #expect(inResult.count == 2, "fingerprint .in must match rows whose value is in the set")
        let ids = Set(inResult.compactMap { $0["id"] })
        #expect(ids.contains(.uuid(idA)))
        #expect(ids.contains(.uuid(idC)))
        #expect(!ids.contains(.uuid(idB)))
    }

    // MARK: - array

    @Test func arrayEqMatchesIdenticalElements() async throws {
        let s = try await makeStorage()
        // InMemory does not validate TypedValue against declared ColumnType;
        // storing .array in a .blob column works correctly.
        let arrA: TypedValue = .array([.int(1), .text("hello")])
        let arrB: TypedValue = .array([.int(2), .text("world")])
        let id1 = UUID(); let id2 = UUID()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(id1), "arr_col": arrA])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(id2), "arr_col": arrB])

        let eq = try await s.rowStore.query(
            table: "items", where: .eq(col("arr_col"), arrA))
        #expect(eq.count == 1, "array .eq must match the row with identical elements")
        #expect(eq[0]["id"] == .uuid(id1))
    }

    @Test func arrayNeqFalseForEqualElements() async throws {
        let s = try await makeStorage()
        let arr: TypedValue = .array([.int(42), .bool(true)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "arr_col": arr])

        let neq = try await s.rowStore.count(
            table: "items", where: .neq(col("arr_col"), arr))
        #expect(neq == 0, "array .neq against identical value must not match")
    }

    @Test func arrayNeqTrueForDifferentElements() async throws {
        let s = try await makeStorage()
        let arr1: TypedValue = .array([.int(1)])
        let arr2: TypedValue = .array([.int(2)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "arr_col": arr1])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "arr_col": arr2])

        let neq = try await s.rowStore.count(
            table: "items", where: .neq(col("arr_col"), arr1))
        #expect(neq == 1, "array .neq must match rows with different elements")
    }

    @Test func arrayInMatchesMembership() async throws {
        let s = try await makeStorage()
        let arrA: TypedValue = .array([.int(10)])
        let arrB: TypedValue = .array([.int(20)])
        let arrC: TypedValue = .array([.int(30)])
        let idA = UUID(); let idB = UUID(); let idC = UUID()
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idA), "arr_col": arrA])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idB), "arr_col": arrB])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(idC), "arr_col": arrC])

        let inResult = try await s.rowStore.query(
            table: "items",
            where: .in(col("arr_col"), [arrA, arrC]))
        #expect(inResult.count == 2, "array .in must match rows whose value is in the set")
        let ids = Set(inResult.compactMap { $0["id"] })
        #expect(ids.contains(.uuid(idA)))
        #expect(ids.contains(.uuid(idC)))
        #expect(!ids.contains(.uuid(idB)))
    }

    /// Arrays of different lengths that share a common prefix must compare
    /// correctly (shorter < longer when prefix elements are equal).
    @Test func arrayNeqDifferentLengths() async throws {
        let s = try await makeStorage()
        let short: TypedValue = .array([.int(1)])
        let long:  TypedValue = .array([.int(1), .int(2)])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "arr_col": short])
        _ = try await s.rowStore.insert(table: "items",
            values: ["id": .uuid(UUID()), "arr_col": long])

        // Neither matches the other via .eq
        let eqShort = try await s.rowStore.count(
            table: "items", where: .eq(col("arr_col"), short))
        let eqLong = try await s.rowStore.count(
            table: "items", where: .eq(col("arr_col"), long))
        #expect(eqShort == 1, "shorter array must only match itself")
        #expect(eqLong  == 1, "longer array must only match itself")
    }
}
