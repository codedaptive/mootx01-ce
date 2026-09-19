import Foundation

// LoCoMoSpecCorpus.swift — Spec-compliant LoCoMo corpus loader for the locomo-spec lane.
//
// Dataset: snap-research/locomo (ACL 2024, arXiv 2402.17753).
// Schema verified 2026-08-18 against locomo10.json.
// License: CC BY-NC 4.0 (NonCommercial) — internal diagnostic use only.
//
// KEY DIFFERENCES from LoCoMoCorpus.swift:
//
//   1. ALL 1,986 questions are included — category 5 (adversarial) and non-cat5
//      questions with empty evidence lists are NOT excluded. The locomo-spec lane
//      scores all categories per §3 of LOCOMO_OFFICIAL_PROTOCOL.md:
//        - Categories 2, 3, 4: single-answer F1 (§2).
//        - Category 1: multi-answer F1 (§2).
//        - Category 3: gold answer truncated at first ';' before scoring (§3).
//        - Category 5: binary abstention check (§3).
//
//   2. Image captions (blip_caption field) are preserved in turns. The §6
//      context-formatting rule appends ' and shared [caption]' to any turn
//      that carries a blip_caption.
//
//   3. Provides official context-formatting helpers per §6 of
//      LOCOMO_OFFICIAL_PROTOCOL.md (see "Context Formatting" section below).
//
// Expected totals when loading locomo10.json (verified 2026-08-18):
//   Total QAs:   1,986
//   Category 1:    282   (single_hop)
//   Category 2:    321   (temporal)
//   Category 3:     96   (multi_hop)
//   Category 4:    841   (open_domain)
//   Category 5:    446   (adversarial — no gold answer, scored by abstention)
//   Non-cat5 QAs with empty evidence: 4 (included in cat 1–4 counts above;
//     evidence recall per §4 appends 1 when evidence list is empty).

// MARK: - Turn

/// One turn in a LoCoMo conversation session, with optional image caption.
///
/// The blip_caption field is the BLIP-generated image description attached to
/// turns where the speaker shared an image. Per §6 context formatting:
/// '[speaker] said, "[text]"' with ' and shared [caption]' appended when present.
struct LoCoMoSpecTurn: Sendable {
    /// Speaker name (matches conversation.speaker_a or speaker_b).
    let speaker: String
    /// Unique turn identifier: format "D<session>:<turn>" (e.g. "D1:3").
    let diaID: String
    /// Turn text content.
    let text: String
    /// BLIP-generated image caption (nil when the turn contains no image).
    /// Source field: blip_caption in the JSON.
    let imageCaption: String?
}

// MARK: - Session

/// One session within a LoCoMo conversation, with date/time stamp.
struct LoCoMoSpecSession: Sendable {
    /// 1-based session number (from the session_N key).
    let sessionNumber: Int
    /// Timestamp string (e.g. "1:56 pm on 8 May, 2023"). May be empty if absent.
    let dateTime: String
    /// Turns in chronological order within this session.
    let turns: [LoCoMoSpecTurn]
}

// MARK: - Conversation

/// One conversation from the LoCoMo dataset: speakers, sessions, and a flattened turn view.
struct LoCoMoSpecConversation: Sendable {
    /// Unique conversation identifier (e.g. "conv-26").
    let sampleID: String
    /// Name of speaker A.
    let speakerA: String
    /// Name of speaker B.
    let speakerB: String
    /// Sessions in ascending session-number (chronological) order.
    let sessions: [LoCoMoSpecSession]

    /// Flat list of (sessionNumber, turn) pairs across all sessions, session order.
    /// Convenience accessor for callers that need a single-sequence view.
    var allTurns: [(sessionNumber: Int, turn: LoCoMoSpecTurn)] {
        sessions.flatMap { session in
            session.turns.map { turn in (session.sessionNumber, turn) }
        }
    }
}

// MARK: - Question

