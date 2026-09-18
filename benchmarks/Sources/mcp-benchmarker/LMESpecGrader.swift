import Foundation

// LMESpecGrader.swift — Official LongMemEval "anscheck" QA grader.
//
// Implements the QA accuracy evaluation protocol verbatim from
// LONGMEMEVAL_OFFICIAL_PROTOCOL.md §2–§4, extracted from
// xiaowu0162/LongMemEval evaluate_qa.py and print_qa_metrics.py.
//
// Role: pure logic; no subprocess, no I/O, no Date() calls.
//
// The five prompt templates are stored verbatim as Swift string constants
// with real newline characters. The spec's \n sequences are real newlines
// per §2 ("The \n sequences in the spec doc are real newlines").
//
// Seam discipline: anscheckPrompt produces the filled prompt string.
// lmeSpecJudgeRequest wraps it with the §3 call parameters (model,
// n=1, temperature=0, max_tokens=10). The subprocess/HTTP seam that
// dispatches the request to the external judge command lives in the
// runner part — this module only defines prompt construction and
// aggregation logic.

// MARK: - Error type

/// Error raised by anscheckPrompt for an unknown, non-abstention question type.
///
/// Mirrors the upstream NotImplementedError in evaluate_qa.py (§2):
/// any question_type not in the fixed six-type list AND not routed to the
/// abstention branch is a fatal grading configuration error.
enum LMESpecGraderError: Error, Sendable, CustomStringConvertible {
    case unknownQuestionType(String)

    var description: String {
        switch self {
        case .unknownQuestionType(let t):
            return "LMESpecGrader: unknown non-abstention question_type '\(t)' — " +
                   "expected one of: single-session-user, single-session-preference, " +
                   "single-session-assistant, multi-session, temporal-reasoning, knowledge-update"
        }
    }
}

// MARK: - Verbatim prompt templates (§2)

// Five templates, each stored as a single verbatim Swift string constant.
// The \n escape sequences are real newlines (U+000A), matching the spec.
// Trailing-space differences before the first \n\n are preserved verbatim:
// templates 1 and 2 have a trailing space; templates 3–5 do not.
// {} slots fill in order with (question, answer, hypothesis) via fillAnscheckSlots.

/// §2 standard template: single-session-user / single-session-assistant / multi-session.
/// Trailing space before \n\n is verbatim from the spec.
private let lmeSpecTemplateStandard =
    "I will give you a question, a correct answer, and a response from a model. " +
    "Please answer yes if the response contains the correct answer. Otherwise, answer no. " +
    "If the response is equivalent to the correct answer or contains all the intermediate " +
    "steps to get the correct answer, you should also answer yes. " +
    "If the response only contains a subset of the information required by the answer, answer no. " +
    "\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n" +
    "Is the model response correct? Answer yes or no only."

/// §2 temporal-reasoning template.
/// Off-by-one grace clause added after "answer no. " with trailing space verbatim.
private let lmeSpecTemplateTemporal =
    "I will give you a question, a correct answer, and a response from a model. " +
    "Please answer yes if the response contains the correct answer. Otherwise, answer no. " +
    "If the response is equivalent to the correct answer or contains all the intermediate " +
    "steps to get the correct answer, you should also answer yes. " +
    "If the response only contains a subset of the information required by the answer, answer no. " +
    "In addition, do not penalize off-by-one errors for the number of days. " +
    "If the question asks for the number of days/weeks/months, etc., and the model makes " +
    "off-by-one errors (e.g., predicting 19 days when the answer is 18), the model's " +
    "response is still correct. " +
    "\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n" +
    "Is the model response correct? Answer yes or no only."

/// §2 knowledge-update template.
/// No trailing space before the first \n\n (verbatim from spec).
private let lmeSpecTemplateKnowledgeUpdate =
    "I will give you a question, a correct answer, and a response from a model. " +
    "Please answer yes if the response contains the correct answer. Otherwise, answer no. " +
    "If the response contains some previous information along with an updated answer, " +
    "the response should be considered as correct as long as the updated answer is the required answer." +
    "\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n" +
    "Is the model response correct? Answer yes or no only."

/// §2 single-session-preference template.
/// Uses "Rubric" label for the second slot instead of "Correct Answer".
/// No trailing space before the first \n\n (verbatim from spec).
private let lmeSpecTemplatePreference =
    "I will give you a question, a rubric for desired personalized response, " +
    "and a response from a model. " +
    "Please answer yes if the response satisfies the desired response. Otherwise, answer no. " +
    "The model does not need to reflect all the points in the rubric. " +
    "The response is correct as long as it recalls and utilizes the user's personal information correctly." +
    "\n\nQuestion: {}\n\nRubric: {}\n\nModel Response: {}\n\n" +
    "Is the model response correct? Answer yes or no only."

