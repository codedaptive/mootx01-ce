import Foundation

// MemBenchCorpus.swift — Loads and validates the MemBench dataset.
//
// Dataset: MemBench (arXiv 2506.21605, ACL Findings 2025)
// Paper: "MemBench: Towards More Comprehensive Evaluation on the Memory of LLM-based Agents"
// Repo: https://github.com/import-myself/Membench
// License: see repo (no explicit license file found; for internal diagnostic use only)
//
// The dataset is never committed; see scripts/fetch-membench.sh to download.
//
// SCHEMA (verified 2026-08-06 by partial download of MemData/FirstAgent/simple.json):
//
// File layout: MemData/{FirstAgent,ThirdAgent}/<category>.json
//
// Top-level: JSON object with one or more topic keys.
//   - In practice, simple.json has a single key "roles".
//   - The loader treats all top-level array values as topic groups.
//   Key → array of items: { tid, message_list, QA }
//
// Per-item fields:
//   tid:          Integer — unique item index within the file/topic
//   message_list: [[Turn]]  — array of sessions, each session is an array of turns
//   QA:           Object    — single question-answer pair
//
// Turn fields (verified):
//   sid:               Integer — GLOBAL sequential turn ID across all sessions in the item
//                               (session 0 has sids 0–19, session 1 has sids 20–40, etc.)
//   user_message:      String  — user's utterance
//   assistant_message: String  — assistant's response
//   time:              String  — timestamp of the exchange
//   place:             String  — location context
//
// QA fields (verified):
//   qid:             Integer       — question ID within the item
//   question:        String        — question text
//   answer:          String        — verbatim answer text
//   target_step_id:  [[Int, Int]]  — each pair is [global_sid, session_idx]
//                                   where global_sid uniquely identifies the evidence turn
//                                   and session_idx is the 0-based session index (redundant,
//                                   for verification). Verified for tid=0: sid=119 is in
//                                   session 5, and target_step_id = [[119, 5]].
//   choices:         Object        — A/B/C/D answer choices
//   ground_truth:    String        — correct answer letter (A, B, C, or D)
//   time:            String        — timestamp associated with the question
//
// Categories (FirstAgent):
//   LowLevel:  simple, comparative, aggregative, conditional, knowledge_update,
//              post_processing, noisy
//   HighLevel: highlevel, highlevel_rec, lowlevel_rec, RecMultiSession
//
// Scoring: retrieval recall (recall-any@k / recall-all@k / MRR) using target_step_id
// evidence, plus optional multiple-choice accuracy when a judge is provided.

// MARK: - Turn

/// One conversational exchange in a MemBench session.
struct MemBenchTurn: Sendable, Codable {
    /// Step ID for this turn. Sequential within the item's message_list but NOT
    /// unique: a turn that restates an earlier step repeats its sid. Seed-file
    /// record IDs therefore append the ingest index (see `memBenchRecordID`).
    let sid: Int
    /// The user's message text.
    let userMessage: String
    /// The assistant's response text.
    let assistantMessage: String
    /// Timestamp string for this exchange.
    let time: String
    /// Location context for this exchange.
    let place: String

    enum CodingKeys: String, CodingKey {
        case sid
        case userMessage      = "user_message"
        case assistantMessage = "assistant_message"
        case time
        case place
    }
}

// MARK: - Session

/// One session within a MemBench item's conversation.
struct MemBenchSession: Sendable {
    /// 0-based index of this session within the item's message_list.
    let sessionIndex: Int
    /// Turns in this session, in chronological order.
    let turns: [MemBenchTurn]
}

// MARK: - QA

/// A multiple-choice question from the MemBench dataset.
struct MemBenchQA: Sendable {
    /// Question ID within the item.
    let qid: Int
    /// Question text.
    let question: String
    /// Verbatim answer text.
    let answer: String
    /// Evidence turns: each pair is (global_sid, session_idx). Use global_sid
    /// to identify the target turn uniquely — it matches the turn's sid field
    /// and is stable across session restructuring.
    let targetStepID: [(globalSid: Int, sessionIdx: Int)]
    /// Multiple-choice options. Keys are the letter labels (A, B, C, D).
    let choices: [String: String]
    /// Correct answer letter (A, B, C, or D).
    let groundTruth: String
    /// Timestamp string associated with the question.
    let time: String
}

// MARK: - Item

