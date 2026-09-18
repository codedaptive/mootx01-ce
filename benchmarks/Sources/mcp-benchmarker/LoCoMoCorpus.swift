import Foundation

// LoCoMoCorpus.swift — Loads and validates the LoCoMo dataset.
//
// Schema verified 2026-07-26 against snap-research/locomo on GitHub.
// Dataset: https://github.com/snap-research/locomo — locomo10.json
// License: CC BY-NC 4.0 (NonCommercial) — for internal diagnostic use only.
//
// The dataset is never committed; see scripts/fetch-locomo.sh to download.
//
// Top-level structure: JSON array of 10 conversation objects.
//
// Per-conversation fields:
//   sample_id:        String   — unique conversation identifier (e.g. "conv-26")
//   conversation:     Object   — dict with speaker_a, speaker_b, session_N,
//                               session_N_date_time keys (N = 1..max_session)
//   qa:               [Object] — question-answer annotation list
//   event_summary:    Object   — session event summaries (not used here)
//   observation:      Object   — session observations (not used here)
//   session_summary:  Object   — session summaries (not used here)
//
// conversation dict:
//   speaker_a:              String — name of the first speaker
//   speaker_b:              String — name of the second speaker
//   session_N:              [Turn] — turns for session N (N = 1-based integer)
//   session_N_date_time:    String — timestamp for session N (e.g. "1:56 pm on 8 May, 2023")
//
// Turn fields:
//   speaker:    String — speaker name (matches speaker_a or speaker_b)
//   dia_id:     String — unique turn identifier, format "D<session>:<turn>"
//                        (e.g. "D1:3" = session 1, 3rd dialog)
//   text:       String — turn content
//   (optional) img_url, blip_caption, query — image metadata (not used here)
//
// QA fields:
//   question:           String — the question text
//   answer:             String/Number/absent — reference answer
//                       Absent (category 5 = adversarial) — excluded from scoring
//   evidence:           [String] — dia_id strings that contain the answer evidence
//   category:           Int 1-5 — question type:
//                         1 = single-hop explicit memory
//                         2 = temporal reasoning
//                         3 = multi-hop / knowledge reasoning
//                         4 = open-domain (with evidence in conversation)
//                         5 = adversarial (no answer — excluded from scoring)
//   adversarial_answer: String — plausible-but-wrong answer (category 5 only)
//
// Category 5 questions (adversarial, no ground-truth answer) are EXCLUDED
// from retrieval scoring, exactly as LongMemEval excludes abstention questions.
//
// Total statistics (verified 2026-07-26):
//   - 10 conversations, 1,986 total QAs
//   - 1,542 scoreable (categories 1-4)
//   - 444 adversarial (category 5, excluded)

// MARK: - Turn types

/// One turn in a LoCoMo conversation session.
struct LoCoMoTurn: Codable, Sendable {
    /// Speaker name (matches conversation.speaker_a or speaker_b).
    let speaker: String
    /// Unique turn identifier: format "D<session>:<turn>" (e.g. "D1:3").
    let diaID: String
    /// Turn text content.
    let text: String

    enum CodingKeys: String, CodingKey {
        case speaker
        case diaID = "dia_id"
        case text
    }
}

// MARK: - Session

/// One session within a LoCoMo conversation.
struct LoCoMoSession: Sendable {
    /// 1-based session number (from the `session_N` key).
    let sessionNumber: Int
    /// Timestamp string for this session (e.g. "1:56 pm on 8 May, 2023").
    let dateTime: String
    /// Turns in chronological order within this session.
    let turns: [LoCoMoTurn]
}

// MARK: - Conversation

/// One conversation from the LoCoMo dataset, containing sessions and Q&A pairs.
struct LoCoMoConversation: Sendable {
    /// Unique conversation identifier (e.g. "conv-26").
    let sampleID: String
    /// Name of speaker A.
    let speakerA: String
    /// Name of speaker B.
    let speakerB: String
    /// Sessions in ascending session-number order.
    let sessions: [LoCoMoSession]
    /// Flat list of all turns across all sessions, in session order.
    /// Used by the runner for full-conversation ingest.
    var allTurns: [(sessionNumber: Int, turn: LoCoMoTurn)] {
        sessions.flatMap { session in
            session.turns.map { turn in (session.sessionNumber, turn) }
        }
    }
}

// MARK: - Question

/// One scored question from the LoCoMo dataset.
/// Category 5 (adversarial) questions are excluded before reaching this type.
struct LoCoMoQuestion: Sendable {
    /// Synthetic question identifier: "<sampleID>_q<index>" (generated on load).
    let questionID: String
    /// Question text.
    let question: String
    /// Reference answer (may be a string representation of a number).
    let answer: String
    /// List of dia_id strings that contain evidence for this answer.
    /// Format: ["D1:3", "D2:5"] — session number and dialog number.
    let evidence: [String]
    /// Category: 1=single_hop, 2=temporal, 3=multi_hop, 4=open_domain.
    let category: Int
    /// Index into the parent LoCoMoCorpus.conversations array.
    /// Used by the runner to look up the full conversation for ingest.
    let conversationIndex: Int
    /// Sample ID for logging (same as the conversation's sampleID).
    let sampleID: String