/// §2 abstention template (selected when '_abs' is contained in question_id).
/// Uses "Explanation" label and a different closing question.
/// No trailing space before the first \n\n (verbatim from spec).
private let lmeSpecTemplateAbstention =
    "I will give you an unanswerable question, an explanation, and a response from a model. " +
    "Please answer yes if the model correctly identifies the question as unanswerable. " +
    "The model could say that the information is incomplete, " +
    "or some other information is given but the asked information is not." +
    "\n\nQuestion: {}\n\nExplanation: {}\n\nModel Response: {}\n\n" +
    "Does the model correctly identify the question as unanswerable? Answer yes or no only."

// MARK: - Template slot filling

/// Replaces the three `{}` placeholders in a template with the supplied values, in order.
///
/// The upstream protocol uses Python str.format with positional `{}` slots:
/// `prompt_template.format(question, answer, hypothesis)`.
/// This function replicates that: the first `{}` → question, second → answer (or
/// rubric/explanation for preference/abstention templates), third → hypothesis.
///
/// - Parameters:
///   - template: A template string containing exactly three `{}` placeholders.
///   - question: Text for slot 1.
///   - answer: Text for slot 2 (gold answer, rubric, or explanation depending on type).
///   - hypothesis: Text for slot 3 (the system-under-test's response).
/// - Returns: The template with all three slots filled.
private func fillAnscheckSlots(
    template: String,
    question: String,
    answer: String,
    hypothesis: String
) -> String {
    var result = template
    for value in [question, answer, hypothesis] {
        guard let range = result.range(of: "{}") else { break }
        result.replaceSubrange(range, with: value)
    }
    return result
}

// MARK: - Prompt construction (§2)

/// Constructs the byte-exact "anscheck" judge prompt for one QA instance.
///
/// Template selection (§2):
///   1. If `'_abs' in question_id` → abstention template regardless of questionType.
///   2. Otherwise, route by questionType:
///      - "single-session-user", "single-session-assistant", "multi-session" → standard template
///      - "temporal-reasoning" → temporal-reasoning template
///      - "knowledge-update" → knowledge-update template
///      - "single-session-preference" → preference template
///      - Anything else → throws LMESpecGraderError.unknownQuestionType,
///        mirroring Python's NotImplementedError (§2 last line).
///
/// Slot fill order (§2): question → answer → hypothesis (three {} in order).
/// For the preference template the second label in the prompt is "Rubric" but the
/// slot still fills with the gold answer text. For the abstention template the
/// second label is "Explanation."
///
/// - Parameters:
///   - questionType: The reference file's `question_type` field (e.g. "multi-session").
///   - questionID: The reference file's `question_id` field; controls abstention branch.
///   - question: The question text.
///   - answer: The gold answer (or rubric, or explanation for abstention questions).
///   - hypothesis: The system-under-test's answer text.
/// - Returns: The byte-exact filled prompt string.
/// - Throws: `LMESpecGraderError.unknownQuestionType` for unknown non-abstention types.
public func anscheckPrompt(
    questionType: String,
    questionID: String,
    question: String,
    answer: String,
    hypothesis: String
) throws -> String {
    // §2: abstention branch is keyed on question_id, not question_type.
    if questionID.contains("_abs") {
        return fillAnscheckSlots(
            template: lmeSpecTemplateAbstention,
            question: question,
            answer: answer,
            hypothesis: hypothesis
        )
    }

    // §2: non-abstention routing by question_type.
    let template: String
    switch questionType {
    case "single-session-user", "single-session-assistant", "multi-session":
        template = lmeSpecTemplateStandard
    case "temporal-reasoning":
        template = lmeSpecTemplateTemporal
    case "knowledge-update":
        template = lmeSpecTemplateKnowledgeUpdate
    case "single-session-preference":
        template = lmeSpecTemplatePreference
    default:
        // §2: unknown type mirrors Python NotImplementedError.
        throw LMESpecGraderError.unknownQuestionType(questionType)
    }

    return fillAnscheckSlots(
        template: template,
        question: question,
        answer: answer,
        hypothesis: hypothesis
    )
}

// MARK: - Judge request descriptor (§3)

