// StableKeyTests.swift
//
// The stable-keying scheme is what makes MDCC canons safe to adopt.
// A concept's code in v1 stays its code in v1.x. These tests pin the
// next-free-slot computation and the registry round-trip.

import Testing
@testable import LatticeLib

@Suite("Stable key registry")
struct StableKeyTests {

    @Test("empty registry returns NN00 as the first free code")
    func firstFreeIsBase() {
        let reg = StableKeyRegistry(entries: [])
        let science = NotationSpine.owningClass(forBase: 500)!
        #expect(reg.nextFreeCode(in: science) == "500")
    }

    @Test("registry skips occupied codes")
    func skipsOccupied() {
        let reg = StableKeyRegistry(entries: [
            StableKeyEntry(sourceIdentity: "Q1", code: "500", firstAssignedInCanon: "v1"),
            StableKeyEntry(sourceIdentity: "Q2", code: "501", firstAssignedInCanon: "v1"),
        ])
        let science = NotationSpine.owningClass(forBase: 500)!
        #expect(reg.nextFreeCode(in: science) == "502")
    }

    @Test("registry never returns a code inside the reserved range")
    func skipsReserved() {
        // Fill NN00 through NN79; with the flat band full the allocator
        // descends into the decimal-extension space rather than handing
        // out a reserved code. The next free must be the first extension
        // slot (500.0), never the reserved 580, and never nil.
        var entries: [StableKeyEntry] = []
        for offset in 0..<80 {
            let code = String(format: "%03d", 500 + offset)
            entries.append(StableKeyEntry(
                sourceIdentity: "Q\(offset)",
                code: code,
                firstAssignedInCanon: "v1"
            ))
        }
        let reg = StableKeyRegistry(entries: entries)
        let science = NotationSpine.owningClass(forBase: 500)!
        let next = reg.nextFreeCode(in: science)
        #expect(next == "500.0")
        #expect(next.map { !ReservedRanges.isReserved($0) } == true)
    }

    @Test("registry pins a source identity to its assigned code")
    func pinning() {
        let reg = StableKeyRegistry(entries: [
            StableKeyEntry(sourceIdentity: "Q42", code: "501", firstAssignedInCanon: "v1"),
        ])
        #expect(reg.code(for: "Q42") == "501")
        #expect(reg.code(for: "Q999") == nil)
    }
}