    /// Category label for report breakdowns.
    var categoryLabel: String {
        switch category {
        case 1: return "single_hop"
        case 2: return "temporal"
        case 3: return "multi_hop"
        case 4: return "open_domain"
        default: return "unknown_\(category)"
        }
    }
}

// MARK: - Corpus

/// The result of loading the LoCoMo dataset.
struct LoCoMoCorpus: Sendable {
    /// All 10 (or fewer) conversations loaded from the file.
    let conversations: [LoCoMoConversation]
    /// Non-adversarial questions (categories 1-4), in file order.
    /// Each question carries a `conversationIndex` into `conversations`.
    let questions: [LoCoMoQuestion]
    /// Number of adversarial questions excluded (category 5).
    let adversarialCount: Int
    /// Total questions in the file (questions.count + adversarialCount).
    var totalCount: Int { questions.count + adversarialCount }
}

// MARK: - Load error

/// Loader error carrying the missing/mistyped field name and sample/QA index.
/// Parallel to LMELoadError.
struct LoCoMoLoadError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Raw decode types

/// Raw codec for a single turn. Optional image fields are ignored.
private struct LoCoMoTurnRaw: Decodable {
    let speaker: String
    let dia_id: String
    let text: String
    // img_url, blip_caption, query are optional and not used by the benchmarker.
}

/// Raw codec for one conversation object. The conversation's sessions are decoded
/// by extracting `session_N` / `session_N_date_time` keys from the dynamic dict.
private struct LoCoMoSampleRaw: Decodable {
    let sample_id: String
    let conversation: ConversationDict
    let qa: [LoCoMoQARaw]

    // event_summary, observation, session_summary are present but not used.
}

/// The `conversation` field is a heterogeneous dict whose keys include
/// `speaker_a`, `speaker_b`, `session_N`, `session_N_date_time`, and optional
/// `session_N_observation`, `session_N_summary` keys. We decode it by treating
/// it as a flat `[String: JSONValue]` map and extracting what we need.
private struct ConversationDict: Decodable {
    let speakerA: String
    let speakerB: String
    /// Parsed sessions in the order they appear (sorted by session number after decode).
    let sessions: [LoCoMoSession]

    // Custom decode: pull speaker_a/speaker_b as strings, then find all
    // `session_N` and `session_N_date_time` keys.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        // Decode speaker names.
        let speakerAKey = DynamicCodingKey(stringValue: "speaker_a")!
        let speakerBKey = DynamicCodingKey(stringValue: "speaker_b")!
        self.speakerA = try container.decode(String.self, forKey: speakerAKey)
        self.speakerB = try container.decode(String.self, forKey: speakerBKey)

        // Collect all session keys. Each session N contributes:
        //   session_N          — [LoCoMoTurnRaw]
        //   session_N_date_time — String (optional: some sessions may omit this)
        var sessionsMap: [Int: (dateTime: String, turns: [LoCoMoTurnRaw])] = [:]
        for key in container.allKeys {
            let k = key.stringValue
            if k.hasPrefix("session_") && !k.hasSuffix("_date_time")
                && !k.hasSuffix("_observation") && !k.hasSuffix("_summary") {
                // Extract session number: "session_3" → 3
                let suffix = k.dropFirst("session_".count)
                guard let n = Int(suffix) else { continue }
                let turns = try container.decode([LoCoMoTurnRaw].self, forKey: key)
                // dateTime may be absent (e.g. partial dataset variants).
                let dtKey = DynamicCodingKey(stringValue: "session_\(n)_date_time")!
                let dt = (try? container.decode(String.self, forKey: dtKey)) ?? ""
                sessionsMap[n] = (dateTime: dt, turns: turns)
            }
        }

        // Build sessions sorted by session number.
        self.sessions = sessionsMap.sorted(by: { $0.key < $1.key }).map { (n, value) in
            let turns = value.turns.map { raw in
                LoCoMoTurn(speaker: raw.speaker, diaID: raw.dia_id, text: raw.text)
            }
            return LoCoMoSession(sessionNumber: n, dateTime: value.dateTime, turns: turns)
        }
    }
}

/// Dynamic CodingKey for heterogeneous dict decode.
private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

/// Raw codec for one QA pair.
private struct LoCoMoQARaw: Decodable {
    let question: String
    /// Answer may be absent (category 5), a string, or a number.
    let answer: String?
    let evidence: [String]
    let category: Int