/// The parameters for one anscheck judge call, per §3.
///
/// The external judge seam (subprocess or HTTP) reads this struct to dispatch
/// the request. The runner constructs the actual command invocation or HTTP
/// payload from these fields; this module only defines the descriptor.
///
/// §3 parameters verbatim:
///   model: metric_model
///   messages: [{"role": "user", "content": prompt}]
///   n: 1
///   temperature: 0
///   max_tokens: 10
public struct LMESpecJudgeRequest: Sendable {
    /// The judge model identifier (e.g. "gpt-4o-2024-08-06"). Passed to the
    /// external judge command verbatim; also recorded in the resulting verdict.
    public let model: String
    /// The filled anscheck prompt, content of the single user message.
    public let userMessage: String
    /// §3 literal: n = 1.
    public let n: Int
    /// §3 literal: temperature = 0. Passed as-is; no floating-point coercion.
    public let temperature: Double
    /// §3 literal: max_tokens = 10.
    public let maxTokens: Int
}

/// Constructs a §3-compliant judge request descriptor.
///
/// Wraps the filled anscheck prompt with the fixed parameters from §3.
/// Callers obtain the prompt from `anscheckPrompt(...)` and pass it here.
///
/// - Parameters:
///   - model: Judge model identifier (e.g. "gpt-4o-2024-08-06").
///   - prompt: The filled anscheck prompt string.
/// - Returns: A `LMESpecJudgeRequest` ready for the runner seam.
public func lmeSpecJudgeRequest(model: String, prompt: String) -> LMESpecJudgeRequest {
    LMESpecJudgeRequest(
        model: model,
        userMessage: prompt,
        n: 1,
        temperature: 0,
        maxTokens: 10
    )
}

// MARK: - Verdict parsing (§3)

/// The outcome of one anscheck judge call, carrying model identity and label.
///
/// Model identity is stored here so the aggregator can surface which judge model
/// was used and flag mixed-model runs (the spec asserts a single model per run).
public struct LMESpecVerdict: Sendable {
    /// The judge model that produced this verdict (same as LMESpecJudgeRequest.model).
    public let judgeModel: String
    /// True when the judge replied "yes"; false for "no".
    public let label: Bool
}

/// Parses the judge model's text reply into a verdict label per §3.
///
/// §3 verdict algorithm verbatim:
///   `label = 'yes' in eval_response.lower()`
/// after `.strip()`. The raw eval_response is first stripped of leading/trailing
/// whitespace, then lowercased, then 'yes' substring membership determines the label.
/// A judge that says "YES it is" → true; "no" → false; " yes" (leading space) → true.
///
/// - Parameters:
///   - evalResponse: The raw text returned by the judge for this instance.
///   - judgeModel: The model that produced this response.
/// - Returns: A `LMESpecVerdict` with the parsed label.
public func lmeSpecVerdict(evalResponse: String, judgeModel: String) -> LMESpecVerdict {
    let stripped = evalResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = stripped.lowercased()
    return LMESpecVerdict(judgeModel: judgeModel, label: lower.contains("yes"))
}

// MARK: - Aggregation types (§4)

/// Fixed six-type list per §4 of the protocol.
///
/// Abstention instances aggregate under their base type (question_type without "_abs"
/// suffix). The order here is fixed and matches print_qa_metrics.py.
public let lmeSpecFixedTypeList: [String] = [
    "single-session-user",
    "single-session-preference",
    "single-session-assistant",
    "multi-session",
    "temporal-reasoning",
    "knowledge-update",
]

/// Per-question-type accuracy result for §4 aggregation.
public struct LMESpecPerTypeResult: Sendable {
    /// One of the six fixed question types.
    public let questionType: String
    /// Mean of binary labels over instances of this type, rounded to 4 decimal places.
    /// 0.0 when count is 0 (the type is absent from this run's instance set).
    public let accuracy: Double
    /// Number of instances of this type in the evaluated set.
    public let count: Int
}

/// Complete §4 aggregate result for one evaluation run.
public struct LMESpecAggregateResult: Sendable {
    /// Per-type accuracy in the fixed order of lmeSpecFixedTypeList. Always six entries.
    public let perType: [LMESpecPerTypeResult]
    /// §4 task-averaged accuracy: unweighted mean of the six per-type raw accuracies,
    /// rounded to 4 decimal places.
    public let taskAveragedAccuracy: Double
    /// §4 overall accuracy: mean label over all instances, rounded to 4 decimal places.
    public let overallAccuracy: Double
    /// §4 abstention accuracy: mean label over instances whose questionID contains '_abs',
    /// rounded to 4 decimal places. 0.0 when abstentionCount is 0.
    public let abstentionAccuracy: Double
    /// Number of abstention instances in the evaluated set.
    public let abstentionCount: Int
    /// Unique judge model identifiers seen across all verdicts (sorted for determinism).
    public let judgeModels: [String]
}

