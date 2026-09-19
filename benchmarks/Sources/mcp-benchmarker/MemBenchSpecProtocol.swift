// MemBenchSpecProtocol.swift — §2–§3 string surfaces for the membench-spec lane.
//
// Implements the official MemBench interaction protocol per
// MEMBENCH_OFFICIAL_PROTOCOL.md §2 (storage line format), §3 (answer-generation
// prompts), and §4 (step-id parse and recall query format).
//
// All functions are pure string constructors: no I/O, no Date() calls, no clock
// reads, no external dependencies. The Rust twin (membench_spec_protocol.rs)
// produces byte-identical output for every input — pinned by
// conformance/membench-spec/protocol_vectors.json.
//
// § references below point to section numbers in MEMBENCH_OFFICIAL_PROTOCOL.md.

import Foundation

// MARK: - Official initial instruction constant (§2)

/// The official initial instruction constant from the MemBench interaction protocol.
///
/// The constant name `INITIAL_INSTRUACTION` is official — the typo (`INSTRUACTION`)
/// is reproduced verbatim from the source (§2, arXiv 2506.21605,
/// `benchmarks/env/Membenenv.py`). Do not rename this constant.
///
/// This string is sent as the opening message before the first `message_list` turn.
let INITIAL_INSTRUACTION =
    "Please help me record the following information. If there are any questions within the information, please help me answer them."

// MARK: - Storage line construction (§2)

/// Formats a string-form memory storage line per §2.
///
/// Official format: `"{step}[|]{message}"`
/// Used when the `message_list` entry is a plain string message.
///
/// - Parameters:
///   - step: The env's 1-based `step_id` counter at the time of storage (§2).
///   - message: The message text to store.
/// - Returns: The formatted storage line, e.g. `"3[|]Hello, how are you?"`.
func storageLine(step: Int, message: String) -> String {
    // §2: string message form: "{step}[|]{message}"
    "\(step)[|]\(message)"
}

/// Formats a dict-form memory storage line per §2.
///
/// Official format: `"{step}[|]'user': {user}; 'agent': {agent}"`
/// Used when the `message_list` entry is a dict with `user_message` and
/// `assistant_message` fields.
///
/// - Parameters:
///   - step: The env's 1-based `step_id` counter at the time of storage (§2).
///   - user: The user's message text (from the turn's `user_message` field).
///   - agent: The agent's response text (from the turn's `assistant_message` field).
/// - Returns: The formatted storage line, e.g.
///   `"5[|]'user': Hi there; 'agent': Hello!"`.
func storageLine(step: Int, user: String, agent: String) -> String {
    // §2: dict message form: "{step}[|]'user': {user}; 'agent': {agent}"
    "\(step)[|]'user': \(user); 'agent': \(agent)"
}

// MARK: - Step-id parse (§4)

/// Errors produced by parsing a storage line for its step id.
enum StorageLineParseError: Error, Equatable {
    /// The `[|]` separator was absent — the line is not a valid storage line.
    case missingDelimiter
    /// The prefix before `[|]` was not a decimal integer.
    case invalidStepID
}

/// Parses the step id from a storage line produced by the §2 storage protocol.
///
/// Algorithm verbatim from §4: `int(text.split('[|]')[0])` — split on the
/// literal delimiter `[|]`, take the first element, parse as int.
///
/// - Parameter line: A storage line in either the string or dict form from §2.
/// - Returns: The parsed step id on success.
/// - Throws: `StorageLineParseError.missingDelimiter` when `[|]` is absent;
///   `StorageLineParseError.invalidStepID` when the prefix is not a decimal integer.
func stepID(fromStorageLine line: String) throws -> Int {
    // §4: int(text.split('[|]')[0]) — fail loudly when the delimiter is absent.
    guard line.contains("[|]") else {
        throw StorageLineParseError.missingDelimiter
    }
    // Take everything before the first "[|]" (matching Python's split('[|]')[0]).
    let prefix = line.components(separatedBy: "[|]").first ?? ""
    guard let id = Int(prefix) else {
        throw StorageLineParseError.invalidStepID
    }
    return id
}

// MARK: - Recall / retrieval query (§3–4)

