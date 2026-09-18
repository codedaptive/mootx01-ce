import Testing
import Foundation
@testable import mcp_benchmarker

// LoCoMoSpecScorerTests.swift — Conformance and golden-pin tests for the
// LoCoMo-spec scoring pipeline (§1–§5 of LOCOMO_OFFICIAL_PROTOCOL.md).
//
// Source of truth for all expected values:
//   conformance/locomo-spec/scorer_vectors.json
//
// Both this Swift suite and the Rust twin (locomo_spec_conformance.rs) load the
// same JSON file and assert identical results. Neither port hardcodes expected
// values independently for the vector-driven tests.
//
// Golden pins (§2 requirement): at least one literal input→expected-value
// assertion per: normalizeAnswer, porterStem, f1Score, multiAnswerF1, the cat-5
// binary rule, session-form evidence recall, and dia-form evidence recall. These
// are the SAME literals asserted in the Rust twin.
//
// Run with:
//   swift test --scratch-path .build-locospec --filter LoCoMoSpecScorer

// MARK: - Path helpers

/// Resolves `conformance/locomo-spec/scorer_vectors.json` relative to this file.
/// #filePath → Tests/mcp-benchmarkerTests/ → Tests/ → benchmarks/ → conformance/locomo-spec/
private func scorerVectorsURL() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // .../mcp-benchmarkerTests/
        .deletingLastPathComponent()   // .../Tests/
        .deletingLastPathComponent()   // .../benchmarks/
        .appendingPathComponent("conformance/locomo-spec/scorer_vectors.json")
}

/// Loads scorer_vectors.json, skipping the entire suite if the file is absent.
/// Returns the parsed top-level JSON dictionary.
private func loadVectors() throws -> [String: Any] {
    let url = scorerVectorsURL()
    guard FileManager.default.fileExists(atPath: url.path) else {
        // File present in the repo; absence signals env misconfiguration, not a
        // planned skip — surface the path so the developer can investigate.
        Issue.record("scorer_vectors.json not found at \(url.path); aborting LoCoMoSpecScorer tests")
        return [:]
    }
    let data = try Data(contentsOf: url)
    return try JSONSerialization.jsonObject(with: data) as! [String: Any]
}

// MARK: - §1 normalizeAnswer — conformance vectors

@Suite("LoCoMoSpecScorer — §1 normalizeAnswer vectors")
struct LoCoMoSpecScorerNormalizeTests {

    @Test("normalizeAnswer: all vectors in scorer_vectors.json pass")
    func normalizeAnswerVectors() throws {
        let vectors = try loadVectors()
        guard let cases = vectors["normalize_answer_cases"] as? [[String: Any]], !cases.isEmpty else {
            Issue.record("normalize_answer_cases missing or empty in scorer_vectors.json")
            return
        }
        for c in cases {
            let id       = c["id"]       as! String
            let input    = c["input"]    as! String
            let expected = c["expected"] as! String
            let got = normalizeAnswer(input)
            #expect(got == expected,
                    "normalize_answer '\(id)': expected \"\(expected)\", got \"\(got)\"")
        }
    }

    // ── Golden pins — §2 requirement ──────────────────────────────────────────
    // Same literals asserted in the Rust twin (locomo_spec_conformance.rs).

    /// §1 pipeline: strip comma → lower → remove punctuation → remove articles → collapse.
    /// "Hello, World!" → comma stripped → lowercase → '!' removed → no articles → "hello world".
    @Test("golden pin: normalizeAnswer(\"Hello, World!\") == \"hello world\"")
    func goldenPinHelloWorld() {
        #expect(normalizeAnswer("Hello, World!") == "hello world")
    }

    /// §1 article removal: "a" and "and" are whole-word articles per the regex \b pattern.
    @Test("golden pin: normalizeAnswer(\"a dog and a cat\") == \"dog cat\"")
    func goldenPinArticleRemoval() {
        #expect(normalizeAnswer("a dog and a cat") == "dog cat")
    }

    /// §1: apostrophe is in Python string.punctuation; removed leaving "runners".
    @Test("golden pin: normalizeAnswer(\"runner's high\") == \"runners high\"")
    func goldenPinApostrophe() {
        #expect(normalizeAnswer("runner's high") == "runners high")
    }
}

