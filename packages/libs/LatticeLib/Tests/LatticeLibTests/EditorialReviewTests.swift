// EditorialReviewTests.swift
//
// The editorial review set for mission MDCC-02. These tests encode an
// editor's judgment about where a concept *should* land on the MDCC
// spine, independent of where the raw `udc_hint` bucketing put it, and
// assert the shipped canon honors that judgment.
//
// The editorial thesis (one defect, one cohort):
//
//   UDC's class 8 is "Language. Linguistics. Literature" — it conflates
//   the study of language with literary works. The CC0 seed carries a
//   `udc_hint` per concept, and every language/linguistics concept
//   inherits a hint beginning with "8", so the coarse leading-digit
//   bucketing (WikidataCC0Source.pinnedClassBase) sends them all to MDCC
//   base 800 (Literature).
//
//   But the MDCC spine (NotationSpine) deliberately SEPARATES class 400
//   "Language and communication" from class 800 "Literature". The
//   committed pre-pin canon therefore leaves class 400 empty and files
//   linguistics under Literature — editorially wrong. A grammar, a
//   phonetics treatise, and the field of linguistics are not literary
//   works; they belong in 400.
//
//   The MDCC-02 class pins (class_pins_v1.json) override the hint-derived
//   pinnedClassBase for this reviewed cohort, moving them 800 -> 400.
//
// These tests fail before the pins are authored and the canon
// regenerated (the concepts are still in 800), and pass after. Each
// entry pairs a Wikidata QID with the spine base an editor asserts is
// correct (400) and the human-readable label for self-documentation.

import Foundation
import Testing
@testable import LatticeLib

@Suite("Editorial review set (MDCC-02)")
struct EditorialReviewTests {

    /// One reviewed concept: the CC0 source identity, the spine base an
    /// editor asserts is correct, and the label (for readable failures).
    struct ReviewConcept: Sendable, CustomStringConvertible {
        let qid: String
        let assertedBase: Int
        let label: String
        var description: String { "\(qid) \"\(label)\" -> \(assertedBase)" }
    }

    /// The 44 linguistics concepts the udc_hint bucketing filed under
    /// Literature (800) that an editor asserts belong under Language and
    /// communication (400). Drawn from concepts the pre-pin canon placed
    /// in class 800; each is an unambiguous language/linguistics concept
    /// (biology and logic homonyms such as "syntaxin binding", "plant
    /// morphology", and "translation (biology)" were excluded).
    static let reviewSet: [ReviewConcept] = [
        ReviewConcept(qid: "Q315",        assertedBase: 400, label: "language"),
        ReviewConcept(qid: "Q34770",      assertedBase: 400, label: "language"),
        ReviewConcept(qid: "Q75488338",   assertedBase: 400, label: "language"),
        ReviewConcept(qid: "Q33742",      assertedBase: 400, label: "natural language"),
        ReviewConcept(qid: "Q57159190",   assertedBase: 400, label: "natural language"),
        ReviewConcept(qid: "Q8162",       assertedBase: 400, label: "linguistics"),
        ReviewConcept(qid: "Q14467526",   assertedBase: 400, label: "linguist"),
        ReviewConcept(qid: "Q112182478",  assertedBase: 400, label: "linguistics and language"),
        ReviewConcept(qid: "Q66664364",   assertedBase: 400, label: "linguistic term"),
        ReviewConcept(qid: "Q1478235",    assertedBase: 400, label: "history of linguistics"),
        ReviewConcept(qid: "Q8192",       assertedBase: 400, label: "writing system"),
        ReviewConcept(qid: "Q35395",      assertedBase: 400, label: "phonetics"),
        ReviewConcept(qid: "Q81066006",   assertedBase: 400, label: "phonetics"),
        ReviewConcept(qid: "Q96725769",   assertedBase: 400, label: "phonetics and speech sciences"),
        ReviewConcept(qid: "Q110761784",  assertedBase: 400, label: "phonetics and speech science"),
        ReviewConcept(qid: "Q8091",       assertedBase: 400, label: "grammar"),
        ReviewConcept(qid: "Q37258088",   assertedBase: 400, label: "grammar"),
        ReviewConcept(qid: "Q115804591",  assertedBase: 400, label: "grammar"),
        ReviewConcept(qid: "Q19911815",   assertedBase: 400, label: "grammar"),
        ReviewConcept(qid: "Q15991187",   assertedBase: 400, label: "grammarian"),
        ReviewConcept(qid: "Q2395230",    assertedBase: 400, label: "syntax"),
        ReviewConcept(qid: "Q37437",      assertedBase: 400, label: "syntax"),
        ReviewConcept(qid: "Q477930",     assertedBase: 400, label: "syntax"),
        ReviewConcept(qid: "Q71047059",   assertedBase: 400, label: "syntax"),
        ReviewConcept(qid: "Q1152399",    assertedBase: 400, label: "syntax"),
        ReviewConcept(qid: "Q25449815",   assertedBase: 400, label: "semantics"),
        ReviewConcept(qid: "Q39645",      assertedBase: 400, label: "semantics"),
        ReviewConcept(qid: "Q139808385",  assertedBase: 400, label: "semantics"),
        ReviewConcept(qid: "Q40634",      assertedBase: 400, label: "philology"),
        ReviewConcept(qid: "Q110404717",  assertedBase: 400, label: "philology"),
        ReviewConcept(qid: "Q13418253",   assertedBase: 400, label: "philologist"),
        ReviewConcept(qid: "Q25295",      assertedBase: 400, label: "language family"),
        ReviewConcept(qid: "Q2330667",    assertedBase: 400, label: "language development"),
        ReviewConcept(qid: "Q3621696",    assertedBase: 400, label: "language model"),
        ReviewConcept(qid: "Q30642",      assertedBase: 400, label: "natural language processing"),
        ReviewConcept(qid: "Q1078276",    assertedBase: 400, label: "natural language understanding"),
        ReviewConcept(qid: "Q1513879",    assertedBase: 400, label: "natural language generation"),
        ReviewConcept(qid: "Q7553",       assertedBase: 400, label: "translation"),
        ReviewConcept(qid: "Q21561311",   assertedBase: 400, label: "rhetoric"),
        ReviewConcept(qid: "Q26693471",   assertedBase: 400, label: "rhetoric"),
        ReviewConcept(qid: "Q81009",      assertedBase: 400, label: "rhetoric"),
        ReviewConcept(qid: "Q1896045",    assertedBase: 400, label: "rhetoric"),
        ReviewConcept(qid: "Q361809",     assertedBase: 400, label: "rhetorician"),
        ReviewConcept(qid: "Q1762471",    assertedBase: 400, label: "rhetorical device"),
    ]