/// One scored item from the MemBench dataset.
struct MemBenchItem: Sendable {
    /// Synthetic item identifier: "<category>/<topicKey>/<tid>".
    let itemID: String
    /// Category label (e.g. "simple", "noisy", "highlevel").
    let category: String
    /// Agent perspective ("FirstAgent" or "ThirdAgent").
    let agent: String
    /// Topic key within the file (e.g. "roles").
    let topicKey: String
    /// 0-based item index within the topic.
    let tid: Int
    /// Sessions in the conversation, in order.
    let sessions: [MemBenchSession]
    /// The single QA pair for this item.
    let qa: MemBenchQA

    /// Flat list of all turns across all sessions, in session order.
    var allTurns: [MemBenchTurn] {
        sessions.flatMap(\.turns)
    }

    /// Set of global sids that contain evidence for the question.
    /// These are the turn IDs the retrieval scorer checks against.
    var evidenceSids: [String] {
        qa.targetStepID.map { String($0.globalSid) }
    }
}

// MARK: - Corpus

/// The result of loading one or more MemBench category files.
struct MemBenchCorpus: Sendable {
    /// All items loaded, in file order.
    let items: [MemBenchItem]
    /// Number of items skipped (missing QA, empty sessions, etc.).
    let skippedCount: Int
    /// Total items in the source files (items.count + skippedCount).
    var totalCount: Int { items.count + skippedCount }
}

// MARK: - Load error

/// Loader error with field name and item context.
struct MemBenchLoadError: Error, CustomStringConvertible {
    let description: String
}

// MARK: - Raw decode types

/// Raw codec for one turn object.
private struct MemBenchTurnRaw: Decodable {
    let sid: Int
    let user_message: String
    let assistant_message: String
    let time: String?
    let place: String?
}

/// Raw codec for a ThirdAgent record.
///
/// ThirdAgent is a DIFFERENT TASK SHAPE, not another view of FirstAgent. There
/// is no assistant: each record is one observed assertion about a third party,
/// carrying the relation/attribute/value triple the statement encodes. The
/// records sit in a FLAT array rather than nested sessions.
///
///   FirstAgent turn: sid, user_message, assistant_message, time, place
///   ThirdAgent record: mid, message, time, place, rel, attr, value
///
/// The loader below maps these onto the same MemBenchTurn model so ingest,
/// seeding and scoring are untouched: the record becomes a single-turn
/// exchange whose user side is the statement and whose assistant side is
/// empty, in one session. `rel`/`attr`/`value` are deliberately NOT folded
/// into the ingested text — feeding a system the answer triple alongside the
/// sentence would measure parsing, not recall.
private struct MemBenchRecordRaw: Decodable {
    let mid: Int
    let message: String
    let time: String?
    let place: String?

    // The published files are not uniform: `mid` appears as a JSON number in
    // some categories and a quoted string in others, and `message` is null on
    // a handful of records. Both are decoded leniently rather than rejected —
    // a strict decode fails the whole 13,137-item perspective over a few rows.
    //
    // A null message keeps its record rather than dropping it. Evidence is
    // addressed by mid, so removing a row would shift nothing but would make
    // the referenced mid unresolvable; an empty turn stays addressable and
    // simply contributes no text.
    enum CodingKeys: String, CodingKey { case mid, message, time, place }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try? c.decode(Int.self, forKey: .mid) {
            mid = n
        } else if let str = try? c.decode(String.self, forKey: .mid), let n = Int(str) {
            mid = n
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .mid, in: c, debugDescription: "mid is neither an integer nor a numeric string")
        }
        message = (try? c.decodeIfPresent(String.self, forKey: .message)) .flatMap { $0 } ?? ""
        time    = (try? c.decodeIfPresent(String.self, forKey: .time))    .flatMap { $0 }
        place   = (try? c.decodeIfPresent(String.self, forKey: .place))   .flatMap { $0 }
    }
}

/// message_list is nested sessions in FirstAgent and a flat record array in
/// ThirdAgent. Decoding tries the nested shape first and falls back, so one
/// loader reads both without the caller declaring which it has.
private enum MemBenchMessageList: Decodable {
    case sessions([[MemBenchTurnRaw]])
    case records([MemBenchRecordRaw])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let nested = try? container.decode([[MemBenchTurnRaw]].self) {
            self = .sessions(nested)
            return
        }
        self = .records(try container.decode([MemBenchRecordRaw].self))
    }

    var isEmpty: Bool {
        switch self {
        case let .sessions(s): return s.isEmpty
        case let .records(r):  return r.isEmpty
        }
    }
}