/// One question from the LoCoMo dataset, ALL categories included (1–5).
///
/// Category 5 (adversarial) questions have no gold answer (answer == nil)
/// and carry an adversarialAnswer for reference. Categories 1–4 always have
/// a gold answer. Non-cat5 questions with empty evidence lists are included
/// per the spec lane's "no exclusions" rule (evidence recall for those appends 1
/// per §4).
struct LoCoMoSpecQuestion: Sendable {
    /// Synthetic identifier: "<sampleID>_q<qaIndex>" (generated on load).
    let questionID: String
    /// Question text.
    let question: String
    /// Gold answer string. Nil only for category 5 (adversarial).
    /// For category 3 (multi_hop), the scorer truncates at the first ';' per §3
    /// at scoring time — the raw answer is stored here verbatim.
    let answer: String?
    /// Plausible-but-wrong answer. Non-nil only for category 5.
    let adversarialAnswer: String?
    /// dia_id strings containing answer evidence. May be empty for 4 non-cat5 questions.
    let evidence: [String]
    /// Question type per §3: 1=single_hop, 2=temporal, 3=multi_hop, 4=open_domain,
    /// 5=adversarial.
    let category: Int
    /// Index into the parent LoCoMoSpecCorpus.conversations array.
    let conversationIndex: Int
    /// Sample ID of the parent conversation (for logging).
    let sampleID: String

    /// Human-readable category label for report breakdowns.
    var categoryLabel: String {
        switch category {
        case 1: return "single_hop"
        case 2: return "temporal"
        case 3: return "multi_hop"
        case 4: return "open_domain"
        case 5: return "adversarial"
        default: return "unknown_\(category)"
        }
    }
}

// MARK: - Corpus

/// The result of loading the LoCoMo dataset in spec-compliant mode.
///
/// All 1,986 questions are present in `questions`; nothing is excluded.
/// `categoryCounts` is indexed 1–5 and gives the raw count per category.
struct LoCoMoSpecCorpus: Sendable {
    /// All conversations loaded from the file (10 in the standard dataset).
    let conversations: [LoCoMoSpecConversation]
    /// All questions from the file — categories 1–5, empty-evidence included.
    let questions: [LoCoMoSpecQuestion]
    /// Questions per category (key = category 1–5, value = count).
    /// Verified against the official dataset: {1:282, 2:321, 3:96, 4:841, 5:446}.
    let categoryCounts: [Int: Int]
    /// Total questions (must equal questions.count).
    var totalCount: Int { questions.count }
}

// MARK: - Load error

/// Loader error with a description naming the missing/mistyped field and context.
/// Parallel to LoCoMoLoadError.
struct LoCoMoSpecLoadError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Raw decode types

/// Raw codec for a single turn. Captures blip_caption for §6 context formatting.
private struct LoCoMoSpecTurnRaw: Decodable {
    let speaker: String
    let dia_id: String
    let text: String
    /// Optional BLIP-generated image caption. Present only on turns with an image.
    let blip_caption: String?
    // img_url, query — optional, not used beyond presence detection
}

/// Raw codec for one conversation object. The session_N / session_N_date_time keys
/// are extracted via a dynamic dict, identically to LoCoMoCorpus.
private struct LoCoMoSpecSampleRaw: Decodable {
    let sample_id: String
    let conversation: LoCoMoSpecConversationDict
    let qa: [LoCoMoSpecQARaw]
    // event_summary, observation, session_summary — present, not used
}

/// Heterogeneous conversation dict containing speaker_a, speaker_b,
/// session_N, session_N_date_time, and variant keys.
private struct LoCoMoSpecConversationDict: Decodable {
    let speakerA: String
    let speakerB: String
    let sessions: [LoCoMoSpecSession]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicSpecKey.self)

        let speakerAKey = DynamicSpecKey(stringValue: "speaker_a")!
        let speakerBKey = DynamicSpecKey(stringValue: "speaker_b")!
        self.speakerA = try container.decode(String.self, forKey: speakerAKey)
        self.speakerB = try container.decode(String.self, forKey: speakerBKey)

        // Collect session_N keys (numeric suffix only — skip _date_time, _observation,
        // _summary variants).
        var sessionsMap: [Int: (dateTime: String, turns: [LoCoMoSpecTurnRaw])] = [:]
        for key in container.allKeys {
            let k = key.stringValue
            guard k.hasPrefix("session_") else { continue }
            let suffix = k.dropFirst("session_".count)
            guard let n = Int(suffix) else { continue }
            // Decode the turns array for session N, capturing blip_caption.
            let turnsRaw = try container.decode([LoCoMoSpecTurnRaw].self, forKey: key)
            let dtKey = DynamicSpecKey(stringValue: "session_\(n)_date_time")!
            let dt = (try? container.decode(String.self, forKey: dtKey)) ?? ""
            sessionsMap[n] = (dateTime: dt, turns: turnsRaw)
        }

        self.sessions = sessionsMap
            .sorted(by: { $0.key < $1.key })
            .map { (n, value) in
                let turns = value.turns.map { raw in
                    LoCoMoSpecTurn(
                        speaker: raw.speaker,
                        diaID: raw.dia_id,
                        text: raw.text,
                        imageCaption: raw.blip_caption
                    )
                }
                return LoCoMoSpecSession(
                    sessionNumber: n,
                    dateTime: value.dateTime,
                    turns: turns
                )
            }
    }
}