// MARK: - §2 porterStem — conformance vectors

@Suite("LoCoMoSpecScorer — §2 Porter stemmer vectors")
struct LoCoMoSpecScorerStemTests {

    @Test("porterStem: all vectors in scorer_vectors.json pass")
    func porterStemVectors() throws {
        let vectors = try loadVectors()
        guard let cases = vectors["porter_stem_cases"] as? [[String: Any]], !cases.isEmpty else {
            Issue.record("porter_stem_cases missing or empty in scorer_vectors.json")
            return
        }
        for c in cases {
            let id       = c["id"]       as! String
            let input    = c["input"]    as! String
            let expected = c["expected"] as! String
            let got = porterStem(input)
            #expect(got == expected,
                    "porter_stem '\(id)': expected \"\(expected)\", got \"\(got)\"")
        }
    }

    // ── Golden pins ───────────────────────────────────────────────────────────

    /// Classic Porter 1980 paper example: "caresses" → "caress" (Step 1a SSES→SS).
    @Test("golden pin: porterStem(\"caresses\") == \"caress\"")
    func goldenPinCaresses() {
        #expect(porterStem("caresses") == "caress")
    }

    /// Step 1b ING + double-consonant reduction: "running" → "run".
    @Test("golden pin: porterStem(\"running\") == \"run\"")
    func goldenPinRunning() {
        #expect(porterStem("running") == "run")
    }

    /// Step 1b ING + double-consonant reduction: "stemming" → "stem".
    @Test("golden pin: porterStem(\"stemming\") == \"stem\"")
    func goldenPinStemming() {
        #expect(porterStem("stemming") == "stem")
    }

    /// Words of 2 characters are returned unchanged (NLTK convention).
    @Test("golden pin: porterStem(\"in\") == \"in\"")
    func goldenPinTwoChar() {
        #expect(porterStem("in") == "in")
    }
}

// MARK: - §2 f1Score — conformance vectors

@Suite("LoCoMoSpecScorer — §2 f1Score vectors")
struct LoCoMoSpecScorerF1Tests {

    @Test("f1Score: all vectors in scorer_vectors.json pass")
    func f1ScoreVectors() throws {
        let vectors = try loadVectors()
        guard let cases = vectors["f1_score_cases"] as? [[String: Any]], !cases.isEmpty else {
            Issue.record("f1_score_cases missing or empty in scorer_vectors.json")
            return
        }
        let tol = 1e-9
        for c in cases {
            let id         = c["id"]          as! String
            let prediction = c["prediction"]  as! String
            let gold       = c["gold"]        as! String
            let expected   = c["expected_f1"] as! Double
            let got = f1Score(prediction: prediction, goldAnswer: gold)
            #expect(abs(got - expected) <= tol,
                    "f1_score '\(id)': expected \(expected), got \(got)")
        }
    }

    // ── Golden pins ───────────────────────────────────────────────────────────

    /// Identical strings → F1 = 1.0.
    @Test("golden pin: f1Score(\"cat\", \"cat\") == 1.0")
    func goldenPinIdentical() {
        #expect(f1Score(prediction: "cat", goldAnswer: "cat") == 1.0)
    }

    /// Stemming unifies "dogs"→"dog" and "running"→"run":
    /// both Porter stems agree → F1 = 1.0.
    @Test("golden pin: f1Score(\"running dogs\", \"dog run\") == 1.0")
    func goldenPinStemMatch() {
        #expect(f1Score(prediction: "running dogs", goldAnswer: "dog run") == 1.0)
    }

    /// Disjoint token sets → F1 = 0.0.
    @Test("golden pin: f1Score(\"hello\", \"world\") == 0.0")
    func goldenPinNoOverlap() {
        #expect(f1Score(prediction: "hello", goldAnswer: "world") == 0.0)
    }

    /// Partial overlap: intersection = {world:1}, precision = 1/2, recall = 1/1,
    /// F1 = 2*(1/2)*1/(1/2 + 1) = 2/3.
    @Test("golden pin: f1Score(\"hello world\", \"world\") ≈ 2/3")
    func goldenPinPartialOverlap() {
        let got = f1Score(prediction: "hello world", goldAnswer: "world")
        #expect(abs(got - 2.0 / 3.0) <= 1e-9,
                "expected 2/3 ≈ \(2.0/3.0), got \(got)")
    }
}

