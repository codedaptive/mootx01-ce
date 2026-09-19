import Foundation

// LMESpecCorpus.swift — Spec-compliant LongMemEval corpus loader for the lme-spec lane.
//
// Dataset: xiaowu0162/LongMemEval (ICLR 2025, arXiv 2410.10813).
// Schema verified 2026-08-18 against longmemeval_m_cleaned.json (500 instances).
//
// KEY DIFFERENCES from LongMemEvalCorpus.swift (deviations addressed per
// LONGMEMEVAL_OFFICIAL_PROTOCOL.md §6 row 2):
//
//   1. ALL 500 instances are included — no filtering at load time.
//      Per §1: "Abstention questions ... ARE evaluated for QA accuracy (with
//      the abstention prompt). They are skipped only in retrieval metrics."
//      The original LongMemEvalCorpus.swift excluded '_abs' types at load time.
//
//   2. isAbstention uses the spec selector (§2): '_abs' in question_id.
//      In longmemeval_m_cleaned.json, abstention markers appear only in
//      question_id; question_type never ends in '_abs' in the real dataset.
//      The original loader checked question_type, which matched zero instances.
//
//   3. baseQuestionType strips any trailing '_abs' from question_type, mapping
//      onto the fixed six-type list in §4:
//        ["single-session-user", "single-session-preference",
//         "single-session-assistant", "multi-session",
//         "temporal-reasoning", "knowledge-update"]
//
// Verified counts on longmemeval_m_cleaned.json (2026-08-18):
//   Total:                      500
//   Abstention (qid has _abs):   30    ← isAbstention == true
//   Non-abstention:             470
//   Per base type (abstentions aggregate under their base type):
//     knowledge-update:          78
//     multi-session:            133
//     single-session-assistant:  56
//     single-session-preference: 30
//     single-session-user:       70
//     temporal-reasoning:       133

// MARK: - Question

/// One question from the LongMemEval dataset, loaded in spec-compliant mode.
///
/// All stored fields are identical to LMEQuestion from LongMemEvalCorpus.swift.
/// The spec-specific additions are the `isAbstention` and `baseQuestionType`
/// computed properties, which implement §2 and §4 of
/// LONGMEMEVAL_OFFICIAL_PROTOCOL.md.
struct LMESpecQuestion: Sendable {
    /// Unique question identifier (e.g. "gpt4_2655b836" or "gpt4_ab12cd34_abs").
    let questionID: String
    /// Raw question_type from JSON (e.g. "multi-session").
    /// In longmemeval_m_cleaned.json this is never suffixed with "_abs"; the
    /// suffix may appear in synthetic fixtures or future dataset variants.
    let questionType: String
    /// The question text.
    let question: String
    /// Reference answer string.
    /// For single-session-preference: the rubric for desired personalised response.
    /// For abstention questions: the explanation of why the question is unanswerable.
    /// Normalised to String (numeric oracle-variant answers are coerced, matching
    /// the LMEQuestionRaw decoder in LongMemEvalCorpus.swift).
    let answer: String
    /// Question date string (dataset format: "2023/04/10 (Mon) 23:07").
    let questionDate: String
    /// One date string per haystack session, parallel to haystackSessionIDs.
    let haystackDates: [String]
    /// Session IDs in haystack order, parallel to haystackSessions.
    let haystackSessionIDs: [String]
    /// Haystack sessions. haystackSessions[i] is the turn list for session i.
    let haystackSessions: [[LMETurn]]
    /// Session IDs containing evidence for the answer (ground truth for recall
    /// scoring). Empty for abstention questions (no ground-truth location).
    let answerSessionIDs: [String]

    /// True when '_abs' appears anywhere in questionID.
    ///
    /// Per LONGMEMEVAL_OFFICIAL_PROTOCOL.md §2:
    ///   "abstention = '_abs' in question_id"
    ///
    /// Abstention instances:
    ///   - Are judged with the abstention prompt (§2 abstention block).
    ///   - Are counted separately in §4 aggregation (abstention accuracy).
    ///   - Are excluded from retrieval metrics (§5).
    ///   - Are NOT excluded from QA accuracy scoring (§1, §6 row 2 fix).
    var isAbstention: Bool {
        questionID.contains("_abs")
    }

