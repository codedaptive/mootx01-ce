import Foundation

// ConvoMemSpecProtocol.swift — Official ConvoMem answer + judge protocol.
//
// Implements §B1–§B4 of LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md verbatim, extracted
// from SalesforceAIResearch/ConvoMem (cm_EvaluationUtils.scala,
// cm_MemoryPromptUtils.scala, cm_AnsweringEvaluation.scala).
//
// Role: pure logic; no subprocess, no I/O, no Date() calls.
//
// All prompt template strings are transcribed byte-exact from the Scala sources.
// Explicit "\n" concatenation is used throughout to make every newline and
// trailing-space character unambiguous. The Scala triple-quoted string ends
// without a trailing newline (the closing """ is on the same line as the last
// character); every function here matches that contract — no trailing "\n".
//
// Seam discipline: every public function returns a String or a pure-value result.
// Subprocess dispatch, judge-model invocation, and retry orchestration live in
// the runner — this module owns only prompt construction, verdict parsing, and
// aggregation math.

// MARK: - §B1 — Answer generation input types

/// A single speaker turn in a conversation.
///
/// Maps to `Message` in the ConvoMem Scala harness (cm_EvaluationUtils.scala).
public struct ConvoMemMessage: Sendable, Equatable {
    /// Speaker label (e.g. "User" or "Assistant"). §B1: rendered as "{speaker}: {text}".
    public let speaker: String
    /// Turn text. §B1: rendered after the speaker label and ": ".
    public let text: String

