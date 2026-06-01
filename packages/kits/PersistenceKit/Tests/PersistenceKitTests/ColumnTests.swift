// ColumnTests.swift
//
// Part 2 coverage gap: PersistenceKitCoreTypeTests covered Column's Comparable
// ordering across two pairs, but Column equality/hashing and ColumnType's
// rawValue + Codable round-trip had no peer suite. ColumnType is the type that
// drives backend DDL, so its raw-string stability is worth pinning.

import Testing
import Foundation
import PersistenceKit

struct ColumnTests {

    @Test func equalityAndHashing() {
        let a = Column(table: "drawers", name: "adjective")
        let b = Column(table: "drawers", name: "adjective")
        let c = Column(table: "drawers", name: "operational")
        #expect(a == b)
        #expect(a != c)
        let set: Set<Column> = [a, b, c]
        #expect(set.count == 2)  // a and b collapse
    }

    @Test func comparableTieBreaksOnNameWithinTable() {
        let a = Column(table: "t", name: "a")
        let b = Column(table: "t", name: "b")
        #expect(a < b)
        #expect(!(b < a))
    }

    @Test func comparableOrdersByTableFirst() {
        // Table dominates name: ("z","a") sorts after ("a","z").
        let early = Column(table: "alpha", name: "zzz")
        let late = Column(table: "zeta", name: "aaa")
        #expect(early < late)
    }

    @Test func columnTypeRawValuesAreStable() {
        #expect(ColumnType.uuid.rawValue == "uuid")
        #expect(ColumnType.bitmap.rawValue == "bitmap")
        #expect(ColumnType.fingerprint.rawValue == "fingerprint")
        #expect(ColumnType(rawValue: "hlc") == .hlc)
        #expect(ColumnType(rawValue: "not-a-type") == nil)
    }

    @Test func columnTypeCodableRoundTrip() throws {
        let all: [ColumnType] = [.uuid, .bitmap, .text, .timestamp, .float, .int, .bool, .blob, .json, .hlc, .fingerprint]
        let data = try JSONEncoder().encode(all)
        let decoded = try JSONDecoder().decode([ColumnType].self, from: data)
        #expect(decoded == all)
    }
}
