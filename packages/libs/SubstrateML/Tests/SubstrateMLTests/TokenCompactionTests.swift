// TokenCompactionTests.swift
//
// The §7.6 token-compaction transform and the §6 token-count estimator
// (SPEC_DISTILLATION_STORAGE). One pure transform, two uses: the
// short-item distillation path and the tokenized-on-read hydration
// variants. Deterministic; the Rust twin (token_compaction.rs) must be
// bit-identical — conformance vectors live in
// TokenCompactionConformanceTests + token_compaction_conformance.rs.
//
// Rule order under test (SPEC §5.3, priority order):
//   1. Propositional fidelity — negation and quantifiers ALWAYS survive;
//      entities, numbers, units, dates verbatim.
//   2. Stopword and filler removal.
//   3. Dense wording (fixed phrase-rewrite table).
//   4. Minimal markup / ASCII punctuation.
//   5. Single spacing.

import Testing
@testable import SubstrateML

@Suite("TokenCompaction")
struct TokenCompactionTests {

    // MARK: - Rule 2: stopword and filler removal

    @Test("articles and fillers are dropped")
    func dropsArticlesAndFillers() {
        #expect(TokenCompaction.compact("the cat sat on a mat")
            == "Cat sat on mat")
        #expect(TokenCompaction.compact("this is really very important")
            == "This important")
    }

    @Test("bare copulas drop; other verbs survive")
    func dropsBareCopulas() {
        #expect(TokenCompaction.compact("my favorite color is blue")
            == "My favorite color blue")
    }

    // MARK: - Rule 1: fidelity guards

    @Test("negation always survives")
    func negationSurvives() {
        let out = TokenCompaction.compact("I really do not want the deluxe package")
        #expect(out.contains("not"))
        #expect(!out.contains("really"))
        // The proposition is preserved: negation + object.
        #expect(out == "I do not want deluxe package")
    }

    @Test("contracted negation survives untouched")
    func contractedNegationSurvives() {
        let out = TokenCompaction.compact("She doesn't like the very loud music")
        #expect(out.contains("doesn't"))
        #expect(out == "She doesn't like loud music")
    }

    @Test("quantifiers survive")
    func quantifiersSurvive() {
        #expect(TokenCompaction.compact("all of the tests pass")
            == "All of tests pass")
        #expect(TokenCompaction.compact("never delete the audit log")
            == "Never delete audit log")
    }

    @Test("numbers, units, and dates survive verbatim")
    func numbersAndDatesSurvive() {
        let out = TokenCompaction.compact(
            "The meeting moved from Tuesday, March 3rd to Thursday, March 5th")
        #expect(out == "Meeting moved from Tuesday, March 3rd to Thursday, March 5th")
    }

    @Test("entities (capitalized names) are never dropped or abbreviated")
    func entitiesSurvive() {
        let out = TokenCompaction.compact("Sarah will send out the updated calendar invites")
        #expect(out.contains("Sarah"))
        #expect(out == "Sarah will send out updated calendar invites")
    }

    // MARK: - Rule 3: dense wording (phrase rewrites)

    @Test("perfect-passive auxiliaries compress")
    func perfectAuxiliariesCompress() {
        #expect(TokenCompaction.compact("The meeting has been moved to Thursday")
            == "Meeting moved to Thursday")
    }

    @Test("verbose constructions rewrite densely")
    func verboseRewrites() {
        #expect(TokenCompaction.compact("call me in order to confirm")
            == "Call me to confirm")
        #expect(TokenCompaction.compact("delayed due to the fact that the vendor slipped")
            == "Delayed because vendor slipped")
        #expect(TokenCompaction.compact("please make sure to update your travel plans")
            == "Update your travel plans")
    }

    @Test("phrase rewrite carries trailing punctuation")
    func phraseRewriteCarriesPunctuation() {
        // "has been moved" ends the clause; the terminator must survive.
        #expect(TokenCompaction.compact("The invoice has been paid.")
            == "Invoice paid.")
    }

    // MARK: - Rule 4/5: markup and spacing

    @Test("unicode punctuation normalizes to ASCII")
    func unicodePunctuationNormalizes() {
        #expect(TokenCompaction.compact("the “quoted” value — right")
            == "\"quoted\" value - right")
        #expect(TokenCompaction.compact("wait… done")
            == "Wait... done")
    }

    @Test("whitespace runs and blank lines collapse to single spaces")
    func whitespaceCollapses() {
        #expect(TokenCompaction.compact("one   two\n\n\nthree\t four")
            == "One two three four")
        #expect(TokenCompaction.compact("  padded  ") == "Padded")
    }

    @Test("dropped stopword's trailing punctuation migrates to the previous token")
    func punctuationMigratesOnDrop() {
        // "the," is dropped; its comma must not vanish into a doubled gap.
        let out = TokenCompaction.compact("first the, second")
        #expect(out == "First, second")
    }

    @Test("sentence-initial letters are recapitalized after drops")
    func sentenceRecapitalization() {
        let out = TokenCompaction.compact("the plan works. the team agrees.")
        #expect(out == "Plan works. Team agrees.")
    }

    // MARK: - Determinism and edge cases

    @Test("compaction is deterministic and idempotent-safe on empty input")
    func emptyAndDeterminism() {
        #expect(TokenCompaction.compact("") == "")
        #expect(TokenCompaction.compact("   ") == "")
        let a = TokenCompaction.compact("The quick brown fox, really.")
        let b = TokenCompaction.compact("The quick brown fox, really.")
        #expect(a == b)
    }

    @Test("all-stopword input compacts to empty")
    func allStopwordsCompactToEmpty() {
        #expect(TokenCompaction.compact("the a an really") == "")
    }
}

@Suite("TokenCountEstimate")
struct TokenCountEstimateTests {

    // Estimator contract (SPEC §6): deterministic, vendor-neutral,
    // integer fixed-point blend of bytes/4 and words*4/3 —
    // est = (3*bytes + 16*words + 12) / 24 (integer division, round-half).
    // Advisory only; ±20% of cl100k_base on English prose.

    @Test("empty text estimates zero")
    func emptyIsZero() {
        #expect(TokenCompaction.estimateTokenCount("") == 0)
    }

    @Test("fixed-point formula on known inputs")
    func knownValues() {
        // "Favorite color blue." — 20 UTF-8 bytes, 3 words:
        // (3*20 + 16*3 + 12) / 24 = 120/24 = 5
        #expect(TokenCompaction.estimateTokenCount("Favorite color blue.") == 5)
        // "hi" — 2 bytes, 1 word: (6 + 16 + 12)/24 = 34/24 = 1
        #expect(TokenCompaction.estimateTokenCount("hi") == 1)
    }

    @Test("estimate grows monotonically with prose length")
    func monotoneGrowth() {
        let short = TokenCompaction.estimateTokenCount("Quarterly planning meeting moved.")
        let long = TokenCompaction.estimateTokenCount(
            "Quarterly planning meeting moved Tuesday March 3 to Thursday March 5; "
            + "4th floor conference room under renovation.")
        #expect(long > short)
        #expect(short >= 1)
    }

    @Test("non-ASCII text counts UTF-8 bytes, not characters")
    func utf8Bytes() {
        // "café" = 5 UTF-8 bytes, 1 word: (15 + 16 + 12)/24 = 43/24 = 1
        #expect(TokenCompaction.estimateTokenCount("café") == 1)
    }
}