/// Dynamic CodingKey for the heterogeneous conversation dict.
private struct DynamicSpecKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Raw codec for one QA pair.
/// answer can be String, Number, or absent (category 5 adversarial).
/// adversarial_answer is present only for category 5.
private struct LoCoMoSpecQARaw: Decodable {
    let question: String
    let evidence: [String]
    let category: Int
    /// Nil for category 5 (absent from JSON) or when null.
    let answer: String?
    /// Non-nil for category 5 only.
    let adversarial_answer: String?

    enum CodingKeys: String, CodingKey {
        case question, evidence, category, answer, adversarial_answer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.question         = try c.decode(String.self, forKey: .question)
        self.evidence         = try c.decode([String].self, forKey: .evidence)
        self.category         = try c.decode(Int.self, forKey: .category)
        self.adversarial_answer = try? c.decode(String.self, forKey: .adversarial_answer)

        // Normalise answer: String | Int | Double | absent → String | nil.
        if let s = try? c.decode(String.self, forKey: .answer) {
            self.answer = s
        } else if let n = try? c.decode(Int.self, forKey: .answer) {
            self.answer = String(n)
        } else if let d = try? c.decode(Double.self, forKey: .answer) {
            self.answer = String(d)
        } else {
            self.answer = nil   // absent or null — expected for category 5
        }
    }
}

// MARK: - Loader

/// Loads the LoCoMo dataset in spec-compliant mode: ALL questions included,
/// image captions preserved, no category or evidence exclusions.
///
/// Per LOCOMO_OFFICIAL_PROTOCOL.md §3 and §7 deviation note #2:
/// category 5 is scored (not excluded); 4 non-cat5 questions with empty evidence
/// are included (evidence recall appends 1 per §4 when evidence is empty).
///
/// - Parameter url: Path to locomo10.json (or a compatible fixture).
/// - Returns: LoCoMoSpecCorpus with all conversations and all questions.
/// - Throws: LoCoMoSpecLoadError naming the offending field and sample index.
func loadLoCoMoSpecCorpus(from url: URL) throws -> LoCoMoSpecCorpus {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw LoCoMoSpecLoadError(
            description: "LoCoMoSpec: could not read '\(url.path)': \(error)")
    }

    let rawSamples: [LoCoMoSpecSampleRaw]
    do {
        rawSamples = try JSONDecoder().decode([LoCoMoSpecSampleRaw].self, from: data)
    } catch let decodingError {
        throw LoCoMoSpecLoadError(
            description: "LoCoMoSpec JSON decode failed at top level: \(decodingError)")
    }

    var conversations: [LoCoMoSpecConversation] = []
    var questions: [LoCoMoSpecQuestion] = []
    var categoryCounts: [Int: Int] = [:]

    for (sampleIndex, raw) in rawSamples.enumerated() {
        guard !raw.sample_id.isEmpty else {
            throw LoCoMoSpecLoadError(
                description: "sample[\(sampleIndex)]: missing/empty 'sample_id'")
        }

        let conv = raw.conversation
        guard !conv.sessions.isEmpty else {
            throw LoCoMoSpecLoadError(
                description: "sample[\(sampleIndex)] id='\(raw.sample_id)': " +
                "'conversation' has no sessions (expected session_1 at minimum)")
        }
        guard !conv.speakerA.isEmpty else {
            throw LoCoMoSpecLoadError(
                description: "sample[\(sampleIndex)] id='\(raw.sample_id)': " +
                "missing/empty 'speaker_a'")
        }
        guard !conv.speakerB.isEmpty else {
            throw LoCoMoSpecLoadError(
                description: "sample[\(sampleIndex)] id='\(raw.sample_id)': " +
                "missing/empty 'speaker_b'")
        }

        let conversationIndex = conversations.count
        conversations.append(LoCoMoSpecConversation(
            sampleID: raw.sample_id,
            speakerA: conv.speakerA,
            speakerB: conv.speakerB,
            sessions: conv.sessions
        ))

        // Include ALL QA pairs — no exclusion for category 5 or empty evidence.
        for (qaIndex, qa) in raw.qa.enumerated() {
            guard !qa.question.isEmpty else {
                throw LoCoMoSpecLoadError(
                    description: "sample[\(sampleIndex)] id='\(raw.sample_id)' " +
                    "qa[\(qaIndex)]: missing/empty 'question'")
            }
            guard qa.category >= 1 && qa.category <= 5 else {
                throw LoCoMoSpecLoadError(
                    description: "sample[\(sampleIndex)] id='\(raw.sample_id)' " +
                    "qa[\(qaIndex)]: unexpected 'category' \(qa.category) (expected 1-5)")
            }

            let questionID = "\(raw.sample_id)_q\(qaIndex)"
            questions.append(LoCoMoSpecQuestion(
                questionID: questionID,
                question: qa.question,
                answer: qa.answer,
                adversarialAnswer: qa.adversarial_answer,
                evidence: qa.evidence,
                category: qa.category,
                conversationIndex: conversationIndex,
                sampleID: raw.sample_id
            ))
            categoryCounts[qa.category, default: 0] += 1
        }
    }

    return LoCoMoSpecCorpus(
        conversations: conversations,
        questions: questions,
        categoryCounts: categoryCounts
    )
}