    /// question_type with any trailing '_abs' suffix stripped.
    ///
    /// Maps onto the fixed six-type list from LONGMEMEVAL_OFFICIAL_PROTOCOL.md §4:
    ///   ["single-session-user", "single-session-preference",
    ///    "single-session-assistant", "multi-session",
    ///    "temporal-reasoning", "knowledge-update"]
    ///
    /// In longmemeval_m_cleaned.json, question_type never carries '_abs', so
    /// baseQuestionType == questionType for all 500 real instances. The strip
    /// exists for forward compatibility with dataset variants (and the synthetic
    /// test fixture) that carry '_abs' in question_type.
    var baseQuestionType: String {
        if questionType.hasSuffix("_abs") {
            return String(questionType.dropLast("_abs".count))
        }
        return questionType
    }
}

// MARK: - Corpus

/// The fixed six question-type labels from LONGMEMEVAL_OFFICIAL_PROTOCOL.md §4,
/// in the order they appear in the official aggregator.
let lmeSpecBaseTypes: [String] = [
    "single-session-user",
    "single-session-preference",
    "single-session-assistant",
    "multi-session",
    "temporal-reasoning",
    "knowledge-update"
]

/// The result of loading the LongMemEval dataset in spec-compliant mode.
///
/// All instances are in `questions` — abstention and non-abstention combined.
/// No filtering occurs at load time. Use `isAbstention` on each question to
/// identify abstention instances for judge-prompt selection (§2) and
/// retrieval-metric exclusion (§5).
struct LMESpecCorpus: Sendable {
    /// All questions in dataset order, abstention and non-abstention combined.
    let questions: [LMESpecQuestion]

    /// Count of questions where isAbstention == true.
    /// In longmemeval_m_cleaned.json: 30 out of 500.
    var abstentionCount: Int {
        questions.reduce(0) { $0 + ($1.isAbstention ? 1 : 0) }
    }

    /// Total question count. Always equals questions.count (no filtering).
    var totalCount: Int { questions.count }

    /// Counts per baseQuestionType across all 500 instances.
    ///
    /// Abstention instances aggregate under their base type, matching the
    /// §4 aggregation rule. For longmemeval_m_cleaned.json the expected map is:
    ///   { "knowledge-update": 78, "multi-session": 133,
    ///     "single-session-assistant": 56, "single-session-preference": 30,
    ///     "single-session-user": 70, "temporal-reasoning": 133 }
    func countsByBaseType() -> [String: Int] {
        var counts: [String: Int] = [:]
        for q in questions {
            counts[q.baseQuestionType, default: 0] += 1
        }
        return counts
    }
}

// MARK: - Load error

/// Loader error naming the missing/mistyped field and the zero-based question index.
/// Parallel to LMELoadError in LongMemEvalCorpus.swift and LoCoMoSpecLoadError
/// in LoCoMoSpecCorpus.swift.
struct LMESpecLoadError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Raw decoder

/// Codec for the raw per-question JSON.
///
/// Identical in schema to the private LMEQuestionRaw in LongMemEvalCorpus.swift.
/// It is redeclared here because LMEQuestionRaw is file-private. The spec corpus
/// differs from the original only in post-decode behaviour (no abstention filter).
///
/// answer is normalised from String | Int | Double | absent/null → String.
/// Numeric answers appear in the oracle dataset variant (e.g. a count: 3).
/// The answer field is unused in retrieval scoring; both loaders coerce it to
/// avoid a decode failure on those rows.
///
/// LMETurn and its CodingKeys are defined in LongMemEvalCorpus.swift and are
/// accessible here (same module, internal visibility).
private struct LMESpecQuestionRaw: Decodable {
    let questionID: String
    let questionType: String
    let question: String
    /// Normalised answer — see init(from:) for coercion logic.
    let answer: String
    let questionDate: String
    let haystackDates: [String]
    let haystackSessionIDs: [String]
    let haystackSessions: [[LMETurn]]
    let answerSessionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case questionID          = "question_id"
        case questionType        = "question_type"
        case question
        case answer
        case questionDate        = "question_date"
        case haystackDates       = "haystack_dates"
        case haystackSessionIDs  = "haystack_session_ids"
        case haystackSessions    = "haystack_sessions"
        case answerSessionIDs    = "answer_session_ids"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        questionID          = try c.decode(String.self,          forKey: .questionID)
        questionType        = try c.decode(String.self,          forKey: .questionType)
        question            = try c.decode(String.self,          forKey: .question)
        questionDate        = try c.decode(String.self,          forKey: .questionDate)
        haystackDates       = try c.decode([String].self,        forKey: .haystackDates)
        haystackSessionIDs  = try c.decode([String].self,        forKey: .haystackSessionIDs)
        haystackSessions    = try c.decode([[LMETurn]].self,     forKey: .haystackSessions)
        answerSessionIDs    = try c.decode([String].self,        forKey: .answerSessionIDs)
        // answer: String | Int | Double | absent/null → String.
        // Matches the coercion in LongMemEvalCorpus.swift LMEQuestionRaw.
        if let s = try? c.decode(String.self, forKey: .answer) {
            answer = s
        } else if let n = try? c.decode(Int.self, forKey: .answer) {
            answer = String(n)
        } else if let d = try? c.decode(Double.self, forKey: .answer) {
            answer = String(d)
        } else {
            answer = ""     // absent or null — acceptable for oracle-variant rows
        }
    }
}