/// target_step_id is [[global_sid, session_idx]] in FirstAgent and a flat
/// [mid] in ThirdAgent. Both decode here; the flat form carries session 0,
/// which is the only session a ThirdAgent item has.
private enum MemBenchTargetSteps: Decodable {
    case pairs([[Int]])
    case flat([Int])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let pairs = try? container.decode([[Int]].self) {
            self = .pairs(pairs)
            return
        }
        self = .flat(try container.decode([Int].self))
    }

    /// Evidence turns as (globalSid, sessionIdx). A sid can name more than one
    /// turn (restated steps), in which case every turn carrying it is evidence.
    var resolved: [(globalSid: Int, sessionIdx: Int)] {
        switch self {
        case let .pairs(pairs):
            return pairs.compactMap { pair in
                guard pair.count >= 2 else { return nil }
                return (globalSid: pair[0], sessionIdx: pair[1])
            }
        case let .flat(mids):
            return mids.map { (globalSid: $0, sessionIdx: 0) }
        }
    }
}

/// Raw codec for the QA object. choices is decoded as a generic [String: String].
private struct MemBenchQARaw: Decodable {
    let qid: Int?
    let question: String
    let answer: String
    // target_step_id: [[global_sid, session_idx]] pairs in FirstAgent, a flat
    // [mid] list in ThirdAgent — see MemBenchTargetSteps.
    let target_step_id: MemBenchTargetSteps
    let choices: [String: String]
    let ground_truth: String
    let time: String?

    // Decoded leniently for the same reason as the record above: the published
    // ThirdAgent files carry nulls in places the schema implies a string —
    // individual multiple-choice options, and occasionally answer text. A
    // strict decode discards a whole category over a handful of rows.
    //
    // A null option is DROPPED rather than turned into an empty string: an
    // empty choice would be offered to a judge as a real option to pick.
    enum CodingKeys: String, CodingKey {
        case qid, question, answer, target_step_id, choices, ground_truth, time
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        qid            = (try? c.decodeIfPresent(Int.self, forKey: .qid)) .flatMap { $0 }
        question       = (try? c.decodeIfPresent(String.self, forKey: .question)).flatMap { $0 } ?? ""
        answer         = (try? c.decodeIfPresent(String.self, forKey: .answer)).flatMap { $0 } ?? ""
        target_step_id = (try? c.decode(MemBenchTargetSteps.self, forKey: .target_step_id))
                         ?? MemBenchTargetSteps.flat([])
        ground_truth   = (try? c.decodeIfPresent(String.self, forKey: .ground_truth)).flatMap { $0 } ?? ""
        time           = (try? c.decodeIfPresent(String.self, forKey: .time)).flatMap { $0 }
        let rawChoices = (try? c.decodeIfPresent([String: String?].self, forKey: .choices))
                         .flatMap { $0 } ?? [:]
        choices = rawChoices.compactMapValues { $0 }
    }
}

/// Raw codec for one item object inside a topic array.
private struct MemBenchItemRaw: Decodable {
    let tid: Int?
    let message_list: MemBenchMessageList
    let QA: MemBenchQARaw?
}

// MARK: - Loader