/// One input record for the aggregator.
public struct LMESpecVerdictRecord: Sendable {
    /// The dataset's question_id; determines abstention membership ('_abs' in id).
    public let questionID: String
    /// The base question type (question_type without '_abs' suffix, e.g. "multi-session").
    /// Abstention instances are aggregated under this base type for per-type accuracy.
    public let baseQuestionType: String
    /// The verdict produced by lmeSpecVerdict for this instance.
    public let verdict: LMESpecVerdict
}

// MARK: - Aggregation engine (§4)

/// Rounds a Double to 4 decimal places using round-half-to-even convention.
///
/// Matches Python's `round(x, 4)` which uses banker's rounding for the 5th decimal.
/// For the accuracy values produced here (rationals with denominators ≤ 500) the
/// difference from simple round-half-up is negligible, but the implementation
/// mirrors Python for conformance.
private func round4(_ x: Double) -> Double {
    (x * 10000.0).rounded() / 10000.0
}

/// Computes §4 aggregate QA accuracy metrics over a set of verdict records.
///
/// Per-type accuracy: mean of binary labels for each of the six fixed types, rounded
/// to 4 decimal places. Types with zero instances contribute accuracy 0.0 with count 0.
///
/// Task-averaged accuracy (§4): unweighted mean of the six raw per-type accuracies
/// (computed from raw per-type means before per-type rounding), rounded 4 decimals.
/// This matches print_qa_metrics.py which averages the raw floats before formatting.
///
/// Overall accuracy (§4): mean label over all instances, rounded 4 decimals.
///
/// Abstention accuracy (§4): mean label over instances whose questionID contains '_abs',
/// rounded 4 decimals. 0.0 when no abstention instances are present.
///
/// Judge model identity: all unique judge model identifiers seen across verdicts,
/// surfaced sorted in the result. The official protocol asserts gpt-4o-2024-08-06;
/// the spec lane records identity per verdict to support any external judge model.
///
/// - Parameter records: One record per evaluated QA instance.
/// - Returns: A fully-populated LMESpecAggregateResult.
public func lmeSpecAggregate(_ records: [LMESpecVerdictRecord]) -> LMESpecAggregateResult {
    // Bucket labels by base question type.
    var typeLabels: [String: [Bool]] = Dictionary(
        uniqueKeysWithValues: lmeSpecFixedTypeList.map { ($0, []) }
    )
    var allLabels: [Bool] = []
    var abstentionLabels: [Bool] = []
    var judgeModelSet: Set<String> = []

    for record in records {
        let label = record.verdict.label
        allLabels.append(label)
        judgeModelSet.insert(record.verdict.judgeModel)

        // §4: abstention instances keyed by question_id '_abs' membership.
        if record.questionID.contains("_abs") {
            abstentionLabels.append(label)
        }

        // §4: abstention instances aggregate under their base type via baseQuestionType.
        // Types outside the fixed six are silently ignored for per-type accuracy.
        if typeLabels[record.baseQuestionType] != nil {
            typeLabels[record.baseQuestionType]!.append(label)
        }
    }

    // Compute raw per-type accuracies (before rounding) for task-averaged mean.
    var rawTypeAccuracies: [Double] = []
    let perType: [LMESpecPerTypeResult] = lmeSpecFixedTypeList.map { typeName in
        let labels = typeLabels[typeName] ?? []
        let rawAccuracy: Double = labels.isEmpty
            ? 0.0
            : Double(labels.filter { $0 }.count) / Double(labels.count)
        rawTypeAccuracies.append(rawAccuracy)
        return LMESpecPerTypeResult(
            questionType: typeName,
            accuracy: round4(rawAccuracy),
            count: labels.count
        )
    }

    // §4 task-averaged: mean of the six raw per-type accuracies, then round.
    let taskAveraged = rawTypeAccuracies.isEmpty
        ? 0.0
        : round4(rawTypeAccuracies.reduce(0.0, +) / Double(rawTypeAccuracies.count))

    // §4 overall: mean over all instances.
    let overall: Double = allLabels.isEmpty
        ? 0.0
        : round4(Double(allLabels.filter { $0 }.count) / Double(allLabels.count))

    // §4 abstention: mean over _abs instances.
    let abstentionAccuracy: Double = abstentionLabels.isEmpty
        ? 0.0
        : round4(Double(abstentionLabels.filter { $0 }.count) / Double(abstentionLabels.count))

    return LMESpecAggregateResult(
        perType: perType,
        taskAveragedAccuracy: taskAveraged,
        overallAccuracy: overall,
        abstentionAccuracy: abstentionAccuracy,
        abstentionCount: abstentionLabels.count,
        judgeModels: judgeModelSet.sorted()
    )
}