// MARK: - §2 multiAnswerF1 — conformance vectors

@Suite("LoCoMoSpecScorer — §2 multiAnswerF1 vectors")
struct LoCoMoSpecScorerMultiAnswerTests {

    @Test("multiAnswerF1: all vectors in scorer_vectors.json pass")
    func multiAnswerF1Vectors() throws {
        let vectors = try loadVectors()
        guard let cases = vectors["multi_answer_f1_cases"] as? [[String: Any]], !cases.isEmpty else {
            Issue.record("multi_answer_f1_cases missing or empty in scorer_vectors.json")
            return
        }
        let tol = 1e-9
        for c in cases {
            let id         = c["id"]         as! String
            let prediction = c["prediction"] as! String
            let gold       = c["gold"]       as! String
            let expected   = c["expected"]   as! Double
            let got = multiAnswerF1(prediction: prediction, goldAnswer: gold)
            #expect(abs(got - expected) <= tol,
                    "multi_answer_f1 '\(id)': expected \(expected), got \(got)")
        }
    }

    // ── Golden pin ────────────────────────────────────────────────────────────

    /// gold "cat": max(f1("cat","cat"), f1("dog","cat")) = 1.0
    /// gold "feline": max(f1("cat","feline"), f1("dog","feline")) ≈ 0.0
    /// mean = 0.5
    @Test("golden pin: multiAnswerF1(\"cat, dog\", \"cat, feline\") == 0.5")
    func goldenPinPartial() {
        let got = multiAnswerF1(prediction: "cat, dog", goldAnswer: "cat, feline")
        #expect(abs(got - 0.5) <= 1e-9, "expected 0.5, got \(got)")
    }
}

// MARK: - §3 scoreQuestion — conformance vectors + cat-5 golden pin

@Suite("LoCoMoSpecScorer — §3 scoreQuestion vectors")
struct LoCoMoSpecScorerScoreQuestionTests {

    @Test("scoreQuestion: all vectors in scorer_vectors.json pass")
    func scoreQuestionVectors() throws {
        let vectors = try loadVectors()
        guard let cases = vectors["score_question_cases"] as? [[String: Any]], !cases.isEmpty else {
            Issue.record("score_question_cases missing or empty in scorer_vectors.json")
            return
        }
        let tol = 1e-9
        for c in cases {
            let id         = c["id"]         as! String
            let category   = c["category"]   as! Int
            let prediction = c["prediction"] as! String
            let gold       = c["gold"]       as! String
            let expected   = c["expected"]   as! Double
            let got = try scoreQuestion(category: category, prediction: prediction, goldAnswer: gold)
            #expect(abs(got - expected) <= tol,
                    "score_question '\(id)': expected \(expected), got \(got)")
        }
    }

    // ── Cat-5 binary rule golden pins ─────────────────────────────────────────
    // §3: 1 iff prediction contains "no information available" or "not mentioned"
    // (case-insensitive). Same literals asserted in the Rust twin.

    /// "no information available" (mixed case) → 1.0.
    @Test("golden pin: cat-5 abstention 'No information available' → 1.0")
    func goldenPinCat5Abstain_noInfoAvailable() throws {
        let score = try scoreQuestion(
            category: 5,
            prediction: "No information available here.",
            goldAnswer: "anything"
        )
        #expect(score == 1.0, "cat-5 must return 1.0 when prediction contains 'no information available'")
    }

    /// "not mentioned" → 1.0.
    @Test("golden pin: cat-5 abstention 'not mentioned' → 1.0")
    func goldenPinCat5Abstain_notMentioned() throws {
        let score = try scoreQuestion(
            category: 5,
            prediction: "This topic is not mentioned in the conversation.",
            goldAnswer: "anything"
        )
        #expect(score == 1.0, "cat-5 must return 1.0 when prediction contains 'not mentioned'")
    }

    /// Neither phrase present → 0.0.
    @Test("golden pin: cat-5 no abstention phrase → 0.0")
    func goldenPinCat5NoAbstain() throws {
        let score = try scoreQuestion(
            category: 5,
            prediction: "The answer is 42.",
            goldAnswer: "anything"
        )
        #expect(score == 0.0, "cat-5 must return 0.0 when no abstention phrase present")
    }
}