/// Formats the memory recall and retrieval query string per §3–4.
///
/// Official format (§3): `memory.recall('%s (%s)' % (question, time))`
/// Expands to: `"question (time)"`
///
/// The identical format is used for both `memory.recall(...)` (§3 answer
/// generation) and `memory.retri(...)` (§4 recall metric computation).
///
/// - Parameters:
///   - question: The question text from the QA pair.
///   - time: The `time` field from the QA pair.
/// - Returns: The formatted query, e.g. `"Where did we go? (2024-01-15)"`.
func recallQuery(question: String, time: String) -> String {
    // §3: '%s (%s)' % (question, time)
    "\(question) (\(time))"
}

// MARK: - Agent perspective (§3)

/// The agent perspective, selecting which §3 answer-prompt template to apply.
///
/// `firstAgent` → "FirstAgent (Participation)" prompt: the model answers as a
///   participant in the conversation (`your'conversation with the user`).
///
/// `thirdAgent` → "ThirdAgent (Observation)" prompt: the model answers as an
///   observer of the user's messages (`the user's messages`).
enum MemBenchPerspective: String, Sendable, Equatable {
    case firstAgent = "FirstAgent"
    case thirdAgent = "ThirdAgent"
}

// MARK: - Answer prompt construction (§3)

/// Constructs the §3 answer prompt for the given perspective, byte-exact.
///
/// The two templates differ only in their opening line:
/// - `firstAgent`: `"...your'conversation with the user."` — official typo (§3).
/// - `thirdAgent`: `"...the user's messages."` — third-person observation framing.
///
/// Template structure (both perspectives, §3 verbatim):
/// ```
/// <perspective line>
/// Past memory: {memory}
/// Question: (current time is {time}) {question}
/// Choices:
/// A. {choice_A}
/// B. {choice_B}
/// C. {choice_C}
/// D. {choice_D}
/// Please output the correct option for the question, only one corresponding letter, without any other messages.
/// Example: D
/// ```
///
/// No trailing newline — matches the Python template output.
///
/// - Parameters:
///   - perspective: Agent perspective (`firstAgent` or `thirdAgent`).
///   - memory: The string returned by `memory.recall(recallQuery(question:time:))`.
///   - question: The question text from the QA pair.
///   - time: The `time` field from the QA pair (shown as "current time is {time}").
///   - choices: A/B/C/D option strings from the dataset's `choices` field.
/// - Returns: The fully-rendered prompt string, ready to send to the answering model.
func answerPrompt(
    perspective: MemBenchPerspective,
    memory: String,
    question: String,
    time: String,
    choices: [String: String]
) -> String {
    // §3 FirstAgent: "your'conversation" typo is OFFICIAL — preserve verbatim.
    // §3 ThirdAgent: "the user's messages" — third-person observation framing.
    let perspectiveLine: String
    switch perspective {
    case .firstAgent:
        perspectiveLine =
            "Please answer the following question based on past memories of your'conversation with the user."
    case .thirdAgent:
        perspectiveLine =
            "Please answer the following question based on past memories of the user's messages."
    }
    let choiceA = choices["A"] ?? ""
    let choiceB = choices["B"] ?? ""
    let choiceC = choices["C"] ?? ""
    let choiceD = choices["D"] ?? ""
    // Build line-by-line and join with "\n" to guarantee byte-exact separators
    // across platforms. No trailing newline — matches the Python f-string output.
    return [
        perspectiveLine,
        "Past memory: \(memory)",
        "Question: (current time is \(time)) \(question)",
        "Choices:",
        "A. \(choiceA)",
        "B. \(choiceB)",
        "C. \(choiceC)",
        "D. \(choiceD)",
        "Please output the correct option for the question, only one corresponding letter, without any other messages.",
        "Example: D",
    ].joined(separator: "\n")
}

// MARK: - Answer constraint descriptor (§3)