    /// Loads the shipped canon resource. A nil load is a hard failure —
    /// the resource must always bundle.
    private func loadCanon() throws -> LatticeCanon {
        let canon = LatticeCanon.loadBundledV1()
        try #require(canon != nil, "LatticeCanonV1.json failed to load from the bundle")
        return canon!
    }

    /// The editorial pin directory, resolved relative to this test file
    /// so the test finds the build-input files without a bundle
    /// resource. This file lives at LatticeLib/Tests/LatticeLibTests/, so the
    /// package root is three directories up; the pins live under
    /// Resources/editorial/ at the package root (build inputs, not
    /// bundled).
    private static func editorialURL(_ filename: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // LatticeLibTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // LatticeLib (package root)
            .appendingPathComponent("Resources/editorial/\(filename)")
    }

    // MARK: Pin-loader contracts (Part 2)

    @Test("class_pins_v1.json loads and maps every reviewed QID to its asserted class")
    func classPinsCoverReviewSet() throws {
        let classPins = try EditorialPins.loadClassPins(from: Self.editorialURL("class_pins_v1.json"))
        for concept in Self.reviewSet {
            #expect(classPins[concept.qid] == concept.assertedBase,
                    "class pin for \(concept.qid) (\(concept.label)) is \(classPins[concept.qid]?.description ?? "absent"), expected \(concept.assertedBase)")
        }
    }

    @Test("parent_pins_v1.json loads into a PinnedParents map")
    func parentPinsLoad() throws {
        // Proves the parent-pin channel is authored and wired even though
        // it is inert on the current fully-pinned seed (see file note):
        // the loader parses it and constructs a PinnedParents whose
        // entries resolve. NLP -> linguistics is the anchor edge.
        let pins = try EditorialPins.loadParentPins(from: Self.editorialURL("parent_pins_v1.json"))
        #expect(pins.pinnedParent(for: "Q30642") == "Q8162",
                "expected the NLP -> linguistics parent pin to load")
    }

    @Test("applying class pins overrides a concept's hint-derived pinnedClassBase")
    func classPinsOverridePinnedClassBase() throws {
        let classPins = try EditorialPins.loadClassPins(from: Self.editorialURL("class_pins_v1.json"))
        // A concept that arrived pinned to 800 by its udc_hint must come
        // out pinned to 400 after the class-pin override is applied.
        let before = SourceConcept(sourceIdentity: "Q8162", label: "linguistics", pinnedClassBase: 800)
        let after = EditorialPins.apply(classPins: classPins, to: [before])
        #expect(after.first?.pinnedClassBase == 400)
    }

    // MARK: Per-concept assertions (one test case per reviewed QID)

    @Test("reviewed concept lands in its editorially-correct spine class", arguments: reviewSet)
    func reviewedConceptInAssertedClass(_ concept: ReviewConcept) throws {
        let canon = try loadCanon()
        let entry = canon.entry(forSourceIdentity: concept.qid)
        try #require(entry != nil, "\(concept.qid) (\(concept.label)) is absent from the canon")
        #expect(
            entry!.classBase == concept.assertedBase,
            "\(concept) but canon placed it in \(entry!.classBase) (code \(entry!.code))"
        )
    }

    // MARK: Aggregate checks

    @Test("class 400 (Language and communication) is populated by the review cohort")
    func class400Populated() throws {
        let canon = try loadCanon()
        let in400 = canon.entries.filter { $0.classBase == 400 }
        // The reviewed cohort is the whole intended population of 400 in
        // v1; it must not be empty and must hold at least the review set.
        #expect(in400.count >= Self.reviewSet.count,
                "class 400 holds \(in400.count) entries; expected at least \(Self.reviewSet.count)")
    }

    @Test("every reviewed concept carries a code in its asserted class's range")
    func reviewedCodesAreCoherent() throws {
        let canon = try loadCanon()
        for concept in Self.reviewSet {
            guard let entry = canon.entry(forSourceIdentity: concept.qid) else { continue }
            // The owning class of the rendered code must match the
            // classBase — no concept may carry an 8xx code while filed in
            // class 400 (the code/classBase coherence the warm rebuild
            // preserves by re-homing reclassified concepts).
            let owning = NotationSpine.owningClass(for: entry.code)
            #expect(owning?.base == concept.assertedBase,
                    "\(concept.qid) code \(entry.code) resolves to class \(owning?.base.description ?? "nil"), not \(concept.assertedBase)")
        }
    }
}