// MARK: - §4 evidenceRecall — conformance vectors

@Suite("LoCoMoSpecScorer — §4 evidenceRecall vectors")
struct LoCoMoSpecScorerEvidenceRecallTests {

    @Test("evidenceRecall: all vectors in scorer_vectors.json pass")
    func evidenceRecallVectors() throws {
        let vectors = try loadVectors()
        guard let cases = vectors["evidence_recall_cases"] as? [[String: Any]], !cases.isEmpty else {
            Issue.record("evidence_recall_cases missing or empty in scorer_vectors.json")
            return
        }
        let tol = 1e-9
        for c in cases {
            let id       = c["id"]       as! String
            let expected = c["expected"] as! Double
            let evidence = c["evidence"] as! [String]
            // context may be null (nil) or an array.
            let context: [String]?
            if let arr = c["context"] as? [String] {
                context = arr
            } else {
                context = nil
            }
            let got = evidenceRecall(context: context, evidence: evidence)
            #expect(abs(got - expected) <= tol,
                    "evidence_recall '\(id)': expected \(expected), got \(got)")
        }
    }

    // ── Golden pins for both evidence forms ───────────────────────────────────
    // §4: session form (context starts with 'S') vs dia form.
    // Same literals asserted in Rust twin.

    /// No context field → recall 1.0 per §4.
    @Test("golden pin: evidenceRecall(context: nil, evidence: [\"D1:1\"]) == 1.0")
    func goldenPinNoContext() {
        #expect(evidenceRecall(context: nil, evidence: ["D1:1"]) == 1.0)
    }

    /// Session form: ["S3","S1"] — evidence "D3:5" (session 3) and "D1:2" (session 1)
    /// → both matched → recall 1.0. §4: ev.split(':')[0][1:] extracts session number.
    @Test("golden pin: session-form evidenceRecall full match == 1.0")
    func goldenPinSessionFormFull() {
        let got = evidenceRecall(context: ["S3", "S1"], evidence: ["D3:5", "D1:2"])
        #expect(got == 1.0, "session form: both sessions present → recall 1.0")
    }

    /// Session form: ["S3"] — "D3:5" matched, "D1:2" not matched → recall 0.5.
    @Test("golden pin: session-form evidenceRecall half match == 0.5")
    func goldenPinSessionFormHalf() {
        let got = evidenceRecall(context: ["S3"], evidence: ["D3:5", "D1:2"])
        #expect(abs(got - 0.5) <= 1e-9, "session form: only session 3 present → recall 0.5")
    }

    /// Dia form: ["D3:5","D1:2"] — "D3:5" present, "D1:2" not → recall 0.5.
    /// §4: context entries not starting with 'S' → direct membership check.
    @Test("golden pin: dia-form evidenceRecall half match == 0.5")
    func goldenPinDiaFormHalf() {
        let got = evidenceRecall(context: ["D3:5", "D2:1"], evidence: ["D3:5", "D1:2"])
        #expect(abs(got - 0.5) <= 1e-9, "dia form: only 'D3:5' in context → recall 0.5")
    }

    /// Dia form: both evidence items present → recall 1.0.
    @Test("golden pin: dia-form evidenceRecall full match == 1.0")
    func goldenPinDiaFormFull() {
        let got = evidenceRecall(context: ["D3:5", "D1:2"], evidence: ["D3:5", "D1:2"])
        #expect(got == 1.0, "dia form: both present → recall 1.0")
    }
}

