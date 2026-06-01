// AssemblerTests.swift
//
// The assembler is the pure function from CC0 input to MDCC canon.
// The two contracts these tests pin:
//
//   1. Determinism — same input, same output, regardless of input
//      array order or repeat invocations.
//   2. Stable keying — a source identity present in the prior
//      registry keeps its code when the assembler re-runs.

import Testing
@testable import LatticeLib

@Suite("Assembler")
struct AssemblerTests {

    private func sampleInput(
        registry: StableKeyRegistry = StableKeyRegistry(entries: [])
    ) -> AssemblerInput {
        let concepts = [
            SourceConcept(sourceIdentity: "Q5891", label: "philosophy", pinnedClassBase: 100),
            SourceConcept(sourceIdentity: "Q336",  label: "science",    pinnedClassBase: 500),
            SourceConcept(sourceIdentity: "Q395",  label: "mathematics", pinnedClassBase: nil),
            SourceConcept(sourceIdentity: "Q420",  label: "biology",    pinnedClassBase: nil),
        ]
        let edges = [
            SourceEdge(child: "Q395", parent: "Q336"),
            SourceEdge(child: "Q420", parent: "Q336"),
        ]
        return AssemblerInput(
            concepts: concepts,
            edges: edges,
            pinnedParents: PinnedParents([:]),
            registry: registry,
            canonVersion: "v1"
        )
    }

    @Test("assembler is deterministic across input shuffles")
    func deterministic() {
        let base = sampleInput()
        let shuffled = AssemblerInput(
            concepts: base.concepts.reversed(),
            edges: base.edges.reversed(),
            pinnedParents: base.pinnedParents,
            registry: base.registry,
            canonVersion: base.canonVersion
        )
        let a = Assembler.assemble(base)
        let b = Assembler.assemble(shuffled)
        #expect(a.canon.entries == b.canon.entries)
    }

    @Test("repeat invocations on the same input produce identical canons")
    func repeatable() {
        let input = sampleInput()
        let a = Assembler.assemble(input)
        let b = Assembler.assemble(input)
        #expect(a.canon.entries == b.canon.entries)
    }

    @Test("pinned class is honoured")
    func pinnedClass() {
        let input = sampleInput()
        let out = Assembler.assemble(input)
        let philosophy = out.canon.entry(forSourceIdentity: "Q5891")
        #expect(philosophy?.classBase == 100)
    }

    @Test("unpinned child inherits parent's class")
    func childInheritsClass() {
        let input = sampleInput()
        let out = Assembler.assemble(input)
        let math = out.canon.entry(forSourceIdentity: "Q395")
        #expect(math?.classBase == 500)   // inherited from Q336 (science)
    }

    @Test("orphan with no parents falls into Generalities (000)")
    func orphanGeneralities() {
        let input = AssemblerInput(
            concepts: [
                SourceConcept(sourceIdentity: "Qorphan", label: "lonely concept", pinnedClassBase: nil)
            ],
            edges: [],
            pinnedParents: PinnedParents([:]),
            registry: StableKeyRegistry(entries: []),
            canonVersion: "v1"
        )
        let out = Assembler.assemble(input)
        let entry = out.canon.entry(forSourceIdentity: "Qorphan")
        #expect(entry?.classBase == 0)
        #expect(out.diagnostics.contains(where: { $0.sourceIdentity == "Qorphan" && $0.kind == .orphanCycle }))
    }

    @Test("tier 2 wins over lex-min when only the lex-min parent has been placed")
    func multiParentTierTwoWins() {
        // Two parents: Qa pinned to class 100, Qz pinned to class 500.
        // Lex-min of {Qa, Qz} is Qa. The child has no pinned class.
        // Tier 2 should pick Qa (lower base 100 < 500) — same as lex
        // here, but we structure the case to verify the resolver fires
        // rather than relying on the lex backstop. We add a second
        // child where Qz comes lex-first to expose the difference:
        // for that child, tier 2 must still pick Qa (the parent in
        // class 100), not Qz (lex-min but higher base).
        //
        // To force the lex/tier distinction we use parent names where
        // the lower-base parent is lex-larger.
        let concepts = [
            SourceConcept(sourceIdentity: "Qaa_high_base", label: "high",   pinnedClassBase: 500),
            SourceConcept(sourceIdentity: "Qzz_low_base",  label: "low",    pinnedClassBase: 100),
            SourceConcept(sourceIdentity: "Qchild",        label: "child",  pinnedClassBase: nil),
        ]
        let edges = [
            SourceEdge(child: "Qchild", parent: "Qaa_high_base"),
            SourceEdge(child: "Qchild", parent: "Qzz_low_base"),
        ]
        let input = AssemblerInput(
            concepts: concepts,
            edges: edges,
            pinnedParents: PinnedParents([:]),
            registry: StableKeyRegistry(entries: []),
            canonVersion: "v1"
        )
        let out = Assembler.assemble(input)
        let child = out.canon.entry(forSourceIdentity: "Qchild")
        // Tier 2 picks the parent in the lower-base class (Qzz @ 100),
        // not the lex-min (Qaa @ 500). If the resolver were not seeing
        // the current map, the child would inherit Qaa's class 500
        // because lex-min is the only backstop available.
        #expect(child?.classBase == 100)
    }

    @Test("registry pins are preserved across re-runs")
    func registryPinned() {
        let priorRegistry = StableKeyRegistry(entries: [
            StableKeyEntry(sourceIdentity: "Q5891", code: "117", firstAssignedInCanon: "v1"),
        ])
        let input = sampleInput(registry: priorRegistry)
        let out = Assembler.assemble(input)
        let philosophy = out.canon.entry(forSourceIdentity: "Q5891")
        #expect(philosophy?.code == "117")
    }

    @Test("duplicate source identity emits a diagnostic")
    func duplicateDetected() {
        let input = AssemblerInput(
            concepts: [
                SourceConcept(sourceIdentity: "Qdupe", label: "first",  pinnedClassBase: 500),
                SourceConcept(sourceIdentity: "Qdupe", label: "second", pinnedClassBase: 500),
            ],
            edges: [],
            pinnedParents: PinnedParents([:]),
            registry: StableKeyRegistry(entries: []),
            canonVersion: "v1"
        )
        let out = Assembler.assemble(input)
        #expect(out.diagnostics.contains(where: { $0.kind == .duplicateSourceIdentity }))
    }

    @Test("unknown pinnedClassBase emits a diagnostic")
    func unknownPinnedClass() {
        let input = AssemblerInput(
            concepts: [
                SourceConcept(sourceIdentity: "Qbad", label: "x", pinnedClassBase: 1234),
            ],
            edges: [],
            pinnedParents: PinnedParents([:]),
            registry: StableKeyRegistry(entries: []),
            canonVersion: "v1"
        )
        let out = Assembler.assemble(input)
        #expect(out.diagnostics.contains(where: { $0.kind == .unknownPinnedClass }))
    }
}
