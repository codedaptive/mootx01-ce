// LexiconBuilderTests.swift
//
// Drives LexiconBuilder against tiny fixtures written to a temp directory,
// asserting the cookbook §3.1 build contract: WordNet lemma sense is
// authoritative (beats an incidental Wikidata alias), Wikidata fills
// WordNet-uncovered keys, unmapped synsets fall back to "wn:<id>", and the
// build is deterministic.

import Foundation
import Testing
@testable import LatticeLib

@Suite("LexiconBuilder (cookbook §3.1)")
struct LexiconBuilderTests {

    // Writes fixtures to a fresh temp dir and returns (dictDir, tsvPath).
    private func fixtures() throws -> (dict: String, tsv: String) {
        let base = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("lexfix-\(UUID().uuidString)")
        let dict = (base as NSString).appendingPathComponent("dict")
        try FileManager.default.createDirectory(atPath: dict, withIntermediateDirectories: true)

        // WordNet index.noun: "dog" (sense 0 = synset 02086723) and "xyzzy"
        // (synset with no Wikidata mapping). Format:
        // lemma pos synset_cnt p_cnt sense_cnt tagsense_cnt offset...
        let indexNoun = """
        dog n 1 0 1 0 02086723
        xyzzy n 1 0 1 0 99999999
        """
        try indexNoun.write(toFile: (dict as NSString).appendingPathComponent("index.noun"),
                            atomically: true, encoding: .utf8)

        // Wikidata TSV: Q144 (dog) anchors synset 02086723-n + alias "hound";
        // Q181055 (hot dog) has incidental alias "dog"; Q76 (Obama) has no
        // WordNet coverage. Header mirrors the seed query.
        let tsv = """
        ?item\t?wn\t?label\t?alias
        <http://www.wikidata.org/entity/Q144>\t"02086723-n"\t"dog"@en\t"hound"@en
        <http://www.wikidata.org/entity/Q181055>\t"07697100-n"\t"hot dog"@en\t"dog"@en
        <http://www.wikidata.org/entity/Q76>\t""\t"Barack Obama"@en\t"Obama"@en
        """
        let tsvPath = (base as NSString).appendingPathComponent("wd.tsv")
        try tsv.write(toFile: tsvPath, atomically: true, encoding: .utf8)
        return (dict, tsvPath)
    }

    @Test("WordNet lemma sense beats an incidental Wikidata alias")
    func wordNetAuthoritative() throws {
        let (dict, tsv) = try fixtures()
        let lex = try LexiconBuilder.build(.init(wordNetDictDir: dict, wikidataTSV: tsv, version: "t"))
        // "dog" is claimed by both Q144 (WordNet synset) and Q181055 (alias);
        // WordNet wins.
        #expect(lex.entries["dog"] == "Q144")
    }

    @Test("Wikidata alias fills a WordNet-uncovered key")
    func wikidataFillsGap() throws {
        let (dict, tsv) = try fixtures()
        let lex = try LexiconBuilder.build(.init(wordNetDictDir: dict, wikidataTSV: tsv, version: "t"))
        #expect(lex.entries["obama"] == "Q76")      // no WordNet "obama"
        #expect(lex.entries["hound"] == "Q144")     // alias, no WordNet collision
    }

    @Test("Unmapped synset falls back to wn:<id>")
    func wordNetFallback() throws {
        let (dict, tsv) = try fixtures()
        let lex = try LexiconBuilder.build(.init(wordNetDictDir: dict, wikidataTSV: tsv, version: "t"))
        #expect(lex.entries["xyzzi"] == "wn:99999999-n" || lex.entries["xyzzy"] == "wn:99999999-n")
    }

    @Test("multi-word surfaces are not indexed as single keys")
    func multiWordSkipped() throws {
        let (dict, tsv) = try fixtures()
        let lex = try LexiconBuilder.build(.init(wordNetDictDir: dict, wikidataTSV: tsv, version: "t"))
        // "hot dog" / "Barack Obama" are multi-word; they produce no single key.
        #expect(lex.entries["hot dog"] == nil)
        #expect(lex.entries["barack obama"] == nil)
    }

    @Test("build is deterministic")
    func deterministic() throws {
        let (dict, tsv) = try fixtures()
        let a = try LexiconBuilder.build(.init(wordNetDictDir: dict, wikidataTSV: tsv, version: "t"))
        let b = try LexiconBuilder.build(.init(wordNetDictDir: dict, wikidataTSV: tsv, version: "t"))
        #expect(a == b)
    }
}