/// Loads MemBench items from the directory tree at `dataDir`.
///
/// File layout: `<dataDir>/<agent>/<category>.json`
///
/// - Parameters:
///   - dataDir: Root MemData directory (contains FirstAgent/ and ThirdAgent/).
///   - agent: Which agent perspective to load ("FirstAgent" or "ThirdAgent").
///   - categories: Category names to include. nil = all 7 LowLevel categories.
///   - limit: Optional item count cap applied after loading (for quick runs).
/// - Returns: A `MemBenchCorpus` with all valid items.
/// - Throws: `MemBenchLoadError` on missing directory or unreadable files.
func loadMemBenchCorpus(
    dataDir: URL,
    agent: String = "FirstAgent",
    categories: [String]? = nil,
    limit: Int? = nil
) throws -> MemBenchCorpus {
    // Default to the 7 LowLevel categories (the paper's main evaluation set).
    let effectiveCategories = categories ?? [
        "simple", "comparative", "aggregative", "conditional",
        "knowledge_update", "post_processing", "noisy",
    ]

    let agentDir = dataDir.appendingPathComponent(agent)
    guard FileManager.default.isReadableFile(atPath: agentDir.path) ||
          FileManager.default.fileExists(atPath: agentDir.path) else {
        throw MemBenchLoadError(
            description: "MemBench: agent directory not found at '\(agentDir.path)'")
    }

    var allItems: [MemBenchItem] = []
    var skipped = 0

    for category in effectiveCategories {
        let fileURL = agentDir.appendingPathComponent("\(category).json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Missing category file is not an error — some agents lack some categories.
            continue
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw MemBenchLoadError(
                description: "MemBench: could not read '\(fileURL.path)': \(error)")
        }

        let topLevel: [String: [MemBenchItemRaw]]
        do {
            topLevel = try JSONDecoder().decode([String: [MemBenchItemRaw]].self, from: data)
        } catch let decodingError {
            throw MemBenchLoadError(
                description: "MemBench: JSON decode failed for '\(fileURL.path)': \(decodingError)")
        }

        // Iterate over all topic groups in the file, in SORTED key order.
        //
        // Swift randomises Dictionary iteration order per process, so iterating
        // `topLevel` directly makes item order differ between two runs of the
        // same command. Files with more than one topic group (noisy.json has
        // several) then hand `--limit N` a different slice each launch: a
        // `make artifacts` run built FirstAgent/noisy/roles/169 while the
        // `make measure` run that followed demanded
        // FirstAgent/noisy/events/169 and hard-failed on the missing artifact.
        // Sorted keys make the corpus order a function of its contents alone.
        for topicKey in topLevel.keys.sorted() {
            let rawItems = topLevel[topicKey] ?? []
            for (rawIndex, raw) in rawItems.enumerated() {
                guard let qa = raw.QA else {
                    // Items without a QA field are skipped (not scored).
                    skipped += 1
                    continue
                }
                guard !qa.question.isEmpty else {
                    skipped += 1
                    continue
                }
                guard !raw.message_list.isEmpty else {
                    skipped += 1
                    continue
                }

                let tid = raw.tid ?? rawIndex

                // Build sessions from message_list. ThirdAgent's flat record
                // array becomes ONE session of single-statement turns: it has
                // no session structure to preserve, and collapsing it keeps
                // every downstream consumer (seeding, evidence scoring,
                // per-session batching) on one code path.
                let sessions: [MemBenchSession]
                switch raw.message_list {
                case let .sessions(rawSessions):
                    sessions = rawSessions.enumerated().map { (si, rawTurns) in
                        MemBenchSession(
                            sessionIndex: si,
                            turns: rawTurns.map { t in
                                MemBenchTurn(
                                    sid: t.sid,
                                    userMessage: t.user_message,
                                    assistantMessage: t.assistant_message,
                                    time: t.time ?? "",
                                    place: t.place ?? ""
                                )
                            }
                        )
                    }
                case let .records(records):
                    sessions = [MemBenchSession(
                        sessionIndex: 0,
                        turns: records.map { r in
                            MemBenchTurn(
                                sid: r.mid,
                                userMessage: r.message,
                                assistantMessage: "",
                                time: r.time ?? "",
                                place: r.place ?? ""
                            )
                        }
                    )]
                }

                // Map target_step_id pairs. Each pair is [global_sid, session_idx];
                // we store both but score only against the global_sid. A sid can
                // name more than one turn (restated steps), in which case every
                // turn carrying it counts as evidence.
                let targetStepID = qa.target_step_id.resolved

                let qaItem = MemBenchQA(
                    qid: qa.qid ?? 0,
                    question: qa.question,
                    answer: qa.answer,
                    targetStepID: targetStepID,
                    choices: qa.choices,
                    groundTruth: qa.ground_truth,
                    time: qa.time ?? ""
                )

                allItems.append(MemBenchItem(
                    itemID: "\(agent)/\(category)/\(topicKey)/\(tid)",
                    category: category,
                    agent: agent,
                    topicKey: topicKey,
                    tid: tid,
                    sessions: sessions,
                    qa: qaItem
                ))
            }
        }
    }

    // Apply limit after loading (consistent with how other lanes handle --limit).
    let finalItems: [MemBenchItem]
    if let limit, limit < allItems.count {
        finalItems = Array(allItems.prefix(limit))
    } else {
        finalItems = allItems
    }

    return MemBenchCorpus(items: finalItems, skippedCount: skipped)
}
