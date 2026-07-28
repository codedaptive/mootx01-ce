import Foundation

// LongMemEvalCorpus.swift — Loads and validates the LongMemEval dataset.
//
// Schema verified 2026-07-25 against xiaowu0162/longmemeval-cleaned on HuggingFace.
// The dataset is never committed; see scripts/fetch-longmemeval.sh to download.
//
// Field layout (per-question JSON object):
//   question_id:          String   — unique ID (e.g. "gpt4_2655b836")
//   question_type:        String   — one of: "knowledge-update", "multi-session",
//                                     "single-session-assistant", "single-session-preference",
//                                     "single-session-user", "temporal-reasoning".
//                                     Abstention variants end in "_abs" (e.g. "multi-session_abs").
//   question:             String   — the question text
//   answer:               String or Number — reference answer (for LLM-judge QA, not used here).
//                         The oracle variant has 32 questions with integer answers (e.g. count: 3).
//                         Both types are decoded as String (verified 2026-07-25).
//   question_date:        String   — date/time string (not ISO8601; e.g. "2023/04/10 (Mon) 23:07")
//   haystack_dates:       [String] — one date string per haystack session
//   haystack_session_ids: [String] — session IDs in haystack order
//   haystack_sessions:    [[Turn]] — list of sessions, each session a list of turns
//   answer_session_ids:   [String] — session IDs that contain evidence for the answer
//
// Turn fields: { role: String, content: String, has_answer: Bool }
//
// Abstention questions (question_type ending "_abs") are EXCLUDED from retrieval scoring
// per upstream methodology. LongMemEvalCorpus.load returns only non-abstention questions;
// the exclusion count is reported in `abstentionCount`.

/// One turn in a haystack session.
struct LMETurn: Codable, Sendable {
    /// Speaker role: "user" or "assistant".
    let role: String
    /// Turn content.
    let content: String
    /// True when this turn contains evidence for the answer. Used to verify
    /// the manifest correlation after ingest.
    /// Absent in the real HuggingFace corpus (only in hand-authored synthetic
    /// test sample) — defaults to false when missing.
    let hasAnswer: Bool

    enum CodingKeys: String, CodingKey {
        case role, content
        case hasAnswer = "has_answer"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        hasAnswer = try container.decodeIfPresent(Bool.self, forKey: .hasAnswer) ?? false
    }
}

/// One question from the LongMemEval dataset.
struct LMEQuestion: Sendable {
    /// Unique question identifier.
    let questionID: String
    /// Question type. Abstention types end in "_abs" (excluded from scoring).
    let questionType: String
    /// The question text.
    let question: String
    /// Reference answer (for LLM-judge QA).
    let answer: String
    /// Question date string (dataset format: "2023/04/10 (Mon) 23:07").
    let questionDate: String
    /// One date string per haystack session, parallel to haystackSessionIDs.
    let haystackDates: [String]
    /// Session IDs in haystack order, parallel to haystackSessions.
    let haystackSessionIDs: [String]
    /// Haystack sessions. haystackSessions[i] is a list of turns for session i.
    let haystackSessions: [[LMETurn]]
    /// Session IDs that contain evidence for the answer (ground truth for recall scoring).
    let answerSessionIDs: [String]
}

/// Loader error carrying the missing/mistyped field name and the zero-based question index.
struct LMELoadError: Error, CustomStringConvertible {
    let description: String
}

/// The result of a successful load: the non-abstention questions and counts.
struct LMECorpus: Sendable {
    /// Non-abstention questions, in dataset order (possibly shuffled by the runner's seed).
    let questions: [LMEQuestion]
    /// Number of abstention questions excluded from this corpus.
    let abstentionCount: Int
    /// Total questions in the source JSON (questions.count + abstentionCount).
    var totalCount: Int { questions.count + abstentionCount }
}

