//! convomem_spec_protocol — Official ConvoMem answer + judge protocol (Rust twin).
//!
//! Implements §B1–§B4 of LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md verbatim, porting
//! the Swift ConvoMemSpecProtocol.swift to Rust with identical semantics.
//! Prompt templates are byte-identical across both ports; conformance is verified
//! against the shared conformance/convomem-spec/protocol_vectors.json vectors.
//!
//! Role: pure logic; no I/O, no system time calls, no external crates.

// MARK: - §B1 — Answer generation input types

/// A single speaker turn in a conversation.
///
/// Maps to `Message` in the ConvoMem Scala harness. §B1: rendered as "{speaker}: {text}".
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConvoMemMessage {
    /// Speaker label (e.g. "User" or "Assistant").
    pub speaker: String,
    /// Turn text rendered after the speaker label and ": ".
    pub text: String,
}

impl ConvoMemMessage {
    pub fn new(speaker: impl Into<String>, text: impl Into<String>) -> Self {
        Self { speaker: speaker.into(), text: text.into() }
    }
}

/// A single conversation consisting of one or more ordered turns.
///
/// Maps to `Conversation` in the ConvoMem Scala harness.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConvoMemConversation {
    /// Ordered list of message turns.
    pub messages: Vec<ConvoMemMessage>,
}

impl ConvoMemConversation {
    pub fn new(messages: Vec<ConvoMemMessage>) -> Self {
        Self { messages }
    }
}

/// A single evidence message available to the model during user-facts evaluation.
///
/// Maps to `Message.text` in UserFactsAnsweringEvaluation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConvoMemEvidenceMessage {
    /// Evidence text embedded verbatim in the judge prompt. §B2 UserFacts.
    pub text: String,
}

impl ConvoMemEvidenceMessage {
    pub fn new(text: impl Into<String>) -> Self {
        Self { text: text.into() }
    }
}

// MARK: - §B1 — buildConversationContext (EvaluationUtils.buildConversationContext)

