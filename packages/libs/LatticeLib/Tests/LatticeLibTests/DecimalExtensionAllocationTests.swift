// DecimalExtensionAllocationTests.swift
//
// MDCC-04. Two contracts proven here:
//
//   A. The stable-key allocator descends into the decimal-extension
//      leaf space once the flat band NN00-NN79 of a class is full,
//      deterministically, well-formed at every depth, never into a
//      reserved integer base, never reusing an occupied code, and
//      without disturbing codes already pinned in the flat band.
//
//   B. The edge fetch admits a seed child's parent one hop outside the
//      seed as a routing node, so the child propagates to the parent's
//      spine class instead of collapsing to Generalities — while the
//      routing node itself is never emitted as a canon entry.
//
// Contract A is proven by tests 1-6 (the allocator); contract B by
// test 7 (the one-hop edge fetch driven through the full assembler).

import Foundation
import Testing
@testable import LatticeLib

@Suite("Decimal-extension allocation")
struct DecimalExtensionAllocationTests {

    /// A registry whose flat band NN00-NN79 for `base` is completely
    /// full — 80 occupied codes, one per unreserved slot.
    private func saturatedFlatBand(base: Int) -> StableKeyRegistry {
        var entries: [StableKeyEntry] = []
        for offset in 0..<80 {
            entries.append(StableKeyEntry(
                sourceIdentity: "Qflat\(base)_\(offset)",
                code: String(format: "%03d", base + offset),
                firstAssignedInCanon: "v1"
            ))
        }
        return StableKeyRegistry(entries: entries)
    }

    /// Allocates `count` fresh identities into `latticeClass` starting from
    /// `start`, emulating the assembler's running-registry loop: each
    /// allocation appends a pin so the next call sees it occupied.
    /// Returns the code sequence and the final registry.
    private func allocateSequence(
        count: Int,
        into latticeClass: LatticeClass,
        start: StableKeyRegistry
    ) -> (codes: [String], registry: StableKeyRegistry) {
        var entries = start.entries
        var registry = start
        var codes: [String] = []
        for i in 0..<count {
            guard let code = registry.nextFreeCode(in: latticeClass) else { break }
            codes.append(code)
            entries.append(StableKeyEntry(
                sourceIdentity: "Qnew_\(i)",
                code: code,
                firstAssignedInCanon: "v1"
            ))
            registry = StableKeyRegistry(entries: entries)
        }
        return (codes, registry)
    }

    // MARK: 1 — Descent past the flat band

    @Test("a saturated flat band yields a well-formed extension code, not nil")
    func descendsPastFlatBand() {
        let science = NotationSpine.owningClass(forBase: 500)!
        let reg = saturatedFlatBand(base: 500)
        let next = reg.nextFreeCode(in: science)
        #expect(next != nil)
        // The documented first-extension slot: depth 1 under the lowest
        // flat slot.
        #expect(next == "500.0")
        #expect(next.map(Code.isWellFormed) == true)
    }

    // MARK: 2 — Determinism

    @Test("allocating into a saturated class twice yields identical codes")
    func deterministicDescent() {
        let science = NotationSpine.owningClass(forBase: 500)!
        let start = saturatedFlatBand(base: 500)
        let runA = allocateSequence(count: 250, into: science, start: start)
        let runB = allocateSequence(count: 250, into: science, start: start)
        #expect(runA.codes == runB.codes)
        #expect(runA.codes.count == 250)
    }

    // MARK: 3 — Well-formed at every depth

    @Test("every allocated code is well-formed across depths")
    func wellFormedAtEveryDepth() {
        let science = NotationSpine.owningClass(forBase: 500)!
        // 80 flat slots are pre-filled; 1000 more crosses the 800-code
        // depth-1 band into depth-2 extensions.
        let result = allocateSequence(count: 1000, into: science, start: saturatedFlatBand(base: 500))
        #expect(result.codes.count == 1000)
        for code in result.codes {
            #expect(Code.isWellFormed(code), "ill-formed code emitted: \(code)")
        }
        // Confirm the walk actually reached two-digit extensions.
        #expect(result.codes.contains { $0.split(separator: ".").last?.count == 2 })
    }