/// Describes the JSON-schema letter constraint for the external answering command.
///
/// Per §3, the answering call constrains the model's output to a single letter
/// via `{"choice": enum ["A","B","C","D"]}` (strict). This struct carries the
/// schema descriptor and the shared parse function so every caller uses identical
/// parsing logic.
///
/// Primary parse path (§3): `json.loads(res)['choice']`.
/// Fallback parse path (§3): `s.replace(" ", "").replace("\n", "")`.
/// Correctness check (§3): `action['response'] == QA['ground_truth']` — exact
/// string equality on the returned letter.
enum MemBenchAnswerConstraint {

    /// JSON Schema object enforcing the single-letter output constraint (§3, strict).
    ///
    /// Schema:
    /// `{"type":"object","properties":{"choice":{"type":"string",
    ///  "enum":["A","B","C","D"]}},"required":["choice"],"additionalProperties":false}`
    static let jsonSchema: String =
        #"{"type":"object","properties":{"choice":{"type":"string","enum":["A","B","C","D"]}},"required":["choice"],"additionalProperties":false}"#

    /// Parses the answering model's JSON response and returns the choice letter.
    ///
    /// Primary path (§3): decode JSON, extract the `"choice"` key value.
    /// Fallback path (§3): strip all spaces and newlines; treat the result as
    /// the letter if it is one of A/B/C/D.
    ///
    /// - Parameter jsonString: The raw response string from the answering model.
    /// - Returns: The choice letter (`A`, `B`, `C`, or `D`) on success; `nil`
    ///   when neither path yields a valid letter.
    static func parseAnswerChoice(from jsonString: String) -> String? {
        // §3 primary: json.loads(res)['choice']
        if let data = jsonString.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choice = obj["choice"] as? String,
           isValidLetter(choice) {
            return choice
        }
        // §3 fallback: s.replace(" ", "").replace("\n", "")
        let stripped = jsonString
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return isValidLetter(stripped) ? stripped : nil
    }

    // Returns true for the four valid answer letters (§3: enum ["A","B","C","D"]).
    private static func isValidLetter(_ s: String) -> Bool {
        s == "A" || s == "B" || s == "C" || s == "D"
    }
}

// MARK: - TokenCounter seam (§6 / §7 row 6)

/// Shared tokenizer backing `memBenchCountTokens` (§6 capacity token axis).
///
/// Loaded once per process from the cl100k_base vocabulary at the
/// `MOOT_BENCH_CL100K` path exported by the Makefile. `nil` when the external
/// artifact is absent — `memBenchCountTokens` fails loud in that case, because
/// a §6 capacity figure counted with any other tokenizer is not the documented
/// measurement.
private let memBenchCl100kTokenizer: Cl100kTokenizer? = {
    guard let path = ProcessInfo.processInfo.environment["MOOT_BENCH_CL100K"] else {
        return nil
    }
    return try? Cl100kTokenizer.load(from: path)
}()

/// Token-counting seam for the §6 capacity measurement (step_cap variant).
///
/// §6 specifies `cl100k_base` (tiktoken) as the official tokenizer. §7 row 6
/// RESOLVED ( operator ruling 2026-08-18): the vocabulary artifact is vendored via
/// `scripts/fetch-cl100k.sh` and counts come from `Cl100kTokenizer` — byte-exact
/// tiktoken `cl100k_base`, oracle-verified against tiktoken 0.14.0 by
/// `conformance/cl100k/vectors.json`.
///
/// The §6 capacity runner calls `memBenchCountTokens` rather than the
/// tokenizer directly so the loading policy lives in exactly one place.
///
/// - Parameter text: The string to count tokens in (typically the concatenated
///   `user_message` and `assistant_message` per §6 "user + agent strings per message").
/// - Returns: Exact cl100k_base token count (0 only for the empty string).
func memBenchCountTokens(_ text: String) -> Int {
    guard let tokenizer = memBenchCl100kTokenizer else {
        // Fail loud: §6 defines the token axis as cl100k_base; substituting a
        // different counter silently would misstate the capacity measurement.
        fatalError("""
            cl100k_base vocabulary artifact missing — run \
            benchmarks/scripts/fetch-cl100k.sh (or set MOOT_BENCH_CL100K to the \
            .tiktoken file). The §6 capacity axis requires the exact tokenizer.
            """)
    }
    return tokenizer.countTokens(text)
}