// MARK: - Loader

/// Loads a LongMemEval variant JSON in spec-compliant mode: ALL instances,
/// including abstention questions (question_id contains '_abs').
///
/// Per LONGMEMEVAL_OFFICIAL_PROTOCOL.md §1 and §6 row 2:
///
///   Abstention questions ARE scored with the abstention judge prompt (§2).
///   They ARE included in overall and per-type QA accuracy (§4).
///   They are only excluded from retrieval metrics (§5).
///
/// This loader fixes the deviation in LongMemEvalCorpus.swift, which excluded
/// '_abs' instances by checking question_type.hasSuffix("_abs"). The correct
/// spec selector is '_abs' in question_id (computed via isAbstention).
///
/// - Parameter url: Path to the JSON file (e.g. longmemeval_m_cleaned.json).
/// - Returns: LMESpecCorpus with ALL questions in dataset order.
/// - Throws: LMESpecLoadError naming the offending field and the zero-based
///   question index. Parallel error style to loadLMECorpus and
///   loadLoCoMoSpecCorpus.
func loadLMESpecCorpus(from url: URL) throws -> LMESpecCorpus {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw LMESpecLoadError(
            description: "LMESpec: could not read '\(url.path)': \(error)")
    }

    let rawQuestions: [LMESpecQuestionRaw]
    do {
        rawQuestions = try JSONDecoder().decode([LMESpecQuestionRaw].self, from: data)
    } catch let decodingError {
        throw LMESpecLoadError(
            description: "LMESpec JSON decode failed at top level: \(decodingError)")
    }

    var questions: [LMESpecQuestion] = []
    questions.reserveCapacity(rawQuestions.count)

    for (index, raw) in rawQuestions.enumerated() {
        // Validate required non-empty fields (parallel to loadLMECorpus validation).
        guard !raw.questionID.isEmpty else {
            throw LMESpecLoadError(
                description: "question[\(index)]: missing/empty 'question_id'")
        }
        guard !raw.questionType.isEmpty else {
            throw LMESpecLoadError(
                description: "question[\(index)]: missing/empty 'question_type'")
        }
        guard !raw.question.isEmpty else {
            throw LMESpecLoadError(
                description: "question[\(index)] id='\(raw.questionID)': "
                + "missing/empty 'question'")
        }
        // Validate parallel array lengths.
        guard raw.haystackSessionIDs.count == raw.haystackSessions.count else {
            throw LMESpecLoadError(
                description: "question[\(index)] id='\(raw.questionID)': "
                + "'haystack_session_ids' count (\(raw.haystackSessionIDs.count)) "
                + "!= 'haystack_sessions' count (\(raw.haystackSessions.count))")
        }
        guard raw.haystackDates.count == raw.haystackSessionIDs.count else {
            throw LMESpecLoadError(
                description: "question[\(index)] id='\(raw.questionID)': "
                + "'haystack_dates' count (\(raw.haystackDates.count)) "
                + "!= 'haystack_session_ids' count (\(raw.haystackSessionIDs.count))")
        }

        // ALL instances are appended — no abstention filtering.
        // isAbstention and baseQuestionType are computed properties on LMESpecQuestion,
        // not stored state, so no decision is made here.
        questions.append(LMESpecQuestion(
            questionID:        raw.questionID,
            questionType:      raw.questionType,
            question:          raw.question,
            answer:            raw.answer,
            questionDate:      raw.questionDate,
            haystackDates:     raw.haystackDates,
            haystackSessionIDs: raw.haystackSessionIDs,
            haystackSessions:  raw.haystackSessions,
            answerSessionIDs:  raw.answerSessionIDs
        ))
    }

    return LMESpecCorpus(questions: questions)
}