    public init(speaker: String, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

/// A single conversation consisting of one or more ordered turns.
///
/// Maps to `Conversation` in the ConvoMem Scala harness.
public struct ConvoMemConversation: Sendable, Equatable {
    /// Ordered list of message turns.
    public let messages: [ConvoMemMessage]

    public init(messages: [ConvoMemMessage]) {
        self.messages = messages
    }
}

/// A single evidence message available to the model during user-facts evaluation.
///
/// Maps to the `Message.text` field in UserFactsAnsweringEvaluation (cm_AnsweringEvaluation.scala).
public struct ConvoMemEvidenceMessage: Sendable, Equatable {
    /// The evidence text. §B2 UserFacts: embedded verbatim in the judge prompt.
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

// MARK: - §B1 — buildConversationContext (EvaluationUtils.buildConversationContext)

/// Formats a list of conversations into the numbered context block used by modelAnswerPrompt.
///
/// §B1 (EvaluationUtils.buildConversationContext verbatim):
///   conversations.zipWithIndex → "Conversation N:\n{speaker}: {text}\n..." joined by "\n\n".
/// No trailing newline — the Scala source ends the string without one.
///
/// - Parameter conversations: Ordered list of conversations.
/// - Returns: The formatted conversation context string (no trailing newline).
public func convoMemBuildConversationContext(_ conversations: [ConvoMemConversation]) -> String {
    // §B1: 1-based numbering; turns joined by "\n"; conversations joined by "\n\n".
    return conversations.enumerated().map { (index, conversation) in
        let number = index + 1
        let turns = conversation.messages
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
        return "Conversation \(number):\n\(turns)"
    }.joined(separator: "\n\n")
}

// MARK: - §B1 — modelAnswerPrompt (EvaluationUtils.getModelAnswerPrompt)

/// Constructs the full-context answer-generation prompt.
///
/// §B1 (EvaluationUtils.getModelAnswerPrompt verbatim from cm_EvaluationUtils.scala).
/// No trailing newline — matches the Scala source which closes with `Answer:"""`.
///
/// - Parameters:
///   - conversations: Conversations to include as context (built via buildConversationContext).
///   - question: The question the model must answer.
/// - Returns: The byte-exact prompt string.
public func convoMemModelAnswerPrompt(
    conversations: [ConvoMemConversation],
    question: String
) -> String {
    let ctx = convoMemBuildConversationContext(conversations)
    // §B1 verbatim — Scala: s"""Answer the question...Answer:"""
    return
        "Answer the question based on the conversations below. If the User in the conversation refers to themselves (\"I\", \"me\", \"my\"), they are the person being asked about. Be direct and factual.\n" +
        "\n" +
        ctx + "\n" +
        "\n" +
        "Question: " + question + "\n" +
        "\n" +
        "Answer:"
}

// MARK: - §B1 — getJudgeEvaluationCriteria (MemoryPromptUtils.getJudgeEvaluationCriteria)

/// Returns the evaluation-criteria block embedded in memory-based prompts.
///
/// §B1 (MemoryPromptUtils.getJudgeEvaluationCriteria verbatim from cm_MemoryPromptUtils.scala).
/// Transcribed byte-exact including the trailing space after the colon on items 2 and 5
/// ("2. **Completeness with Transparency**: " and "5. **Clarity and Honesty**: ").
/// No trailing newline — matches the Scala source which closes with `don't know."""`.
///
/// - Returns: The evaluation criteria block as a bare String.
public func convoMemJudgeEvaluationCriteria() -> String {
    // §B1 verbatim from MemoryPromptUtils.getJudgeEvaluationCriteria.
    // Item 2 and item 5 have a trailing space after the colon — verbatim from Scala source.
    return
        "When answering, keep in mind that your response will be evaluated based on:\n" +
        "\n" +
        "1. **Core Information Accuracy**: Your answer must contain all essential factual information that directly addresses the question.\n" +
        "\n" +
        "2. **Completeness with Transparency**: \n" +      // trailing space verbatim
        "   - Provide all information you have that is requested by the question\n" +
        "   - If the question has multiple parts, answer what you can and explicitly state which parts you cannot answer\n" +
        "   - For partial knowledge, use phrases like:\n" +
        "     * \"I know [specific fact], but I don't have information about [missing part]\"\n" +
        "     * \"Based on the conversations, I can confirm [known fact], however [unknown aspect] was not discussed\"\n" +
        "     * \"I have information about [part A]: [details]. Regarding [part B], I don't have that information\"\n" +
        "\n" +
        "3. **Factual Correctness**: All information in your response must be accurate and align with the available information.\n" +
        "\n" +
        "4. **Appropriate Synthesis**: When multiple pieces of relevant information exist, synthesize them appropriately.\n" +
        "\n" +
        "5. **Clarity and Honesty**: \n" +                 // trailing space verbatim
        "   - Be direct and factual in your response\n" +
        "   - Clearly distinguish between what you know and what you don't know\n" +
        "   - Never guess or fabricate information to fill gaps\n" +
        "   - Avoid unnecessary elaboration unless specifically requested\n" +
        "\n" +
        "Examples of good partial responses:\n" +
        "- \"I can tell you that the meeting is on Tuesday at 3 PM, but I don't have information about the location.\"\n" +
        "- \"The project budget is $50,000. I don't have details about the timeline or deliverables.\"\n" +
        "- \"Based on our conversations, Sarah prefers email communication. I don't know her phone preferences.\"\n" +
        "\n" +
        "If you don't have ANY relevant information to answer the question, clearly state \"I don't know\" or \"I don't have any information about that.\"\n" +
        "If you have SOME relevant information, provide what you know and explicitly acknowledge what you don't know."
}

// MARK: - §B1 — memoryBasedPrompt (MemoryPromptUtils.buildMemoryBasedPrompt)

/// Constructs the memory-based answer-generation prompt for retrieval-backed systems.
///
/// §B1 (MemoryPromptUtils.buildMemoryBasedPrompt verbatim from cm_MemoryPromptUtils.scala).
/// Two variants:
///   - Empty memories: preamble + criteria + "No relevant memories..." sentinel.
///   - Non-empty memories: preamble + criteria + numbered list + synthesis instruction.
/// No trailing newline on either variant — matches the Scala `Answer:"""` close.
///
/// - Parameters:
///   - question: The question the model must answer.
///   - memories: Retrieved memory snippets (empty → empty-memories variant).
/// - Returns: The byte-exact prompt string.
public func convoMemMemoryBasedPrompt(question: String, memories: [String]) -> String {
    let criteria = convoMemJudgeEvaluationCriteria()

    if memories.isEmpty {
        // §B1 empty-memories variant (MemoryPromptUtils.buildMemoryBasedPrompt empty branch verbatim).
        return
            "You are an assistant helping to answer questions based on available information.\n" +
            "\n" +
            criteria + "\n" +
            "\n" +
            "No relevant memories were found for this question. If you cannot answer based on the available information, please say \"I don't know.\"\n" +
            "\n" +
            "Question: " + question + "\n" +
            "\n" +
            "Answer:"
    } else {
        // §B1 non-empty memories variant (MemoryPromptUtils.buildMemoryBasedPrompt non-empty branch verbatim).
        // Memories are 1-indexed; each rendered as "{n}. {memory}"; joined by "\n".
        let memoriesContext = memories.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return
            "You are an assistant helping to answer questions based on retrieved memories. Your task is to incorporate ALL relevant information from these memories to provide accurate and complete answers.\n" +
            "\n" +
            criteria + "\n" +
            "\n" +
            "The following memories have been retrieved as relevant to your question. Each memory may contain important facts that should be considered in your answer:\n" +
            "\n" +
            memoriesContext + "\n" +
            "\n" +
            "Based on ALL the information in the memories above, answer the following question. Ensure your response incorporates all relevant facts from the retrieved memories.\n" +
            "\n" +
            "Question: " + question + "\n" +
            "\n" +
            "Answer:"
    }
}

// MARK: - §B2 — Judge prompt templates

// Five templates transcribed byte-exact from cm_AnsweringEvaluation.scala.
// Each function returns the filled prompt string with no trailing newline,
// matching the Scala s"""...WRONG.""" / s"""...RIGHT/WRONG):""" close.

/// Constructs the DefaultAnsweringEvaluation judge prompt for factual evidence.
///
/// §B2 DefaultAnsweringEvaluation (cm_AnsweringEvaluation.scala, object DefaultAnsweringEvaluation).
/// Used for factual/default evidence including assistant_facts_evidence.
/// Five Crucial Guidelines items use two spaces after the period ("1.  **Core...**").
/// Ends with `Answer (RIGHT/WRONG):` — no trailing newline.
///
/// - Parameters:
///   - question: The question asked.
///   - correctAnswer: The ground-truth answer.
///   - modelAnswer: The model response to evaluate.
/// - Returns: The byte-exact judge prompt string.
public func convoMemDefaultFactualJudgePrompt(
    question: String,
    correctAnswer: String,
    modelAnswer: String
) -> String {
    // §B2 DefaultAnsweringEvaluation: guidelines val verbatim from Scala source.
    // Note two spaces after each list number ("1.  ", "2.  ", etc.) — verbatim from Scala.
    let guidelines =
        "**Crucial Guidelines for your judgment:**\n" +
        "\n" +
        "1.  **Core Information is Key**: The Model's Response must contain all the **essential factual information** that directly answers the Question.\n" +
        "2.  **Equivalence Counts**: Phrasing doesn't need to be identical. If the Model's Response conveys the exact same core meaning and details as the Correct Answer, even if paraphrased or structured differently, consider it correct.\n" +
        "3.  **Superfluous (but Accurate) Information**: If the Model's Response includes additional details that were *not explicitly asked for* by the Question, but these details are **accurate and do not contradict** the Correct Answer, you should **still count it as correct** if the core question is fully answered.\n" +
        "4.  **Partial Answers are Incorrect**: If the Model's Response is missing any essential information directly requested by the Question (even if the Correct Answer provides more detail), it is incorrect.\n" +
        "5.  **Focus on the Question**: Your primary focus should be whether the Model's Response adequately addresses the Question using information that aligns with the Correct Answer. Do not penalize the model for not reiterating every single word or incidental detail from the Correct Answer if it wasn't requested."

    // §B2 DefaultAnsweringEvaluation: outer s"""...""" verbatim from Scala source.
    return
        "I will provide you with a **Question**, a **Correct Answer**, and a **Model's Response**. Your sole task is to determine if the Model's Response is **sufficiently correct and complete** to answer the Question, when compared against the Correct Answer.\n" +
        "\n" +
        guidelines + "\n" +
        "\n" +
        "**Answer only \"RIGHT\" or \"WRONG\". Do not provide any additional text, explanations, or reasoning.**\n" +
        "\n" +
        "Question: " + question + "\n" +
        "Correct Answer: " + correctAnswer + "\n" +
        "Model Response: " + modelAnswer + "\n" +
        "\n" +
        "Answer (RIGHT/WRONG):"
}

/// Constructs the RubricBasedAnsweringEvaluation judge prompt for rubric-scored evidence.
///
/// §B2 RubricBasedAnsweringEvaluation (cm_AnsweringEvaluation.scala, object RubricBasedAnsweringEvaluation).
/// Used for preference_evidence and implicit_connection_evidence.
/// The `rubric` parameter is the correctAnswer field — a rubric, not a specific answer.
/// ALL criteria must be satisfied. Ends with `Respond with only RIGHT or WRONG.` — no trailing newline.
///
/// - Parameters:
///   - question: The question asked.
///   - rubric: The evaluation rubric (the correctAnswer field in the Scala source).
///   - modelAnswer: The model response to evaluate.
/// - Returns: The byte-exact judge prompt string.
public func convoMemRubricBasedJudgePrompt(
    question: String,
    rubric: String,
    modelAnswer: String
) -> String {
    // §B2 RubricBasedAnsweringEvaluation: guidelines val verbatim from Scala source.
    let guidelines =
        "Guidelines:\n" +
        "- The model's response must fully satisfy ALL criteria in the rubric\n" +
        "- Partial fulfillment of criteria should result in INCORRECT\n" +
        "- The response must demonstrate clear understanding of the context\n" +
        "- Missing any important aspect mentioned in the rubric means INCORRECT"

    // §B2 RubricBasedAnsweringEvaluation: outer s"""...""" verbatim from Scala source.
    return
        "You are a judge evaluating if a model's response meets the criteria in a rubric.\n" +
        "\n" +
        "Question asked: " + question + "\n" +
        "\n" +
        "Evaluation rubric: " + rubric + "\n" +
        "\n" +
        "Model's response: " + modelAnswer + "\n" +
        "\n" +
        guidelines + "\n" +
        "\n" +
        "Evaluate whether the model's response satisfies the rubric criteria.\n" +
        "\n" +
        "If the response satisfies the criteria: RIGHT\n" +
        "If the response does not satisfy the criteria: WRONG\n" +
        "\n" +
        "Respond with only RIGHT or WRONG."
}

/// Constructs the TemporalAnsweringEvaluation judge prompt for time-sensitive evidence.
///
/// §B2 TemporalAnsweringEvaluation (cm_AnsweringEvaluation.scala, object TemporalAnsweringEvaluation).
/// Used for changing_evidence. Accepts equivalent time expressions (e.g. "3 months = 90 days").
/// "Off-by-one errors in day counts are NOT acceptable." — verbatim from Scala.
/// Ends with `Respond with only RIGHT or WRONG.` — no trailing newline.
///
/// - Parameters:
///   - question: The question asked.
///   - correctAnswer: The ground-truth temporal answer.
///   - modelAnswer: The model response to evaluate.
/// - Returns: The byte-exact judge prompt string.
public func convoMemTemporalJudgePrompt(
    question: String,
    correctAnswer: String,
    modelAnswer: String
) -> String {
    // §B2 TemporalAnsweringEvaluation: guidelines val verbatim from Scala source.
    let guidelines =
        "Guidelines:\n" +
        "- Time calculations must be accurate within reasonable bounds\n" +
        "- Accept different but equivalent time expressions (3 months = 90 days = 12 weeks)\n" +
        "- The model must show correct temporal reasoning\n" +
        "- Off-by-one errors in day counts are NOT acceptable"

    // §B2 TemporalAnsweringEvaluation: outer s"""...""" verbatim from Scala source.
    return
        "You are a judge determining if a model's temporal answer is correct.\n" +
        "\n" +
        "Question: " + question + "\n" +
        "\n" +
        "Correct answer: " + correctAnswer + "\n" +
        "\n" +
        "Model's answer: " + modelAnswer + "\n" +
        "\n" +
        guidelines + "\n" +
        "\n" +
        "Temporal answers often have legitimate variations. Consider if the model's answer represents the same time period or demonstrates correct temporal reasoning.\n" +
        "\n" +
        "If the temporal answer is correct: RIGHT\n" +
        "If the temporal answer is incorrect: WRONG\n" +
        "\n" +
        "Respond with only RIGHT or WRONG."
}

/// Constructs the UserFactsAnsweringEvaluation judge prompt for user-fact evidence.
///
/// §B2 UserFactsAnsweringEvaluation (cm_AnsweringEvaluation.scala, class UserFactsAnsweringEvaluation).
/// Used for user_evidence. Two variants based on evidenceCount:
///   - evidenceCount == 1: single-evidence form; first evidence message text embedded directly.
///     The "**Question Asked:** " header line has a trailing space (verbatim from Scala).
///   - evidenceCount > 1: multi-evidence form; messages listed as
///     "Evidence Message N: {text}" joined by "\n".
/// Both variants end with `Answer (RIGHT/WRONG):` — no trailing newline.
///
/// - Parameters:
///   - question: The question asked.
///   - correctAnswer: The ground-truth answer.
///   - modelAnswer: The model response to evaluate.
///   - evidenceMessages: Evidence messages available to the model.
///   - evidenceCount: Selects single (==1) vs. multi-evidence (>1) branch, mirroring the Scala constructor.
/// - Returns: The byte-exact judge prompt string.
public func convoMemUserFactsJudgePrompt(
    question: String,
    correctAnswer: String,
    modelAnswer: String,
    evidenceMessages: [ConvoMemEvidenceMessage],
    evidenceCount: Int
) -> String {
    if evidenceCount == 1 {
        // §B2 UserFactsAnsweringEvaluation single-evidence branch verbatim from Scala source.
        // headOption.map(_.text).getOrElse("") → first message text or empty string.
        // "**Question Asked:** " has a trailing space — verbatim from Scala line 168.
        let evidenceMessageText = evidenceMessages.first?.text ?? ""

        return
            "You are evaluating whether a model's response correctly answers a question using information from an evidence message.\n" +
            "\n" +
            "**Your Task:**\n" +
            "Determine if the Model's Response is RIGHT or WRONG based on the following criteria.\n" +
            "\n" +
            "**Question Asked:** \n" +       // trailing space verbatim from Scala line 168
            question + "\n" +
            "\n" +
            "**Evidence Message Available to the Model:**\n" +
            evidenceMessageText + "\n" +
            "\n" +
            "**Correct Answer (what the response should convey):**\n" +
            correctAnswer + "\n" +
            "\n" +
            "**Model's Response to Evaluate:**\n" +
            modelAnswer + "\n" +
            "\n" +
            "**Evaluation Criteria:**\n" +
            "\n" +
            "When the response is RIGHT:\n" +
            "- The core answer matches the Correct Answer (exact phrasing not required)\n" +
            "- The response demonstrates understanding of the information from the evidence message\n" +
            "- The response correctly addresses the question asked\n" +
            "- If the model includes accurate additional details not in the Correct Answer, that's still RIGHT\n" +
            "\n" +
            "When the response is WRONG:\n" +
            "- The core answer contradicts or significantly differs from the Correct Answer\n" +
            "- Critical information from the evidence message is missing or misunderstood\n" +
            "- The response shows confusion about the facts\n" +
            "- The response fails to answer the question asked\n" +
            "\n" +
            "**Important Notes:**\n" +
            "- The model doesn't need to quote the evidence message verbatim\n" +
            "- Paraphrasing or summarization is expected and acceptable\n" +
            "- Focus on whether the essential information has been correctly conveyed\n" +
            "\n" +
            "**Answer only \"RIGHT\" or \"WRONG\". Do not provide any additional text, explanations, or reasoning.**\n" +
            "\n" +
            "Answer (RIGHT/WRONG):"

    } else {
        // §B2 UserFactsAnsweringEvaluation multi-evidence branch verbatim from Scala source.
        // evidenceMessages.zipWithIndex → "Evidence Message {n+1}: {msg.text}" joined by "\n".
        // "**Question Asked:** " has a trailing space — same pattern as single-evidence branch.
        let evidenceMessagesText = evidenceMessages.enumerated()
            .map { "Evidence Message \($0.offset + 1): \($0.element.text)" }
            .joined(separator: "\n")

        return
            "You are evaluating whether a model's response correctly answers a question using information from multiple evidence messages.\n" +
            "\n" +
            "**Your Task:**\n" +
            "Determine if the Model's Response is RIGHT or WRONG based on the following criteria.\n" +
            "\n" +
            "**Question Asked:** \n" +       // trailing space verbatim from Scala line 210
            question + "\n" +
            "\n" +
            "**Evidence Messages Available to the Model:**\n" +
            evidenceMessagesText + "\n" +
            "\n" +
            "**Correct Answer (what the response should convey):**\n" +
            correctAnswer + "\n" +
            "\n" +
            "**Model's Response to Evaluate:**\n" +
            modelAnswer + "\n" +
            "\n" +
            "**Evaluation Criteria:**\n" +
            "\n" +
            "When the response is RIGHT:\n" +
            "- The core answer matches the Correct Answer (exact phrasing not required)\n" +
            "- Information from most evidence messages is reasonably reflected in the response\n" +
            "- The response shows understanding and synthesis of the multiple pieces of information\n" +
            "- Minor omissions are acceptable if the main answer is correct\n" +
            "\n" +
            "When the response is WRONG:\n" +
            "- The core answer contradicts or significantly differs from the Correct Answer\n" +
            "- Critical information from multiple evidence messages is completely missing\n" +
            "- The response shows misunderstanding or confusion about the facts\n" +
            "- The response fails to answer the question asked\n" +
            "\n" +
            "**Important Notes:**\n" +
            "- The model doesn't need to explicitly cite each evidence message\n" +
            "- Focus on whether the essential information has been incorporated, not perfect completeness\n" +
            "- Some paraphrasing or summarization is expected and acceptable\n" +
            "- If the model includes accurate additional details not in the Correct Answer, that's still RIGHT\n" +
            "\n" +
            "**Answer only \"RIGHT\" or \"WRONG\". Do not provide any additional text, explanations, or reasoning.**\n" +
            "\n" +
            "Answer (RIGHT/WRONG):"
    }
}

/// Constructs the AbstentionAnsweringEvaluation judge prompt for abstention evidence.
///
/// §B2 AbstentionAnsweringEvaluation (cm_AnsweringEvaluation.scala, object AbstentionAnsweringEvaluation).
/// Used for abstention_evidence. Abstention (saying "I don't know" etc.) is success;
/// hallucination is failure. The correctAnswer field is NOT used in this template.
/// Ends with `Answer (RIGHT/WRONG):` — no trailing newline.
///
/// - Parameters:
///   - question: The question asked.
///   - modelAnswer: The model response to evaluate.
/// - Returns: The byte-exact judge prompt string.
public func convoMemAbstentionJudgePrompt(
    question: String,
    modelAnswer: String
) -> String {
    // §B2 AbstentionAnsweringEvaluation: guidelines val verbatim from Scala source.
    let guidelines =
        "**Critical Guidelines for Abstention Evaluation:**\n" +
        "\n" +
        "1. **Abstention is Success**: If the model refuses to answer, says it doesn't know, or indicates insufficient information, this is CORRECT behavior for abstention tests.\n" +
        "\n" +
        "2. **Various Forms of Abstention are Acceptable**:\n" +
        "   - \"I don't know\" / \"I'm not sure\" / \"I cannot determine\"\n" +
        "   - \"There is no information about...\" / \"This wasn't mentioned...\"\n" +
        "   - \"I don't have enough information to answer...\"\n" +
        "   - \"Based on the conversation, I cannot tell...\"\n" +
        "   - \"This information wasn't provided...\"\n" +
        "   - Asking for clarification or more information\n" +
        "\n" +
        "3. **Hallucination is Failure**: If the model provides a specific answer that wasn't in the evidence, this is WRONG, even if it seems plausible.\n" +
        "\n" +
        "4. **Partial Information Recognition**: If the model correctly identifies what information IS available while noting what is missing, this is RIGHT.\n" +
        "\n" +
        "5. **Key Principle**: The goal is to test whether the model can recognize the limits of its knowledge. Any response that demonstrates this recognition should be marked as RIGHT."

    // §B2 AbstentionAnsweringEvaluation: outer s"""...""" verbatim from Scala source.
    return
        "You are evaluating an ABSTENTION test where the model should recognize it lacks sufficient information to answer the question.\n" +
        "\n" +
        "**This is an abstention test - the model SHOULD refuse to answer or say it doesn't know.**\n" +
        "\n" +
        guidelines + "\n" +
        "\n" +
        "**Answer only \"RIGHT\" or \"WRONG\". Do not provide any additional text, explanations, or reasoning.**\n" +
        "\n" +
        "Question: " + question + "\n" +
        "Expected behavior: The model should indicate it cannot answer due to insufficient information\n" +
        "Model Response: " + modelAnswer + "\n" +
        "\n" +
        "Does the model appropriately abstain from answering or acknowledge insufficient information?\n" +
        "\n" +
        "Answer (RIGHT/WRONG):"
}

// MARK: - §B2 — Evidence type to template selector

/// The six ConvoMem evidence type identifiers matching the §A1 subset names.
public enum ConvoMemEvidenceType: String, Sendable, CaseIterable {
    /// §B2 mapping: abstention_evidence → AbstentionAnsweringEvaluation.
    case abstentionEvidence = "abstention_evidence"
    /// §B2 mapping: assistant_facts_evidence → DefaultAnsweringEvaluation (factual default).
    case assistantFactsEvidence = "assistant_facts_evidence"
    /// §B2 mapping: changing_evidence → TemporalAnsweringEvaluation.
    case changingEvidence = "changing_evidence"
    /// §B2 mapping: implicit_connection_evidence → RubricBasedAnsweringEvaluation.
    case implicitConnectionEvidence = "implicit_connection_evidence"
    /// §B2 mapping: preference_evidence → RubricBasedAnsweringEvaluation.
    case preferenceEvidence = "preference_evidence"
    /// §B2 mapping: user_evidence → UserFactsAnsweringEvaluation(evidenceCount).
    case userEvidence = "user_evidence"
}

/// Constructs the appropriate judge prompt for a given evidence type.
///
/// §B2 selector mapping (verbatim from LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md §B2):
///   - assistant_facts_evidence (factual default) → DefaultAnsweringEvaluation
///   - preference_evidence + implicit_connection_evidence → RubricBasedAnsweringEvaluation
///   - changing_evidence → TemporalAnsweringEvaluation
///   - user_evidence → UserFactsAnsweringEvaluation(evidenceCount)
///   - abstention_evidence → AbstentionAnsweringEvaluation
///
/// - Parameters:
///   - evidenceType: The ConvoMem subset evidence type.
///   - question: The question asked.
///   - correctAnswer: Ground-truth answer or rubric; ignored for abstention.
///   - modelAnswer: The model response to evaluate.
///   - evidenceMessages: Evidence messages (used only for UserFacts).
///   - evidenceCount: Branch selector for UserFacts (single vs. multi-evidence).
/// - Returns: The byte-exact judge prompt for the evidence type.
public func convoMemJudgePrompt(
    evidenceType: ConvoMemEvidenceType,
    question: String,
    correctAnswer: String,
    modelAnswer: String,
    evidenceMessages: [ConvoMemEvidenceMessage] = [],
    evidenceCount: Int = 1
) -> String {
    switch evidenceType {
    case .assistantFactsEvidence:
        // §B2: factual default → DefaultAnsweringEvaluation.
        return convoMemDefaultFactualJudgePrompt(
            question: question,
            correctAnswer: correctAnswer,
            modelAnswer: modelAnswer
        )

    case .preferenceEvidence, .implicitConnectionEvidence:
        // §B2: preference + implicit_connection → RubricBasedAnsweringEvaluation.
        return convoMemRubricBasedJudgePrompt(
            question: question,
            rubric: correctAnswer,
            modelAnswer: modelAnswer
        )

    case .changingEvidence:
        // §B2: changing → TemporalAnsweringEvaluation.
        return convoMemTemporalJudgePrompt(
            question: question,
            correctAnswer: correctAnswer,
            modelAnswer: modelAnswer
        )

    case .userEvidence:
        // §B2: user facts → UserFactsAnsweringEvaluation(evidenceCount).
        return convoMemUserFactsJudgePrompt(
            question: question,
            correctAnswer: correctAnswer,
            modelAnswer: modelAnswer,
            evidenceMessages: evidenceMessages,
            evidenceCount: evidenceCount
        )

    case .abstentionEvidence:
        // §B2: abstention → AbstentionAnsweringEvaluation (correctAnswer not embedded).
        return convoMemAbstentionJudgePrompt(
            question: question,
            modelAnswer: modelAnswer
        )
    }
}

// MARK: - §B3 — Verdict parsing

/// The outcome of one judge call, per §B3.
///
/// `invalid` is a DISTINCT case from `incorrect` — it signals the runner should retry,
/// not that the answer was scored wrong. §B3: "neither → invalid → retry (bounded);
/// a run out of retries yields no verdict (question unscored, counted as such)."
public enum ConvoMemVerdictOutcome: Sendable, Equatable {
    /// Judge response contained "right" only (after trim+lowercase). §B3 → scored correct.
    case correct
    /// Judge response contained "wrong" only, OR contained both "right" and "wrong"
    /// (ambiguous). §B3: both-present → ambiguous → false (scored as incorrect).
    case incorrect
    /// Judge response contained neither "right" nor "wrong". §B3 → retry signal.
    /// NOT the same as incorrect — the question is unscored if retries are exhausted.
    case invalid
}

/// Parses a judge's raw text response into a verdict outcome per §B3.
///
/// §B3 algorithm verbatim from EvaluationUtils.verifyAnswerCorrectnessWithPrompt:
///   1. response.content.trim.toLowerCase
///   2. containsRight = judgeResponse.contains("right")
///   3. containsWrong = judgeResponse.contains("wrong")
///   4. if containsRight && containsWrong → ambiguous → false (scored as .incorrect)
///   5. else if containsRight → true (.correct)
///   6. else if containsWrong → false (.incorrect)
///   7. else → throw (trigger retry) → .invalid when retries exhausted
///
/// - Parameter judgeResponse: Raw text returned by the external judge command.
/// - Returns: A `ConvoMemVerdictOutcome` per §B3.
public func convoMemVerdict(_ judgeResponse: String) -> ConvoMemVerdictOutcome {
    // §B3: trim then lowercase, as in Scala: response.content.trim.toLowerCase
    let lower = judgeResponse.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    let containsRight = lower.contains("right")
    let containsWrong = lower.contains("wrong")

    if containsRight && containsWrong {
        // §B3: ambiguous — both present → default to false (incorrect).
        // Caller logs the warning; this module does not print.
        return .incorrect
    } else if containsRight {
        // §B3: "right" only → correct.
        return .correct
    } else if containsWrong {
        // §B3: "wrong" only → incorrect.
        return .incorrect
    } else {
        // §B3: neither → invalid → caller retries (bounded).
        // When retries are exhausted the question is unscored, not scored wrong.
        return .invalid
    }
}

// MARK: - §B4 — Aggregation types

/// One input row for the §B4 aggregator.
public struct ConvoMemVerdictRow: Sendable {
    /// ConvoMem subset name (e.g. "user_evidence"). §B4: groups per-type accuracy.
    public let evidenceType: String
    /// Evidence count file index (e.g. 1 for "1_evidence"). §B4: groups per-count accuracy.
    public let evidenceCount: Int
    /// Verdict outcome. `.invalid` rows are excluded from accuracy denominator. §B4.
    public let outcome: ConvoMemVerdictOutcome

    public init(evidenceType: String, evidenceCount: Int, outcome: ConvoMemVerdictOutcome) {
        self.evidenceType = evidenceType
        self.evidenceCount = evidenceCount
        self.outcome = outcome
    }
}

/// Per-evidence-type accuracy result for §B4 aggregation.
public struct ConvoMemTypeMetrics: Sendable, Equatable {
    /// The evidence type string (ConvoMem subset name).
    public let evidenceType: String
    /// accuracy = correctCount / scoredCount; 0.0 when scoredCount == 0.
    public let accuracy: Double
    /// Correct verdicts (outcome == .correct). Count alongside the mean per §B4.
    public let correctCount: Int
    /// Scored verdicts (outcome != .invalid); the accuracy denominator.
    public let scoredCount: Int
    /// Unscored verdicts (outcome == .invalid); reported separately per §B4.
    public let unscoredCount: Int
}

/// Per-evidence-count accuracy result for §B4 aggregation.
public struct ConvoMemCountMetrics: Sendable, Equatable {
    /// The evidence count bucket (e.g. 1 for "1_evidence" files).
    public let evidenceCount: Int
    /// accuracy = correctCount / scoredCount; 0.0 when scoredCount == 0.
    public let accuracy: Double
    /// Correct verdicts (outcome == .correct). Count alongside the mean per §B4.
    public let correctCount: Int
    /// Scored verdicts (outcome != .invalid); the accuracy denominator.
    public let scoredCount: Int
    /// Unscored verdicts (outcome == .invalid); reported separately per §B4.
    public let unscoredCount: Int
}

/// Complete §B4 aggregate result for one evaluation run.
public struct ConvoMemAggregateResult: Sendable {
    /// Per-evidence-type metrics, sorted by type string for determinism. §B4.
    public let perType: [ConvoMemTypeMetrics]
    /// Per-evidence-count metrics, sorted by count ascending for determinism. §B4.
    public let perCount: [ConvoMemCountMetrics]
    /// Overall accuracy over all scored instances (outcome != .invalid). §B4.
    public let overallAccuracy: Double
    /// Total correct scored instances. Count alongside the mean per §B4.
    public let overallCorrectCount: Int
    /// Total scored instances (accuracy denominator). §B4.
    public let overallScoredCount: Int
    /// Total unscored instances (outcome == .invalid); reported separately. §B4.
    public let overallUnscoredCount: Int
}

// MARK: - §B4 — Aggregation engine

/// Rounds a Double to 4 decimal places for consistent accuracy reporting.
private func convoMemRound4(_ x: Double) -> Double {
    (x * 10_000.0).rounded() / 10_000.0
}

/// Computes §B4 aggregate accuracy metrics over a set of verdict rows.
///
/// §B4: accuracy per evidence type, per evidence count, and overall.
/// Counts accompany every mean. Rows with outcome `.invalid` are excluded from
/// the accuracy denominator and reported in the unscoredCount fields separately.
///
/// Output is sorted for determinism: perType by evidence type string, perCount
/// by evidence count integer ascending.
///
/// - Parameter rows: One row per evaluated QA instance.
/// - Returns: A fully-populated `ConvoMemAggregateResult`.
public func convoMemAggregate(_ rows: [ConvoMemVerdictRow]) -> ConvoMemAggregateResult {
    // Accumulate per-type and per-count buckets.
    var typeCorrect:   [String: Int] = [:]
    var typeScored:    [String: Int] = [:]
    var typeUnscored:  [String: Int] = [:]

    var countCorrect:  [Int: Int] = [:]
    var countScored:   [Int: Int] = [:]
    var countUnscored: [Int: Int] = [:]

    var overallCorrect  = 0
    var overallScored   = 0
    var overallUnscored = 0

    for row in rows {
        let et = row.evidenceType
        let ec = row.evidenceCount

        switch row.outcome {
        case .correct:
            // §B4: scored + correct — contributes to all accuracy denominators and numerators.
            typeCorrect[et,  default: 0] += 1
            typeScored[et,   default: 0] += 1
            countCorrect[ec, default: 0] += 1
            countScored[ec,  default: 0] += 1
            overallCorrect += 1
            overallScored  += 1

        case .incorrect:
            // §B4: scored + wrong (includes ambiguous per §B3) — in denominator, not numerator.
            typeScored[et,  default: 0] += 1
            countScored[ec, default: 0] += 1
            overallScored += 1

        case .invalid:
            // §B4: unscored — excluded from accuracy, counted separately.
            typeUnscored[et,  default: 0] += 1
            countUnscored[ec, default: 0] += 1
            overallUnscored += 1
        }
    }

    // Build per-type metrics, sorted by type name for determinism.
    let allTypes = Set(typeScored.keys).union(typeUnscored.keys).sorted()
    let perType: [ConvoMemTypeMetrics] = allTypes.map { et in
        let scored   = typeScored[et,   default: 0]
        let correct  = typeCorrect[et,  default: 0]
        let unscored = typeUnscored[et, default: 0]
        let accuracy = scored == 0 ? 0.0 : convoMemRound4(Double(correct) / Double(scored))
        return ConvoMemTypeMetrics(
            evidenceType: et,
            accuracy:     accuracy,
            correctCount: correct,
            scoredCount:  scored,
            unscoredCount: unscored
        )
    }

    // Build per-count metrics, sorted by count ascending for determinism.
    let allCounts = Set(countScored.keys).union(countUnscored.keys).sorted()
    let perCount: [ConvoMemCountMetrics] = allCounts.map { ec in
        let scored   = countScored[ec,   default: 0]
        let correct  = countCorrect[ec,  default: 0]
        let unscored = countUnscored[ec, default: 0]
        let accuracy = scored == 0 ? 0.0 : convoMemRound4(Double(correct) / Double(scored))
        return ConvoMemCountMetrics(
            evidenceCount: ec,
            accuracy:      accuracy,
            correctCount:  correct,
            scoredCount:   scored,
            unscoredCount: unscored
        )
    }

    // §B4 overall accuracy over all scored instances.
    let overallAccuracy = overallScored == 0
        ? 0.0
        : convoMemRound4(Double(overallCorrect) / Double(overallScored))

    return ConvoMemAggregateResult(
        perType:             perType,
        perCount:            perCount,
        overallAccuracy:     overallAccuracy,
        overallCorrectCount: overallCorrect,
        overallScoredCount:  overallScored,
        overallUnscoredCount: overallUnscored
    )
}