    // MARK: 4 — Reserved-range skip at depth

    @Test("no allocated code has a reserved integer base, at any depth")
    func skipsReservedAtDepth() {
        let science = NotationSpine.owningClass(forBase: 500)!
        let result = allocateSequence(count: 1000, into: science, start: saturatedFlatBand(base: 500))
        for code in result.codes {
            #expect(!ReservedRanges.isReserved(code), "allocated into reserved range: \(code)")
            if let base = Code.integerBase(of: code) {
                // The reserved community/annex block of class 500 is
                // 580-599; no extension may sit on a reserved base.
                #expect(!(580...599).contains(base), "reserved base \(base) in \(code)")
            }
        }
    }

    // MARK: 5 — Pin preservation (flat band unchanged)

    @Test("the descent does not disturb flat-band allocation or prior pins")
    func pinsPreserved() {
        let science = NotationSpine.owningClass(forBase: 500)!
        // A partially-filled flat band: 500, 501, 502 pinned.
        let reg = StableKeyRegistry(entries: [
            StableKeyEntry(sourceIdentity: "Qa", code: "500", firstAssignedInCanon: "v1"),
            StableKeyEntry(sourceIdentity: "Qb", code: "501", firstAssignedInCanon: "v1"),
            StableKeyEntry(sourceIdentity: "Qc", code: "502", firstAssignedInCanon: "v1"),
        ])
        // Prior pins are still honoured.
        #expect(reg.code(for: "Qb") == "501")
        #expect(reg.isOccupied("501"))
        // A fresh identity still takes the next flat slot — the descent
        // never pre-empts an available flat code.
        #expect(reg.nextFreeCode(in: science) == "503")
    }

    // MARK: 6 — No collision

    @Test("a large allocation produces no duplicate codes; all are occupied")
    func noCollision() {
        let science = NotationSpine.owningClass(forBase: 500)!
        let result = allocateSequence(count: 1000, into: science, start: saturatedFlatBand(base: 500))
        #expect(Set(result.codes).count == result.codes.count)
        for code in result.codes {
            #expect(result.registry.isOccupied(code))
        }
    }

    // MARK: 7 — One-hop routing (FixtureEdgeSource)

    @Test("a one-hop out-of-seed parent routes a child to the parent's class, unemitted")
    func oneHopRouting() async throws {
        // Seed: an unpinned child and a sibling pinned to Natural
        // sciences (500). Both subclass the SAME parent, which is NOT in
        // the seed — it is a routing node.
        let concepts = [
            SourceConcept(sourceIdentity: "Qchild",   label: "child concept",   pinnedClassBase: nil),
            SourceConcept(sourceIdentity: "Qsibling", label: "sibling concept", pinnedClassBase: 500),
        ]
        let qids = Set(concepts.map(\.sourceIdentity))
        // "Qrouter" is the out-of-seed parent.
        let fixtureEdges = [
            SourceEdge(child: "Qchild",   parent: "Qrouter"),
            SourceEdge(child: "Qsibling", parent: "Qrouter"),
        ]
        let edges = try await EdgeFetcher(source: FixtureEdgeSource(fixtureEdges)).fetch(for: qids)
        // The one-hop rule admits the edge to the out-of-seed parent.
        #expect(edges.contains { $0.parent == "Qrouter" })

        let output = Assembler.assemble(AssemblerInput(
            concepts: concepts,
            edges: edges,
            pinnedParents: PinnedParents([:]),
            registry: StableKeyRegistry(entries: []),
            canonVersion: "v1"
        ))
        // The child rode the routing node to Natural sciences, not
        // Generalities.
        let child = output.canon.entry(forSourceIdentity: "Qchild")
        #expect(child?.classBase == 500)
        // The routing node is not a canon entry — only seed concepts get
        // codes.
        #expect(output.canon.entry(forSourceIdentity: "Qrouter") == nil)
        #expect(!output.canon.entries.contains { $0.sourceIdentity == "Qrouter" })
    }
}