/// Formats a list of conversations into the numbered context block.
///
/// §B1 (EvaluationUtils.buildConversationContext verbatim):
///   conversations.zipWithIndex → "Conversation N:\n{speaker}: {text}\n..." joined by "\n\n".
/// No trailing newline — matches the Scala source.
///
/// # Arguments
/// * `conversations` — Ordered list of conversations.
pub fn convomem_build_conversation_context(conversations: &[ConvoMemConversation]) -> String {
    // §B1: 1-based numbering; turns joined by "\n"; conversations joined by "\n\n".
    conversations
        .iter()
        .enumerate()
        .map(|(index, conversation)| {
            let number = index + 1;
            let turns: Vec<String> = conversation
                .messages
                .iter()
                .map(|m| format!("{}: {}", m.speaker, m.text))
                .collect();
            format!("Conversation {}:\n{}", number, turns.join("\n"))
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

// MARK: - §B1 — modelAnswerPrompt (EvaluationUtils.getModelAnswerPrompt)

/// Constructs the full-context answer-generation prompt.
///
/// §B1 (EvaluationUtils.getModelAnswerPrompt verbatim from cm_EvaluationUtils.scala).
/// No trailing newline — matches the Scala source which closes with `Answer:"""`.
///
/// # Arguments
/// * `conversations` — Conversations included as context.
/// * `question` — The question the model must answer.
pub fn convomem_model_answer_prompt(conversations: &[ConvoMemConversation], question: &str) -> String {
    let ctx = convomem_build_conversation_context(conversations);
    // §B1 verbatim — Scala: s"""Answer the question...Answer:"""
    format!(
        "Answer the question based on the conversations below. If the User in the conversation refers to themselves (\"I\", \"me\", \"my\"), they are the person being asked about. Be direct and factual.\n\
         \n\
         {ctx}\n\
         \n\
         Question: {question}\n\
         \n\
         Answer:"
    )
}

// MARK: - §B1 — getJudgeEvaluationCriteria (MemoryPromptUtils.getJudgeEvaluationCriteria)

/// Returns the evaluation-criteria block embedded in memory-based prompts.
///
/// §B1 (MemoryPromptUtils.getJudgeEvaluationCriteria verbatim from cm_MemoryPromptUtils.scala).
/// Transcribed byte-exact including trailing space after colon on items 2 and 5.
/// No trailing newline — matches the Scala source.
pub fn convomem_judge_evaluation_criteria() -> String {
    // §B1 verbatim from MemoryPromptUtils.getJudgeEvaluationCriteria.
    // Item 2 "Completeness with Transparency": and item 5 "Clarity and Honesty": each
    // have a trailing space after the colon — verbatim from Scala source lines 22 and 34.
    concat!(
        "When answering, keep in mind that your response will be evaluated based on:\n",
        "\n",
        "1. **Core Information Accuracy**: Your answer must contain all essential factual information that directly addresses the question.\n",
        "\n",
        "2. **Completeness with Transparency**: \n",  // trailing space verbatim
        "   - Provide all information you have that is requested by the question\n",
        "   - If the question has multiple parts, answer what you can and explicitly state which parts you cannot answer\n",
        "   - For partial knowledge, use phrases like:\n",
        "     * \"I know [specific fact], but I don't have information about [missing part]\"\n",
        "     * \"Based on the conversations, I can confirm [known fact], however [unknown aspect] was not discussed\"\n",
        "     * \"I have information about [part A]: [details]. Regarding [part B], I don't have that information\"\n",
        "\n",
        "3. **Factual Correctness**: All information in your response must be accurate and align with the available information.\n",
        "\n",
        "4. **Appropriate Synthesis**: When multiple pieces of relevant information exist, synthesize them appropriately.\n",
        "\n",
        "5. **Clarity and Honesty**: \n",             // trailing space verbatim
        "   - Be direct and factual in your response\n",
        "   - Clearly distinguish between what you know and what you don't know\n",
        "   - Never guess or fabricate information to fill gaps\n",
        "   - Avoid unnecessary elaboration unless specifically requested\n",
        "\n",
        "Examples of good partial responses:\n",
        "- \"I can tell you that the meeting is on Tuesday at 3 PM, but I don't have information about the location.\"\n",
        "- \"The project budget is $50,000. I don't have details about the timeline or deliverables.\"\n",
        "- \"Based on our conversations, Sarah prefers email communication. I don't know her phone preferences.\"\n",
        "\n",
        "If you don't have ANY relevant information to answer the question, clearly state \"I don't know\" or \"I don't have any information about that.\"\n",
        "If you have SOME relevant information, provide what you know and explicitly acknowledge what you don't know.",
    ).to_string()
}

// MARK: - §B1 — memoryBasedPrompt (MemoryPromptUtils.buildMemoryBasedPrompt)

/// Constructs the memory-based answer-generation prompt for retrieval-backed systems.
///
/// §B1 (MemoryPromptUtils.buildMemoryBasedPrompt verbatim from cm_MemoryPromptUtils.scala).
/// Two variants depending on whether memories are available.
/// No trailing newline on either variant — matches the Scala `Answer:"""` close.
///
/// # Arguments
/// * `question` — The question the model must answer.
/// * `memories` — Retrieved memory snippets (empty → empty-memories variant).
pub fn convomem_memory_based_prompt(question: &str, memories: &[&str]) -> String {
    let criteria = convomem_judge_evaluation_criteria();

    if memories.is_empty() {
        // §B1 empty-memories variant (MemoryPromptUtils.buildMemoryBasedPrompt empty branch verbatim).
        format!(
            "You are an assistant helping to answer questions based on available information.\n\
             \n\
             {criteria}\n\
             \n\
             No relevant memories were found for this question. If you cannot answer based on the available information, please say \"I don't know.\"\n\
             \n\
             Question: {question}\n\
             \n\
             Answer:"
        )
    } else {
        // §B1 non-empty memories variant (MemoryPromptUtils.buildMemoryBasedPrompt non-empty branch verbatim).
        // memories.zipWithIndex → "{n}. {memory}" joined by "\n".
        let memories_context: Vec<String> = memories
            .iter()
            .enumerate()
            .map(|(i, m)| format!("{}. {}", i + 1, m))
            .collect();
        let memories_context = memories_context.join("\n");

        format!(
            "You are an assistant helping to answer questions based on retrieved memories. Your task is to incorporate ALL relevant information from these memories to provide accurate and complete answers.\n\
             \n\
             {criteria}\n\
             \n\
             The following memories have been retrieved as relevant to your question. Each memory may contain important facts that should be considered in your answer:\n\
             \n\
             {memories_context}\n\
             \n\
             Based on ALL the information in the memories above, answer the following question. Ensure your response incorporates all relevant facts from the retrieved memories.\n\
             \n\
             Question: {question}\n\
             \n\
             Answer:"
        )
    }
}

// MARK: - §B2 — Judge prompt templates

/// Constructs the DefaultAnsweringEvaluation judge prompt for factual evidence.
///
/// §B2 DefaultAnsweringEvaluation (cm_AnsweringEvaluation.scala, object DefaultAnsweringEvaluation).
/// Used for factual/default evidence including assistant_facts_evidence.
/// Five Crucial Guidelines items use two spaces after the period ("1.  **Core...**") — verbatim.
/// No trailing newline — matches the Scala `Answer (RIGHT/WRONG):"""` close.
///
/// # Arguments
/// * `question` — The question asked.
/// * `correct_answer` — The ground-truth answer.
/// * `model_answer` — The model response to evaluate.
pub fn convomem_default_factual_judge_prompt(
    question: &str,
    correct_answer: &str,
    model_answer: &str,
) -> String {
    // §B2 DefaultAnsweringEvaluation: guidelines val verbatim from Scala source.
    // Two spaces after each list number ("1.  ", "2.  ", etc.) — verbatim from Scala.
    let guidelines = concat!(
        "**Crucial Guidelines for your judgment:**\n",
        "\n",
        "1.  **Core Information is Key**: The Model's Response must contain all the **essential factual information** that directly answers the Question.\n",
        "2.  **Equivalence Counts**: Phrasing doesn't need to be identical. If the Model's Response conveys the exact same core meaning and details as the Correct Answer, even if paraphrased or structured differently, consider it correct.\n",
        "3.  **Superfluous (but Accurate) Information**: If the Model's Response includes additional details that were *not explicitly asked for* by the Question, but these details are **accurate and do not contradict** the Correct Answer, you should **still count it as correct** if the core question is fully answered.\n",
        "4.  **Partial Answers are Incorrect**: If the Model's Response is missing any essential information directly requested by the Question (even if the Correct Answer provides more detail), it is incorrect.\n",
        "5.  **Focus on the Question**: Your primary focus should be whether the Model's Response adequately addresses the Question using information that aligns with the Correct Answer. Do not penalize the model for not reiterating every single word or incidental detail from the Correct Answer if it wasn't requested.",
    );

    // §B2 DefaultAnsweringEvaluation: outer s"""...""" verbatim from Scala source.
    format!(
        "I will provide you with a **Question**, a **Correct Answer**, and a **Model's Response**. Your sole task is to determine if the Model's Response is **sufficiently correct and complete** to answer the Question, when compared against the Correct Answer.\n\
         \n\
         {guidelines}\n\
         \n\
         **Answer only \"RIGHT\" or \"WRONG\". Do not provide any additional text, explanations, or reasoning.**\n\
         \n\
         Question: {question}\n\
         Correct Answer: {correct_answer}\n\
         Model Response: {model_answer}\n\
         \n\
         Answer (RIGHT/WRONG):"
    )
}

/// Constructs the RubricBasedAnsweringEvaluation judge prompt for rubric-scored evidence.
///
/// §B2 RubricBasedAnsweringEvaluation (cm_AnsweringEvaluation.scala).
/// Used for preference_evidence and implicit_connection_evidence.
/// No trailing newline — matches the Scala `Respond with only RIGHT or WRONG."""` close.
///
/// # Arguments
/// * `question` — The question asked.
/// * `rubric` — The evaluation rubric (the correctAnswer field in the Scala source).
/// * `model_answer` — The model response to evaluate.
pub fn convomem_rubric_based_judge_prompt(
    question: &str,
    rubric: &str,
    model_answer: &str,
) -> String {
    // §B2 RubricBasedAnsweringEvaluation: guidelines val verbatim from Scala source.
    let guidelines = concat!(
        "Guidelines:\n",
        "- The model's response must fully satisfy ALL criteria in the rubric\n",
        "- Partial fulfillment of criteria should result in INCORRECT\n",
        "- The response must demonstrate clear understanding of the context\n",
        "- Missing any important aspect mentioned in the rubric means INCORRECT",
    );

    // §B2 RubricBasedAnsweringEvaluation: outer s"""...""" verbatim from Scala source.
    format!(
        "You are a judge evaluating if a model's response meets the criteria in a rubric.\n\
         \n\
         Question asked: {question}\n\
         \n\
         Evaluation rubric: {rubric}\n\
         \n\
         Model's response: {model_answer}\n\
         \n\
         {guidelines}\n\
         \n\
         Evaluate whether the model's response satisfies the rubric criteria.\n\
         \n\
         If the response satisfies the criteria: RIGHT\n\
         If the response does not satisfy the criteria: WRONG\n\
         \n\
         Respond with only RIGHT or WRONG."
    )
}

/// Constructs the TemporalAnsweringEvaluation judge prompt for time-sensitive evidence.
///
/// §B2 TemporalAnsweringEvaluation (cm_AnsweringEvaluation.scala).
/// Used for changing_evidence. Accepts equivalent time expressions.
/// "Off-by-one errors in day counts are NOT acceptable." — verbatim from Scala.
/// No trailing newline — matches the Scala `Respond with only RIGHT or WRONG."""` close.
///
/// # Arguments
/// * `question` — The question asked.
/// * `correct_answer` — The ground-truth temporal answer.
/// * `model_answer` — The model response to evaluate.
pub fn convomem_temporal_judge_prompt(
    question: &str,
    correct_answer: &str,
    model_answer: &str,
) -> String {
    // §B2 TemporalAnsweringEvaluation: guidelines val verbatim from Scala source.
    let guidelines = concat!(
        "Guidelines:\n",
        "- Time calculations must be accurate within reasonable bounds\n",
        "- Accept different but equivalent time expressions (3 months = 90 days = 12 weeks)\n",
        "- The model must show correct temporal reasoning\n",
        "- Off-by-one errors in day counts are NOT acceptable",
    );

    // §B2 TemporalAnsweringEvaluation: outer s"""...""" verbatim from Scala source.
    format!(
        "You are a judge determining if a model's temporal answer is correct.\n\
         \n\
         Question: {question}\n\
         \n\
         Correct answer: {correct_answer}\n\
         \n\
         Model's answer: {model_answer}\n\
         \n\
         {guidelines}\n\
         \n\
         Temporal answers often have legitimate variations. Consider if the model's answer represents the same time period or demonstrates correct temporal reasoning.\n\
         \n\
         If the temporal answer is correct: RIGHT\n\
         If the temporal answer is incorrect: WRONG\n\
         \n\
         Respond with only RIGHT or WRONG."
    )
}

/// Constructs the UserFactsAnsweringEvaluation judge prompt for user-fact evidence.
///
/// §B2 UserFactsAnsweringEvaluation (cm_AnsweringEvaluation.scala, class UserFactsAnsweringEvaluation).
/// Used for user_evidence. Two variants based on evidence_count:
///   - evidence_count == 1: single-evidence form; first evidence message embedded directly.
///     "**Question Asked:** " has a trailing space (verbatim from Scala line 168).
///   - evidence_count > 1: multi-evidence form; messages listed as
///     "Evidence Message N: {text}" joined by "\n".
/// No trailing newline on either variant.
///
/// # Arguments
/// * `question` — The question asked.
/// * `correct_answer` — The ground-truth answer.
/// * `model_answer` — The model response to evaluate.
/// * `evidence_messages` — Evidence messages available to the model.
/// * `evidence_count` — Selects single (==1) vs. multi (>1) branch.
pub fn convomem_user_facts_judge_prompt(
    question: &str,
    correct_answer: &str,
    model_answer: &str,
    evidence_messages: &[ConvoMemEvidenceMessage],
    evidence_count: usize,
) -> String {
    if evidence_count == 1 {
        // §B2 UserFactsAnsweringEvaluation single-evidence branch verbatim from Scala source.
        // headOption.map(_.text).getOrElse("") → first message text or empty string.
        // "**Question Asked:** " has trailing space — verbatim from Scala line 168.
        let evidence_message_text = evidence_messages
            .first()
            .map(|m| m.text.as_str())
            .unwrap_or("");

        format!(
            "You are evaluating whether a model's response correctly answers a question using information from an evidence message.\n\
             \n\
             **Your Task:**\n\
             Determine if the Model's Response is RIGHT or WRONG based on the following criteria.\n\
             \n\
             **Question Asked:** \n\
             {question}\n\
             \n\
             **Evidence Message Available to the Model:**\n\
             {evidence_message_text}\n\
             \n\
             **Correct Answer (what the response should convey):**\n\
             {correct_answer}\n\
             \n\
             **Model's Response to Evaluate:**\n\
             {model_answer}\n\
             \n\
             **Evaluation Criteria:**\n\
             \n\
             When the response is RIGHT:\n\
             - The core answer matches the Correct Answer (exact phrasing not required)\n\
             - The response demonstrates understanding of the information from the evidence message\n\
             - The response correctly addresses the question asked\n\
             - If the model includes accurate additional details not in the Correct Answer, that's still RIGHT\n\
             \n\
             When the response is WRONG:\n\
             - The core answer contradicts or significantly differs from the Correct Answer\n\
             - Critical information from the evidence message is missing or misunderstood\n\
             - The response shows confusion about the facts\n\
             - The response fails to answer the question asked\n\
             \n\
             **Important Notes:**\n\
             - The model doesn't need to quote the evidence message verbatim\n\
             - Paraphrasing or summarization is expected and acceptable\n\
             - Focus on whether the essential information has been correctly conveyed\n\
             \n\
             **Answer only \"RIGHT\" or \"WRONG\". Do not provide any additional text, explanations, or reasoning.**\n\
             \n\
             Answer (RIGHT/WRONG):"
        )
    } else {
        // §B2 UserFactsAnsweringEvaluation multi-evidence branch verbatim from Scala source.
        // evidenceMessages.zipWithIndex → "Evidence Message {n+1}: {msg.text}" joined by "\n".
        // "**Question Asked:** " has trailing space — verbatim from Scala line 210.
        let evidence_messages_text: Vec<String> = evidence_messages
            .iter()
            .enumerate()
            .map(|(i, m)| format!("Evidence Message {}: {}", i + 1, m.text))
            .collect();
        let evidence_messages_text = evidence_messages_text.join("\n");

        format!(
            "You are evaluating whether a model's response correctly answers a question using information from multiple evidence messages.\n\
             \n\
             **Your Task:**\n\
             Determine if the Model's Response is RIGHT or WRONG based on the following criteria.\n\
             \n\
             **Question Asked:** \n\
             {question}\n\
             \n\
             **Evidence Messages Available to the Model:**\n\
             {evidence_messages_text}\n\
             \n\
             **Correct Answer (what the response should convey):**\n\
             {correct_answer}\n\
             \n\
             **Model's Response to Evaluate:**\n\
             {model_answer}\n\
             \n\
             **Evaluation Criteria:**\n\
             \n\
             When the response is RIGHT:\n\
             - The core answer matches the Correct Answer (exact phrasing not required)\n\
             - Information from most evidence messages is reasonably reflected in the response\n\
             - The response shows understanding and synthesis of the multiple pieces of information\n\
             - Minor omissions are acceptable if the main answer is correct\n\
             \n\
             When the response is WRONG:\n\
             - The core answer contradicts or significantly differs from the Correct Answer\n\
             - Critical information from multiple evidence messages is completely missing\n\
             - The response shows misunderstanding or confusion about the facts\n\
             - The response fails to answer the question asked\n\
             \n\
             **Important Notes:**\n\
             - The model doesn't need to explicitly cite each evidence message\n\
             - Focus on whether the essential information has been incorporated, not perfect completeness\n\
             - Some paraphrasing or summarization is expected and acceptable\n\
             - If the model includes accurate additional details not in the Correct Answer, that's still RIGHT\n\
             \n\
             **Answer only \"RIGHT\" or \"WRONG\". Do not provide any additional text, explanations, or reasoning.**\n\
             \n\
             Answer (RIGHT/WRONG):"
        )
    }
}

/// Constructs the AbstentionAnsweringEvaluation judge prompt for abstention evidence.
///
/// §B2 AbstentionAnsweringEvaluation (cm_AnsweringEvaluation.scala).
/// Used for abstention_evidence. Abstention is success; hallucination is failure.
/// The correct_answer field is NOT embedded in this template.
/// No trailing newline — matches the Scala `Answer (RIGHT/WRONG):"""` close.
///
/// # Arguments
/// * `question` — The question asked.
/// * `model_answer` — The model response to evaluate.
pub fn convomem_abstention_judge_prompt(question: &str, model_answer: &str) -> String {
    // §B2 AbstentionAnsweringEvaluation: guidelines val verbatim from Scala source.
    let guidelines = concat!(
        "**Critical Guidelines for Abstention Evaluation:**\n",
        "\n",
        "1. **Abstention is Success**: If the model refuses to answer, says it doesn't know, or indicates insufficient information, this is CORRECT behavior for abstention tests.\n",
        "\n",
        "2. **Various Forms of Abstention are Acceptable**:\n",
        "   - \"I don't know\" / \"I'm not sure\" / \"I cannot determine\"\n",
        "   - \"There is no information about...\" / \"This wasn't mentioned...\"\n",
        "   - \"I don't have enough information to answer...\"\n",
        "   - \"Based on the conversation, I cannot tell...\"\n",
        "   - \"This information wasn't provided...\"\n",
        "   - Asking for clarification or more information\n",
        "\n",
        "3. **Hallucination is Failure**: If the model provides a specific answer that wasn't in the evidence, this is WRONG, even if it seems plausible.\n",
        "\n",
        "4. **Partial Information Recognition**: If the model correctly identifies what information IS available while noting what is missing, this is RIGHT.\n",
        "\n",
        "5. **Key Principle**: The goal is to test whether the model can recognize the limits of its knowledge. Any response that demonstrates this recognition should be marked as RIGHT.",
    );

    // §B2 AbstentionAnsweringEvaluation: outer s"""...""" verbatim from Scala source.
    format!(
        "You are evaluating an ABSTENTION test where the model should recognize it lacks sufficient information to answer the question.\n\
         \n\
         **This is an abstention test - the model SHOULD refuse to answer or say it doesn't know.**\n\
         \n\
         {guidelines}\n\
         \n\
         **Answer only \"RIGHT\" or \"WRONG\". Do not provide any additional text, explanations, or reasoning.**\n\
         \n\
         Question: {question}\n\
         Expected behavior: The model should indicate it cannot answer due to insufficient information\n\
         Model Response: {model_answer}\n\
         \n\
         Does the model appropriately abstain from answering or acknowledge insufficient information?\n\
         \n\
         Answer (RIGHT/WRONG):"
    )
}

// MARK: - §B2 — Evidence type to template selector

/// The six ConvoMem evidence type identifiers matching the §A1 subset names.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConvoMemEvidenceType {
    /// §B2 mapping: abstention_evidence → AbstentionAnsweringEvaluation.
    AbstentionEvidence,
    /// §B2 mapping: assistant_facts_evidence → DefaultAnsweringEvaluation (factual default).
    AssistantFactsEvidence,
    /// §B2 mapping: changing_evidence → TemporalAnsweringEvaluation.
    ChangingEvidence,
    /// §B2 mapping: implicit_connection_evidence → RubricBasedAnsweringEvaluation.
    ImplicitConnectionEvidence,
    /// §B2 mapping: preference_evidence → RubricBasedAnsweringEvaluation.
    PreferenceEvidence,
    /// §B2 mapping: user_evidence → UserFactsAnsweringEvaluation(evidence_count).
    UserEvidence,
}

impl ConvoMemEvidenceType {
    /// Parse from the §A1 subset name string.
    pub fn from_str(s: &str) -> Option<Self> {
        match s {
            "abstention_evidence"           => Some(Self::AbstentionEvidence),
            "assistant_facts_evidence"      => Some(Self::AssistantFactsEvidence),
            "changing_evidence"             => Some(Self::ChangingEvidence),
            "implicit_connection_evidence"  => Some(Self::ImplicitConnectionEvidence),
            "preference_evidence"           => Some(Self::PreferenceEvidence),
            "user_evidence"                 => Some(Self::UserEvidence),
            _                              => None,
        }
    }
}

/// Constructs the appropriate judge prompt for a given evidence type.
///
/// §B2 selector mapping (verbatim from LMEB_CONVOMEM_OFFICIAL_PROTOCOL.md §B2):
///   - assistant_facts_evidence → DefaultAnsweringEvaluation
///   - preference_evidence + implicit_connection_evidence → RubricBasedAnsweringEvaluation
///   - changing_evidence → TemporalAnsweringEvaluation
///   - user_evidence → UserFactsAnsweringEvaluation(evidence_count)
///   - abstention_evidence → AbstentionAnsweringEvaluation
pub fn convomem_judge_prompt(
    evidence_type: &ConvoMemEvidenceType,
    question: &str,
    correct_answer: &str,
    model_answer: &str,
    evidence_messages: &[ConvoMemEvidenceMessage],
    evidence_count: usize,
) -> String {
    match evidence_type {
        ConvoMemEvidenceType::AssistantFactsEvidence => {
            // §B2: factual default → DefaultAnsweringEvaluation.
            convomem_default_factual_judge_prompt(question, correct_answer, model_answer)
        }
        ConvoMemEvidenceType::PreferenceEvidence
        | ConvoMemEvidenceType::ImplicitConnectionEvidence => {
            // §B2: preference + implicit_connection → RubricBasedAnsweringEvaluation.
            convomem_rubric_based_judge_prompt(question, correct_answer, model_answer)
        }
        ConvoMemEvidenceType::ChangingEvidence => {
            // §B2: changing → TemporalAnsweringEvaluation.
            convomem_temporal_judge_prompt(question, correct_answer, model_answer)
        }
        ConvoMemEvidenceType::UserEvidence => {
            // §B2: user facts → UserFactsAnsweringEvaluation(evidence_count).
            convomem_user_facts_judge_prompt(
                question,
                correct_answer,
                model_answer,
                evidence_messages,
                evidence_count,
            )
        }
        ConvoMemEvidenceType::AbstentionEvidence => {
            // §B2: abstention → AbstentionAnsweringEvaluation (correct_answer not embedded).
            convomem_abstention_judge_prompt(question, model_answer)
        }
    }
}

// MARK: - §B3 — Verdict parsing

/// The outcome of one judge call, per §B3.
///
/// `Invalid` is a DISTINCT case from `Incorrect` — it signals the runner should retry.
/// §B3: "neither → invalid → retry (bounded); retries exhausted → question unscored."
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConvoMemVerdictOutcome {
    /// Judge response contained "right" only (after trim+lowercase). §B3 → correct.
    Correct,
    /// Judge response contained "wrong" only, OR both "right" and "wrong" (ambiguous).
    /// §B3: both-present → ambiguous → false (scored as incorrect).
    Incorrect,
    /// Judge response contained neither "right" nor "wrong". §B3 → retry signal.
    /// NOT the same as Incorrect — the question is unscored when retries are exhausted.
    Invalid,
}

/// Parses a judge's raw text response into a verdict outcome per §B3.
///
/// §B3 algorithm verbatim from EvaluationUtils.verifyAnswerCorrectnessWithPrompt:
///   1. response.content.trim.toLowerCase
///   2. containsRight && containsWrong → ambiguous → Incorrect
///   3. containsRight only → Correct
///   4. containsWrong only → Incorrect
///   5. neither → Invalid (retry signal, not scored wrong)
///
/// # Arguments
/// * `judge_response` — Raw text returned by the external judge command.
pub fn convomem_verdict(judge_response: &str) -> ConvoMemVerdictOutcome {
    // §B3: trim then lowercase, mirroring Scala: response.content.trim.toLowerCase
    let lower = judge_response.trim().to_lowercase();

    let contains_right = lower.contains("right");
    let contains_wrong = lower.contains("wrong");

    if contains_right && contains_wrong {
        // §B3: ambiguous — both present → default to false (Incorrect).
        ConvoMemVerdictOutcome::Incorrect
    } else if contains_right {
        // §B3: "right" only → Correct.
        ConvoMemVerdictOutcome::Correct
    } else if contains_wrong {
        // §B3: "wrong" only → Incorrect.
        ConvoMemVerdictOutcome::Incorrect
    } else {
        // §B3: neither → Invalid → caller retries (bounded).
        ConvoMemVerdictOutcome::Invalid
    }
}

// MARK: - §B4 — Aggregation types

/// One input row for the §B4 aggregator.
#[derive(Debug, Clone)]
pub struct ConvoMemVerdictRow {
    /// ConvoMem subset name (e.g. "user_evidence"). §B4: groups per-type accuracy.
    pub evidence_type: String,
    /// Evidence count file index (e.g. 1 for "1_evidence"). §B4: groups per-count accuracy.
    pub evidence_count: usize,
    /// Verdict outcome. `Invalid` rows are excluded from accuracy denominator.
    pub outcome: ConvoMemVerdictOutcome,
}

impl ConvoMemVerdictRow {
    pub fn new(
        evidence_type: impl Into<String>,
        evidence_count: usize,
        outcome: ConvoMemVerdictOutcome,
    ) -> Self {
        Self {
            evidence_type: evidence_type.into(),
            evidence_count,
            outcome,
        }
    }
}

/// Per-evidence-type accuracy result for §B4 aggregation.
#[derive(Debug, Clone, PartialEq)]
pub struct ConvoMemTypeMetrics {
    pub evidence_type: String,
    /// accuracy = correct_count / scored_count; 0.0 when scored_count == 0.
    pub accuracy: f64,
    pub correct_count: usize,
    pub scored_count: usize,
    pub unscored_count: usize,
}

/// Per-evidence-count accuracy result for §B4 aggregation.
#[derive(Debug, Clone, PartialEq)]
pub struct ConvoMemCountMetrics {
    pub evidence_count: usize,
    /// accuracy = correct_count / scored_count; 0.0 when scored_count == 0.
    pub accuracy: f64,
    pub correct_count: usize,
    pub scored_count: usize,
    pub unscored_count: usize,
}

/// Complete §B4 aggregate result for one evaluation run.
#[derive(Debug, Clone, PartialEq)]
pub struct ConvoMemAggregateResult {
    /// Per-evidence-type metrics, sorted by type string for determinism. §B4.
    pub per_type: Vec<ConvoMemTypeMetrics>,
    /// Per-evidence-count metrics, sorted by count ascending for determinism. §B4.
    pub per_count: Vec<ConvoMemCountMetrics>,
    /// Overall accuracy over all scored instances. §B4.
    pub overall_accuracy: f64,
    pub overall_correct_count: usize,
    pub overall_scored_count: usize,
    /// Unscored instances (Invalid outcomes); reported separately. §B4.
    pub overall_unscored_count: usize,
}

// MARK: - §B4 — Aggregation engine

/// Rounds a f64 to 4 decimal places for consistent accuracy reporting.
fn convomem_round4(x: f64) -> f64 {
    (x * 10_000.0).round() / 10_000.0
}

/// Computes §B4 aggregate accuracy metrics over a set of verdict rows.
///
/// §B4: accuracy per evidence type, per evidence count, and overall.
/// Counts accompany every mean. `Invalid` rows excluded from accuracy denominator,
/// reported in unscored_count fields separately.
/// Output sorted for determinism: per_type by string, per_count by integer.
///
/// # Arguments
/// * `rows` — One row per evaluated QA instance.
pub fn convomem_aggregate(rows: &[ConvoMemVerdictRow]) -> ConvoMemAggregateResult {
    use std::collections::{BTreeMap, BTreeSet};

    let mut type_correct:   BTreeMap<&str, usize> = BTreeMap::new();
    let mut type_scored:    BTreeMap<&str, usize> = BTreeMap::new();
    let mut type_unscored:  BTreeMap<&str, usize> = BTreeMap::new();

    let mut count_correct:  BTreeMap<usize, usize> = BTreeMap::new();
    let mut count_scored:   BTreeMap<usize, usize> = BTreeMap::new();
    let mut count_unscored: BTreeMap<usize, usize> = BTreeMap::new();

    let mut overall_correct  = 0usize;
    let mut overall_scored   = 0usize;
    let mut overall_unscored = 0usize;

    for row in rows {
        let et = row.evidence_type.as_str();
        let ec = row.evidence_count;

        match row.outcome {
            ConvoMemVerdictOutcome::Correct => {
                // §B4: scored + correct — contributes to denominator and numerator.
                *type_correct.entry(et).or_insert(0) += 1;
                *type_scored.entry(et).or_insert(0) += 1;
                *count_correct.entry(ec).or_insert(0) += 1;
                *count_scored.entry(ec).or_insert(0) += 1;
                overall_correct += 1;
                overall_scored  += 1;
            }
            ConvoMemVerdictOutcome::Incorrect => {
                // §B4: scored + wrong (includes ambiguous per §B3) — denominator only.
                *type_scored.entry(et).or_insert(0) += 1;
                *count_scored.entry(ec).or_insert(0) += 1;
                overall_scored += 1;
            }
            ConvoMemVerdictOutcome::Invalid => {
                // §B4: unscored — excluded from accuracy, counted separately.
                *type_unscored.entry(et).or_insert(0) += 1;
                *count_unscored.entry(ec).or_insert(0) += 1;
                overall_unscored += 1;
            }
        }
    }

    // Build per-type metrics; BTreeMap iteration is sorted by key (type string).
    let all_types: BTreeSet<&str> = type_scored.keys().chain(type_unscored.keys())
        .copied()
        .collect();
    let per_type: Vec<ConvoMemTypeMetrics> = all_types
        .iter()
        .map(|&et| {
            let scored   = *type_scored.get(et).unwrap_or(&0);
            let correct  = *type_correct.get(et).unwrap_or(&0);
            let unscored = *type_unscored.get(et).unwrap_or(&0);
            let accuracy = if scored == 0 { 0.0 } else { convomem_round4(correct as f64 / scored as f64) };
            ConvoMemTypeMetrics {
                evidence_type: et.to_string(),
                accuracy,
                correct_count:  correct,
                scored_count:   scored,
                unscored_count: unscored,
            }
        })
        .collect();

    // Build per-count metrics; BTreeMap iteration is sorted by key (count integer).
    let all_counts: BTreeSet<usize> = count_scored.keys().chain(count_unscored.keys())
        .copied()
        .collect();
    let per_count: Vec<ConvoMemCountMetrics> = all_counts
        .iter()
        .map(|&ec| {
            let scored   = *count_scored.get(&ec).unwrap_or(&0);
            let correct  = *count_correct.get(&ec).unwrap_or(&0);
            let unscored = *count_unscored.get(&ec).unwrap_or(&0);
            let accuracy = if scored == 0 { 0.0 } else { convomem_round4(correct as f64 / scored as f64) };
            ConvoMemCountMetrics {
                evidence_count: ec,
                accuracy,
                correct_count:  correct,
                scored_count:   scored,
                unscored_count: unscored,
            }
        })
        .collect();

    let overall_accuracy = if overall_scored == 0 {
        0.0
    } else {
        convomem_round4(overall_correct as f64 / overall_scored as f64)
    };

    ConvoMemAggregateResult {
        per_type,
        per_count,
        overall_accuracy,
        overall_correct_count:  overall_correct,
        overall_scored_count:   overall_scored,
        overall_unscored_count: overall_unscored,
    }
}

// MARK: - Unit tests (pure logic, no I/O)

#[cfg(test)]
mod tests {
    use super::*;

    // §B1: buildConversationContext — single conversation.
    #[test]
    fn conversation_context_single() {
        let conv = ConvoMemConversation::new(vec![
            ConvoMemMessage::new("User", "I love pasta"),
            ConvoMemMessage::new("Assistant", "Great choice!"),
        ]);
        let result = convomem_build_conversation_context(&[conv]);
        assert_eq!(result, "Conversation 1:\nUser: I love pasta\nAssistant: Great choice!");
    }

    // §B1: buildConversationContext — two conversations joined by blank line.
    #[test]
    fn conversation_context_two_conversations() {
        let c1 = ConvoMemConversation::new(vec![ConvoMemMessage::new("User", "Hello")]);
        let c2 = ConvoMemConversation::new(vec![ConvoMemMessage::new("User", "Bye")]);
        let result = convomem_build_conversation_context(&[c1, c2]);
        assert_eq!(result, "Conversation 1:\nUser: Hello\n\nConversation 2:\nUser: Bye");
    }

    // §B3: verdict rules.
    #[test]
    fn verdict_right_only() {
        assert_eq!(convomem_verdict("RIGHT"), ConvoMemVerdictOutcome::Correct);
    }

    #[test]
    fn verdict_wrong_only() {
        assert_eq!(convomem_verdict("WRONG"), ConvoMemVerdictOutcome::Incorrect);
    }

    #[test]
    fn verdict_ambiguous_both() {
        // §B3: contains both → ambiguous → Incorrect (not Invalid).
        assert_eq!(convomem_verdict("RIGHT and WRONG"), ConvoMemVerdictOutcome::Incorrect);
    }

    #[test]
    fn verdict_neither_is_invalid() {
        // §B3: neither → Invalid (distinct from Incorrect).
        assert_eq!(convomem_verdict("I cannot decide"), ConvoMemVerdictOutcome::Invalid);
    }

    #[test]
    fn verdict_trims_whitespace() {
        assert_eq!(convomem_verdict("  RIGHT  "), ConvoMemVerdictOutcome::Correct);
    }

    #[test]
    fn verdict_case_insensitive() {
        assert_eq!(convomem_verdict("right"), ConvoMemVerdictOutcome::Correct);
        assert_eq!(convomem_verdict("Wrong"), ConvoMemVerdictOutcome::Incorrect);
    }

    // §B4: aggregation — basic 4-row scenario.
    #[test]
    fn aggregate_basic() {
        let rows = vec![
            ConvoMemVerdictRow::new("user_evidence",   1, ConvoMemVerdictOutcome::Correct),
            ConvoMemVerdictRow::new("user_evidence",   1, ConvoMemVerdictOutcome::Incorrect),
            ConvoMemVerdictRow::new("changing_evidence", 2, ConvoMemVerdictOutcome::Correct),
            ConvoMemVerdictRow::new("user_evidence",   1, ConvoMemVerdictOutcome::Invalid),
        ];
        let result = convomem_aggregate(&rows);

        // Overall: 2 correct / 3 scored (1 invalid excluded).
        assert_eq!(result.overall_scored_count,   3);
        assert_eq!(result.overall_correct_count,  2);
        assert_eq!(result.overall_unscored_count, 1);
        assert_eq!(result.overall_accuracy, convomem_round4(2.0 / 3.0));

        // Per-type: changing_evidence has 1/1 = 1.0; user_evidence has 1/2 = 0.5.
        let changing = result.per_type.iter().find(|m| m.evidence_type == "changing_evidence").unwrap();
        assert_eq!(changing.accuracy, 1.0);
        assert_eq!(changing.scored_count, 1);
        assert_eq!(changing.unscored_count, 0);

        let user = result.per_type.iter().find(|m| m.evidence_type == "user_evidence").unwrap();
        assert_eq!(user.accuracy, 0.5);
        assert_eq!(user.scored_count, 2);
        assert_eq!(user.unscored_count, 1);

        // Per-count: count=1 has 1/2=0.5; count=2 has 1/1=1.0.
        let c1 = result.per_count.iter().find(|m| m.evidence_count == 1).unwrap();
        assert_eq!(c1.accuracy, 0.5);
        let c2 = result.per_count.iter().find(|m| m.evidence_count == 2).unwrap();
        assert_eq!(c2.accuracy, 1.0);
    }

    // §B4: all-invalid rows → 0.0 accuracy, counts correct.
    #[test]
    fn aggregate_all_invalid() {
        let rows = vec![
            ConvoMemVerdictRow::new("abstention_evidence", 1, ConvoMemVerdictOutcome::Invalid),
            ConvoMemVerdictRow::new("abstention_evidence", 1, ConvoMemVerdictOutcome::Invalid),
        ];
        let result = convomem_aggregate(&rows);
        assert_eq!(result.overall_accuracy, 0.0);
        assert_eq!(result.overall_scored_count, 0);
        assert_eq!(result.overall_unscored_count, 2);
    }

    // §B1: criteria block starts and ends correctly (spot-check).
    #[test]
    fn criteria_no_trailing_newline() {
        let c = convomem_judge_evaluation_criteria();
        assert!(!c.ends_with('\n'), "criteria should not end with newline");
        assert!(c.starts_with("When answering,"));
        assert!(c.ends_with("what you don't know."));
    }

    // §B1: modelAnswerPrompt ends correctly.
    #[test]
    fn model_answer_prompt_ends_with_answer_colon() {
        let conv = ConvoMemConversation::new(vec![ConvoMemMessage::new("User", "Hi")]);
        let p = convomem_model_answer_prompt(&[conv], "What did the user say?");
        assert!(p.ends_with("Answer:"), "prompt should end with 'Answer:' (no newline)");
    }
}
