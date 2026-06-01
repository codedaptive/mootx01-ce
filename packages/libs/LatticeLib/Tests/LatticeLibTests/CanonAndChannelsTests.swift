// CanonAndChannelsTests.swift
//
// Tests for the bundled v1 canon loader and the two distribution
// channels.

import Foundation
import Testing
@testable import LatticeLib

@Suite("Canon and channels")
struct CanonAndChannelsTests {

    @Test("bundled v1 canon loads")
    func bundledLoads() {
        let canon = LatticeLib.bundledCanon()
        #expect(canon != nil)
        #expect(canon?.canonVersion == "v1")
    }

    @Test("bundled v1 canon resolves known codes")
    func bundledResolves() {
        let entry = LatticeLib.entry(for: "501")
        #expect(entry?.label == "mathematics")
        #expect(entry?.classBase == 500)
    }

    @Test("unknown but well-formed code returns nil (valid-but-unknown)")
    func validButUnknown() {
        // Pick a well-formed code outside the seed entries.
        #expect(Code.isWellFormed("540.137"))
        #expect(LatticeLib.entry(for: "540.137") == nil)
    }

    @Test("fast-codes payload is sorted by code")
    func fastCodesSorted() {
        let canon = LatticeLib.bundledCanon()!
        let payload = Channels.fastCodes(from: canon)
        let codes = payload.codes.map(\.code)
        #expect(codes == codes.sorted())
    }

    @Test("fast-codes JSON encoding is deterministic")
    func fastCodesDeterministic() throws {
        let canon = LatticeLib.bundledCanon()!
        let payload = Channels.fastCodes(from: canon)
        let a = try Channels.encodeFastCodes(payload)
        let b = try Channels.encodeFastCodes(payload)
        #expect(a == b)
    }

    @Test("slow-docs markdown mentions every spine class")
    func slowDocsCoversSpine() {
        let canon = LatticeLib.bundledCanon()!
        let doc = Channels.slowDocs(from: canon)
        for cls in NotationSpine.classes {
            #expect(doc.contains(cls.name), "missing class \(cls.name)")
        }
    }

    @Test("slow-docs markdown lists reserved ranges")
    func slowDocsHasReservedRanges() {
        let canon = LatticeLib.bundledCanon()!
        let doc = Channels.slowDocs(from: canon)
        #expect(doc.contains("Reserved ranges"))
        #expect(doc.contains("community"))
        #expect(doc.contains("annex"))
    }
}