// MARK: - §5 loCoMoSpecAggregate — conformance vectors

@Suite("LoCoMoSpecScorer — §5 aggregate vectors")
struct LoCoMoSpecScorerAggregateTests {

    @Test("loCoMoSpecAggregate: all vectors in scorer_vectors.json pass")
    func aggregateVectors() throws {
        let vectors = try loadVectors()
        guard let cases = vectors["aggregate_cases"] as? [[String: Any]], !cases.isEmpty else {
            Issue.record("aggregate_cases missing or empty in scorer_vectors.json")
            return
        }
        let tol = 1e-9
        for c in cases {
            let id       = c["id"]       as! String
            let rawScores = c["scores"]  as! [[String: Any]]
            let expected = c["expected"] as! [String: Any]

            let scores: [(category: Int, score: Double, evidenceRecall: Double)] = rawScores.map {
                (category: $0["category"] as! Int,
                 score:    $0["score"]    as! Double,
                 evidenceRecall: $0["recall"] as! Double)
            }
            let result = loCoMoSpecAggregate(scores: scores)

            let expOverall = expected["overall"] as! Double
            #expect(abs(result.overall - expOverall) <= tol,
                    "aggregate '\(id)' overall: expected \(expOverall), got \(result.overall)")

            let expTotal = expected["total_questions"] as! Int
            #expect(result.totalQuestions == expTotal,
                    "aggregate '\(id)' total_questions: expected \(expTotal), got \(result.totalQuestions)")

            // §5: category order must be [4, 1, 2, 3, 5].
            let gotOrder = result.byCategory.map { $0.category }
            let expOrder = expected["by_category_order"] as! [Int]
            #expect(gotOrder == expOrder,
                    "aggregate '\(id)' category order: expected \(expOrder), got \(gotOrder)")

            // Per-category accuracy values.
            let expCatAccuracy = expected["category_accuracy"] as! [String: Double]
            for cm in result.byCategory {
                let key = "\(cm.category)"
                if let expAcc = expCatAccuracy[key] {
                    #expect(abs(cm.accuracy - expAcc) <= tol,
                            "aggregate '\(id)' cat-\(cm.category) accuracy: expected \(expAcc), got \(cm.accuracy)")
                }
            }
        }
    }

    @Test("category order is always [4, 1, 2, 3, 5] per §5")
    func categoryOrderIsCanonical() {
        // §5: "reported in category order [4, 1, 2, 3, 5]"
        let scores: [(category: Int, score: Double, evidenceRecall: Double)] = [
            (1, 1.0, 1.0), (2, 1.0, 1.0), (3, 1.0, 1.0), (4, 1.0, 1.0), (5, 1.0, 1.0)
        ]
        let result = loCoMoSpecAggregate(scores: scores)
        let order = result.byCategory.map { $0.category }
        #expect(order == [4, 1, 2, 3, 5], "§5 mandates category order [4,1,2,3,5]")
    }

    @Test("empty input → overall 0.0, 5 category buckets, all question counts 0")
    func emptyInputReturnsZeros() {
        let result = loCoMoSpecAggregate(scores: [])
        #expect(result.overall == 0.0)
        #expect(result.totalQuestions == 0)
        #expect(result.byCategory.count == 5, "5 category buckets always returned")
        for cm in result.byCategory {
            #expect(cm.questionCount == 0)
        }
    }
}