    enum CodingKeys: String, CodingKey {
        case question, evidence, category
        case answer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.question = try c.decode(String.self, forKey: .question)
        self.evidence = try c.decode([String].self, forKey: .evidence)
        self.category = try c.decode(Int.self, forKey: .category)
        // `answer` is absent for category 5 (adversarial). Normalise to String.
        if let s = try? c.decode(String.self, forKey: .answer) {
            self.answer = s
        } else if let n = try? c.decode(Int.self, forKey: .answer) {
            self.answer = String(n)
        } else if let d = try? c.decode(Double.self, forKey: .answer) {
            self.answer = String(d)
        } else {
            self.answer = nil   // absent or null — category 5 adversarial
        }
    }
}

// MARK: - Loader

/// Loads the LoCoMo dataset from a single JSON file, validates the schema, and
/// returns all conversations plus the flat list of scoreable questions.
///
/// Category 5 (adversarial) questions are excluded from `questions`; their count
/// is in `adversarialCount`. QAs with empty evidence lists are also excluded
/// (4 known in the dataset; they cannot be evaluated by retrieval scoring).
///
/// - Parameter url: Path to `locomo10.json` (or equivalent).
/// - Throws: `LoCoMoLoadError` naming the missing/mistyped field and the
///   zero-based sample index, matching the style of `LMELoadError`.
func loadLoCoMoCorpus(from url: URL) throws -> LoCoMoCorpus {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw LoCoMoLoadError(
            description: "LoCoMo: could not read '\(url.path)': \(error)")
    }

    let rawSamples: [LoCoMoSampleRaw]
    do {
        rawSamples = try JSONDecoder().decode([LoCoMoSampleRaw].self, from: data)
    } catch let decodingError {
        throw LoCoMoLoadError(
            description: "LoCoMo JSON decode failed at top level: \(decodingError)")
    }

    var conversations: [LoCoMoConversation] = []
    var questions: [LoCoMoQuestion] = []
    var adversarialCount = 0

    for (sampleIndex, raw) in rawSamples.enumerated() {
        // Validate sample_id.
        guard !raw.sample_id.isEmpty else {
            throw LoCoMoLoadError(
                description: "sample[\(sampleIndex)]: missing/empty 'sample_id'")
        }

        let conv = raw.conversation
        // Validate at least one session is present.
        guard !conv.sessions.isEmpty else {
            throw LoCoMoLoadError(
                description: "sample[\(sampleIndex)] id='\(raw.sample_id)': " +
                "'conversation' has no sessions (expected session_1 at minimum)")
        }
        // Validate speaker names.
        guard !conv.speakerA.isEmpty else {
            throw LoCoMoLoadError(
                description: "sample[\(sampleIndex)] id='\(raw.sample_id)': " +
                "missing/empty 'speaker_a'")
        }
        guard !conv.speakerB.isEmpty else {
            throw LoCoMoLoadError(
                description: "sample[\(sampleIndex)] id='\(raw.sample_id)': " +
                "missing/empty 'speaker_b'")
        }

        let conversationIndex = conversations.count
        conversations.append(LoCoMoConversation(
            sampleID: raw.sample_id,
            speakerA: conv.speakerA,
            speakerB: conv.speakerB,
            sessions: conv.sessions
        ))

        // Parse QA pairs; exclude adversarial (cat 5) and empty-evidence questions.
        for (qaIndex, qa) in raw.qa.enumerated() {
            guard !qa.question.isEmpty else {
                throw LoCoMoLoadError(
                    description: "sample[\(sampleIndex)] id='\(raw.sample_id)' " +
                    "qa[\(qaIndex)]: missing/empty 'question'")
            }
            guard qa.category >= 1 && qa.category <= 5 else {
                throw LoCoMoLoadError(
                    description: "sample[\(sampleIndex)] id='\(raw.sample_id)' " +
                    "qa[\(qaIndex)]: unexpected 'category' \(qa.category) (expected 1-5)")
            }

            // Exclude adversarial questions — they have no ground-truth answer
            // and cannot be evaluated by retrieval scoring.
            if qa.category == 5 {
                adversarialCount += 1
                continue
            }

            // Exclude QAs with no evidence (4 known in dataset — cannot be scored).
            guard !qa.evidence.isEmpty else {
                // Count as adversarial-equivalent: excluded from scoring.
                adversarialCount += 1
                continue
            }

            let questionID = "\(raw.sample_id)_q\(qaIndex)"
            questions.append(LoCoMoQuestion(
                questionID: questionID,
                question: qa.question,
                answer: qa.answer ?? "",
                evidence: qa.evidence,
                category: qa.category,
                conversationIndex: conversationIndex,
                sampleID: raw.sample_id
            ))
        }
    }

    return LoCoMoCorpus(
        conversations: conversations,
        questions: questions,
        adversarialCount: adversarialCount
    )
}