// MARK: - Context Formatting (§6)
//
// Official prompt context per LOCOMO_OFFICIAL_PROTOCOL.md §6.
// Both Swift and Rust ports produce byte-identical output for the same input.

/// Returns the official conversation preamble with speaker names substituted.
///
/// Verbatim from §6 (including the official typo 'wriiten'):
/// "Below is a conversation between two people: {A} and {B}. The conversation
///  takes place over multiple days and the date of each conversation is wriiten
///  at the beginning of the conversation."
///
/// - Parameters:
///   - speakerA: Name of the first speaker (substituted into first {}).
///   - speakerB: Name of the second speaker (substituted into second {}).
/// - Returns: The formatted preamble string (no trailing newline).
func loCoMoConversationPreamble(speakerA: String, speakerB: String) -> String {
    // §6 preamble — 'wriiten' typo is in the official prompt; reproduce verbatim.
    "Below is a conversation between two people: \(speakerA) and \(speakerB). " +
    "The conversation takes place over multiple days and the date of each " +
    "conversation is wriiten at the beginning of the conversation."
}

/// Returns the session header line per §6 format.
///
/// Format: "DATE: [dateTime] CONVERSATION:"
///
/// - Parameter dateTime: The session timestamp string (e.g. "1:56 pm on 8 May, 2023").
/// - Returns: The formatted header string (no trailing newline).
func loCoMoSessionHeader(dateTime: String) -> String {
    "DATE: \(dateTime) CONVERSATION:"
}

/// Returns the formatted turn line per §6 format.
///
/// Format: '[speaker] said, "[text]"' with ' and shared [caption]' appended
/// when the turn has an imageCaption (blip_caption in JSON).
///
/// - Parameter turn: The turn to format.
/// - Returns: The formatted turn string (no trailing newline).
func loCoMoFormatTurn(_ turn: LoCoMoSpecTurn) -> String {
    var line = "\(turn.speaker) said, \"\(turn.text)\""
    // §6: append ' and shared [caption]' for image turns.
    if let caption = turn.imageCaption {
        line += " and shared \(caption)"
    }
    return line
}

/// Returns the full formatted context for a conversation per §6.
///
/// Structure:
///   {preamble}\n
///   DATE: [session1_datetime] CONVERSATION:\n
///   [turn]\n
///   ...\n
///   DATE: [session2_datetime] CONVERSATION:\n
///   ...
///
/// Sessions are in chronological (ascending session-number) order, matching
/// the sorted order in LoCoMoSpecConversation.sessions. The string ends with
/// a trailing newline after the last turn.
///
/// - Parameter conversation: The conversation to format.
/// - Returns: The complete context string.
func loCoMoFormatContext(_ conversation: LoCoMoSpecConversation) -> String {
    var out = loCoMoConversationPreamble(
        speakerA: conversation.speakerA,
        speakerB: conversation.speakerB
    )
    out += "\n"
    for session in conversation.sessions {
        out += loCoMoSessionHeader(dateTime: session.dateTime)
        out += "\n"
        for turn in session.turns {
            out += loCoMoFormatTurn(turn)
            out += "\n"
        }
    }
    return out
}
