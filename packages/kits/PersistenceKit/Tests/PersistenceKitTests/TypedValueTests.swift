// TypedValueTests.swift
//
// Part 2 coverage gap: TypedValue's equality across two cases was touched in
// PersistenceKitCoreTypeTests, but typeDescription (the 13-case switch), the
// full isNull behavior, array/blob value semantics, and Hashable conformance
// had no peer suite. These tests pin the closed case set directly.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit

struct TypedValueTests {

    @Test func typeDescriptionCoversEveryCase() {
        #expect(TypedValue.null.typeDescription == "null")
        #expect(TypedValue.bool(true).typeDescription == "bool")
        #expect(TypedValue.int(1).typeDescription == "int")
        #expect(TypedValue.bitmap(1).typeDescription == "bitmap")
        #expect(TypedValue.float(1.0).typeDescription == "float")
        #expect(TypedValue.text("x").typeDescription == "text")
        #expect(TypedValue.blob(Data()).typeDescription == "blob")
        #expect(TypedValue.uuid(UUID()).typeDescription == "uuid")
        #expect(TypedValue.timestamp(Date()).typeDescription == "timestamp")
        #expect(TypedValue.json(Data()).typeDescription == "json")
        #expect(TypedValue.hlc(HLC(physicalTime: 1, logicalCount: 0, nodeID: 1)).typeDescription == "hlc")
        #expect(TypedValue.fingerprint(.zero).typeDescription == "fingerprint")
        #expect(TypedValue.array([]).typeDescription == "array")
    }

    @Test func isNullOnlyForNull() {
        #expect(TypedValue.null.isNull)
        #expect(!TypedValue.int(0).isNull)
        #expect(!TypedValue.bool(false).isNull)
        #expect(!TypedValue.text("").isNull)
        #expect(!TypedValue.array([]).isNull)
    }

    @Test func equalityIsCaseSensitive() {
        // bitmap is semantically distinct from int even at the same Int64.
        #expect(TypedValue.int(42) != TypedValue.bitmap(42))
        #expect(TypedValue.text("a") != TypedValue.text("b"))
        #expect(TypedValue.blob(Data([1, 2])) == TypedValue.blob(Data([1, 2])))
        #expect(TypedValue.blob(Data([1, 2])) != TypedValue.blob(Data([1, 3])))
    }

    @Test func arrayEqualityIsStructural() {
        #expect(TypedValue.array([.int(1), .text("x")]) == TypedValue.array([.int(1), .text("x")]))
        #expect(TypedValue.array([.int(1)]) != TypedValue.array([.int(2)]))
        #expect(TypedValue.array([.int(1)]) != TypedValue.array([.int(1), .int(1)]))
    }

    @Test func hashableDistinguishesCases() {
        // int(1) and bitmap(1) are distinct keys; duplicate ints collapse.
        let set: Set<TypedValue> = [.int(1), .int(1), .bitmap(1), .null]
        #expect(set.count == 3)
        #expect(set.contains(.bitmap(1)))
        #expect(!set.contains(.int(2)))
    }
}