/// Codec for the raw per-question JSON representation.
///
/// Schema note: `answer` is usually a String but some oracle-variant questions
/// carry a numeric answer (e.g. a count: `3`). The field is not used in
/// retrieval scoring, so it is decoded as a string with numeric coercion to
/// avoid a decode failure on those questions.
private struct LMEQuestionRaw: Decodable {
    let questionID: String
    let questionType: String
    let question: String
    /// Answer decoded as String regardless of JSON type (String or numeric).
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
        self.questionID     = try c.decode(String.self,   forKey: .questionID)
        self.questionType   = try c.decode(String.self,   forKey: .questionType)
        self.question       = try c.decode(String.self,   forKey: .question)
        self.questionDate   = try c.decode(String.self,   forKey: .questionDate)
        self.haystackDates  = try c.decode([String].self, forKey: .haystackDates)
        self.haystackSessionIDs = try c.decode([String].self, forKey: .haystackSessionIDs)
        self.haystackSessions   = try c.decode([[LMETurn]].self, forKey: .haystackSessions)
        self.answerSessionIDs   = try c.decode([String].self, forKey: .answerSessionIDs)
        // `answer` may be a String or a number (observed in oracle variant, verified 2026-07-25).
        // Normalise both to String; the field is unused in retrieval scoring.
        if let s = try? c.decode(String.self, forKey: .answer) {
            self.answer = s
        } else if let n = try? c.decode(Int.self, forKey: .answer) {
            self.answer = String(n)
        } else if let d = try? c.decode(Double.self, forKey: .answer) {
            self.answer = String(d)
        } else {
            // Absent or null — acceptable for oracle variant questions.
            self.answer = ""
        }
    }
}

/// Loads a LongMemEval variant JSON file, validates the schema, and returns
/// the non-abstention questions plus statistics.
///
/// - Parameter url: Path to the JSON file (e.g. longmemeval_s_cleaned.json).
/// - Throws: `LMELoadError` naming the missing/mistyped field and the zero-based
///   question index, matching the style of `QualityCorpus.load`.
func loadLMECorpus(from url: URL) throws -> LMECorpus {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    let rawQuestions: [LMEQuestionRaw]
    do {
        rawQuestions = try decoder.decode([LMEQuestionRaw].self, from: data)
    } catch let decodingError {
        throw LMELoadError(
            description: "LongMemEval JSON decode failed at top level: \(decodingError)")
    }

    // Validate each question's structural invariants and partition abstentions.
    var questions: [LMEQuestion] = []
    var abstentionCount = 0

    for (index, raw) in rawQuestions.enumerated() {
        // Validate required non-empty fields.
        guard !raw.questionID.isEmpty else {
            throw LMELoadError(
                description: "question[\(index)]: missing/empty 'question_id'")
        }
        guard !raw.questionType.isEmpty else {
            throw LMELoadError(
                description: "question[\(index)]: missing/empty 'question_type'")
        }
        guard !raw.question.isEmpty else {
            throw LMELoadError(
                description: "question[\(index)] id='\(raw.questionID)': missing/empty 'question'")
        }
        // Validate parallel arrays: haystackSessionIDs and haystackSessions must have the same length.
        guard raw.haystackSessionIDs.count == raw.haystackSessions.count else {
            throw LMELoadError(
                description: "question[\(index)] id='\(raw.questionID)': " +
                "'haystack_session_ids' count (\(raw.haystackSessionIDs.count)) " +
                "!= 'haystack_sessions' count (\(raw.haystackSessions.count))")
        }
        // Validate parallel arrays: haystackDates must have the same length as haystackSessionIDs.
        guard raw.haystackDates.count == raw.haystackSessionIDs.count else {
            throw LMELoadError(
                description: "question[\(index)] id='\(raw.questionID)': " +
                "'haystack_dates' count (\(raw.haystackDates.count)) " +
                "!= 'haystack_session_ids' count (\(raw.haystackSessionIDs.count))")
        }
        // answerSessionIDs may be empty (valid for some question types) but must not
        // be missing (it IS present in the JSON, even if empty).

        // Exclude abstention questions per upstream methodology.
        if raw.questionType.hasSuffix("_abs") {
            abstentionCount += 1
            continue
        }

        questions.append(LMEQuestion(
            questionID: raw.questionID,
            questionType: raw.questionType,
            question: raw.question,
            answer: raw.answer,
            questionDate: raw.questionDate,
            haystackDates: raw.haystackDates,
            haystackSessionIDs: raw.haystackSessionIDs,
            haystackSessions: raw.haystackSessions,
            answerSessionIDs: raw.answerSessionIDs
        ))
    }

    return LMECorpus(questions: questions, abstentionCount: abstentionCount)
}
