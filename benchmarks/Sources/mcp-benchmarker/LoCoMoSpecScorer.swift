// LoCoMoSpecScorer.swift — Official LoCoMo QA evaluation metrics, §1–§5.
//
// Source of truth: LOCOMO_OFFICIAL_PROTOCOL.md §1–§5, which verbatim-extracts
// snap-research/locomo task_eval/{evaluation,evaluate_qa,evaluation_stats}.py.
//
// The scoring pipeline is entirely rule-based — no LLM judge.
// Every public function cites its spec section in its doc comment.
//
// Conformance contract: both this Swift file and locomo_spec_scorer.rs must
// produce byte-identical metric values on every vector in
// conformance/locomo-spec/scorer_vectors.json.
//
// No external dependencies; the Porter stemmer is implemented in-repo.

import Foundation

// MARK: - Error type

/// Error raised when a question category is outside the supported range.
/// §3: valid categories are 1, 2, 3, 4, 5; any other value raises ValueError in
/// the reference implementation.
enum LoCoMoSpecError: Error, Sendable {
    case invalidCategory(Int)
}

// MARK: - §1 Answer normalisation

/// Python `string.punctuation` set reproduced verbatim:
///   `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`
/// §1 of LOCOMO_OFFICIAL_PROTOCOL.md: remove_punc strips exactly this set.
private let specPunctuationSet: Set<Character> = {
    // 32 characters from Python string.punctuation — order is irrelevant for a Set.
    // \u{60} is the grave accent / backtick character.
    let s = "!\"#$%&'()*+,-./:;<=>?@[\\]^_\u{60}{|}~"
    return Set(s)
}()

/// Normalises a raw answer string following the verbatim pipeline in §1.
///
/// Order of operations (must be preserved — commas are stripped first, before
/// lowercase, so the comma is absent from the punctuation-removal pass):
///   1. Strip all commas from the raw string.
///   2. Lowercase.
///   3. Remove Python `string.punctuation` characters.
///   4. Remove whole-word articles: a / an / the / and.
///   5. Collapse consecutive whitespace to a single space and strip.
///
/// - Parameter s: Raw answer string (may be any case, may contain punctuation).
/// - Returns: Normalised string ready for token splitting and stemming.
func normalizeAnswer(_ s: String) -> String {
    // Step 1: strip commas from raw string.
    // §1: s = s.replace(',', "")
    let noCommas = s.filter { $0 != "," }

    // Step 2: lowercase.
    // §1: lower(s)
    let lower = noCommas.lowercased()

    // Step 3: remove Python string.punctuation characters.
    // §1: remove_punc — ''.join(ch for ch in text if ch not in exclude)
    let noPunc = lower.filter { !specPunctuationSet.contains($0) }

    // Step 4: remove whole-word articles a / an / the / and.
    // §1: regex.sub(r'\b(a|an|the|and)\b', ' ', text)
    // We split on whitespace, filter out article tokens, then rejoin.
    // Splitting on whitespace already covers the word-boundary semantics since
    // punctuation is already gone; no partial-word matches are possible.
    let tokens = noPunc.split(separator: " ", omittingEmptySubsequences: false)
    let articles: Set<Substring> = ["a", "an", "the", "and"]
    let noArticles = tokens.map { articles.contains($0) ? "" : $0 }

    // Step 5: collapse whitespace.
    // §1: white_space_fix — ' '.join(text.split())
    let result = noArticles.joined(separator: " ")
        .split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")

    return result
}

// MARK: - NLTK Porter stemmer (default NLTK_EXTENSIONS mode)
//
// Reference: M.F. Porter, "An algorithm for suffix stripping",
// Program, 14(3) pp 130-137, 1980.
// §2 of LOCOMO_OFFICIAL_PROTOCOL.md constructs `PorterStemmer()` without a
// mode argument. NLTK therefore uses NLTK_EXTENSIONS, not the deprecated
// ORIGINAL_ALGORITHM. The extensions below are ported from nltk 3.9.2 and are
// conformance-vectored against that upstream Python implementation.

/// Returns true when the character at position `i` in `chars` is a vowel.
/// A vowel is a, e, i, o, u, or y when immediately preceded by a consonant.
/// §2: classic Porter 1980 vowel definition.
private func isVowelAt(_ chars: [Character], _ i: Int) -> Bool {
    switch chars[i] {
    case "a", "e", "i", "o", "u":
        return true
    case "y":
        // y is a vowel iff it is not the first letter and the preceding letter
        // is a consonant (Porter 1980, §2 footnote).
        return i > 0 && !isVowelAt(chars, i - 1)
    default:
        return false
    }
}

/// Computes the measure m of chars[0..<end] — the number of VC sequences.
/// §2: [C](VC)^m[V] gives measure m for a stem.
private func measureOf(_ chars: [Character], _ end: Int) -> Int {
    var m = 0
    var i = 0
    // Skip any leading consonants.
    while i < end && !isVowelAt(chars, i) { i += 1 }
    while i < end {
        // Skip a vowel run.
        while i < end && isVowelAt(chars, i) { i += 1 }
        // Skip a consonant run; each such run after a vowel run adds 1 to m.
        if i < end {
            while i < end && !isVowelAt(chars, i) { i += 1 }
            m += 1
        }
    }
    return m
}

/// Returns true if chars[0..<end] contains at least one vowel.
/// §2: *v* condition.
private func containsVowel(_ chars: [Character], _ end: Int) -> Bool {
    (0..<end).contains { isVowelAt(chars, $0) }
}

/// Returns true if chars[0..<end] ends with a double consonant.
/// §2: *d condition (e.g. -TT, -SS, -MM).
private func endsDoubleConsonant(_ chars: [Character], _ end: Int) -> Bool {
    guard end >= 2 else { return false }
    guard chars[end - 1] == chars[end - 2] else { return false }
    return !isVowelAt(chars, end - 1)
}

/// Returns true if chars[0..<end] ends with the pattern CVC where the final
/// consonant is not W, X, or Y.
/// §2: *o condition (short vowel in monosyllabic stems).
private func endsCVC(_ chars: [Character], _ end: Int) -> Bool {
    // NLTK_EXTENSIONS adds a two-letter VC form to the paper's CVC rule.
    if end == 2 {
        return isVowelAt(chars, 0) && !isVowelAt(chars, 1)
    }
    guard end >= 3 else { return false }
    // Check last three positions: consonant, vowel, consonant (not W/X/Y).
    guard !isVowelAt(chars, end - 3) else { return false }
    guard  isVowelAt(chars, end - 2) else { return false }
    guard !isVowelAt(chars, end - 1) else { return false }
    let last = chars[end - 1]
    return last != "w" && last != "x" && last != "y"
}

/// Attempts to strip `suffix` from `chars` and replace it with `replacement`
/// if `condition(chars, stemLen)` returns true.
/// Returns true and mutates `chars` on success; otherwise leaves `chars` unchanged.
@discardableResult
private func applyRule(
    _ chars: inout [Character],
    suffix: String,
    replacement: String,
    _ condition: ([Character], Int) -> Bool
) -> Bool {
    let sfx = Array(suffix)
    let n   = chars.count
    let sfxLen  = sfx.count
    guard n >= sfxLen else { return false }
    let stemLen = n - sfxLen
    // Fast suffix check.
    for i in 0..<sfxLen {
        if chars[stemLen + i] != sfx[i] { return false }
    }
    // Condition receives chars (before modification) and the stem length.
    guard condition(chars, stemLen) else { return false }
    // Apply: remove suffix, append replacement.
    chars.removeSubrange(stemLen...)
    chars.append(contentsOf: Array(replacement))
    return true
}

private let nltkPorterIrregularForms: [String: String] = [
    "sky": "sky", "skies": "sky",
    "dying": "die", "lying": "lie", "tying": "tie",
    "news": "news",
    "innings": "inning", "inning": "inning",
    "outings": "outing", "outing": "outing",
    "cannings": "canning", "canning": "canning",
    "howe": "howe", "proceed": "proceed", "exceed": "exceed", "succeed": "succeed",
]

/// Applies NLTK's Step 2, including its recursive ALLI extension and the
/// NLTK-only FULLI and LOGI rules. A suffix match whose condition fails stops
/// the step, matching `_apply_rule_list` rather than trying a shorter suffix.
private func applyNltkPorterStep2(_ chars: inout [Character]) {
    let word = String(chars)
    if word.hasSuffix("alli") {
        let stemLen = chars.count - 4
        if measureOf(chars, stemLen) > 0 {
            chars.removeSubrange(stemLen...)
            chars.append(contentsOf: Array("al"))
            applyNltkPorterStep2(&chars)
        }
        return
    }

    let rules: [(String, String, ([Character], Int) -> Bool)] = [
        ("ational", "ate", { c, e in measureOf(c, e) > 0 }),
        ("tional", "tion", { c, e in measureOf(c, e) > 0 }),
        ("enci", "ence", { c, e in measureOf(c, e) > 0 }),
        ("anci", "ance", { c, e in measureOf(c, e) > 0 }),
        ("izer", "ize", { c, e in measureOf(c, e) > 0 }),
        ("bli", "ble", { c, e in measureOf(c, e) > 0 }),
        ("alli", "al", { c, e in measureOf(c, e) > 0 }),
        ("entli", "ent", { c, e in measureOf(c, e) > 0 }),
        ("eli", "e", { c, e in measureOf(c, e) > 0 }),
        ("ousli", "ous", { c, e in measureOf(c, e) > 0 }),
        ("ization", "ize", { c, e in measureOf(c, e) > 0 }),
        ("ation", "ate", { c, e in measureOf(c, e) > 0 }),
        ("ator", "ate", { c, e in measureOf(c, e) > 0 }),
        ("alism", "al", { c, e in measureOf(c, e) > 0 }),
        ("iveness", "ive", { c, e in measureOf(c, e) > 0 }),
        ("fulness", "ful", { c, e in measureOf(c, e) > 0 }),
        ("ousness", "ous", { c, e in measureOf(c, e) > 0 }),
        ("aliti", "al", { c, e in measureOf(c, e) > 0 }),
        ("iviti", "ive", { c, e in measureOf(c, e) > 0 }),
        ("biliti", "ble", { c, e in measureOf(c, e) > 0 }),
        ("fulli", "ful", { c, e in measureOf(c, e) > 0 }),
        // NLTK intentionally measures word[:-3], keeping the `l` with the stem.
        ("logi", "log", { c, _ in c.count >= 3 && measureOf(c, c.count - 3) > 0 }),
    ]
    for (suffix, replacement, condition) in rules where word.hasSuffix(suffix) {
        _ = applyRule(&chars, suffix: suffix, replacement: replacement, condition)
        return
    }
}

/// Returns the stem produced by NLTK 3.9.2 `PorterStemmer()` in its default
/// `NLTK_EXTENSIONS` mode.
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md: all token metrics stem with Porter.
func porterStem(_ word: String) -> String {
    let lowered = word.lowercased()
    // NLTK checks its exception pool against the caller's original spelling,
    // even though all later steps use the lowercased stem. Preserve that
    // observable detail: `skies` is exceptional, while `SKIES` becomes `ski`.
    if let irregular = nltkPorterIrregularForms[word] { return irregular }
    var chars = Array(lowered)
    guard chars.count > 2 else { return lowered }

    // ── Step 1a ────────────────────────────────────────────────────────────
    // Unconditional suffix rules (the original paper lists no m condition here).
    // Order is significant: try each rule in turn, stop after the first match.
    //   SSES → SS, IES → I, SS → SS, S → ""
    let fourLetterIES = chars.count == 4 && String(chars).hasSuffix("ies")
    let _ = applyRule(&chars, suffix: "sses", replacement: "ss", { _, _ in true })
         || applyRule(&chars, suffix: "ies",  replacement: fourLetterIES ? "ie" : "i",  { _, _ in true })
         || applyRule(&chars, suffix: "ss",   replacement: "ss", { _, _ in true })
         || applyRule(&chars, suffix: "s",    replacement: "",   { _, _ in true })

    // ── Step 1b ────────────────────────────────────────────────────────────
    // (m>0) EED→EE; (*v*) ED→""; (*v*) ING→""
    // The ED and ING sub-rules trigger a follow-up adjustment.
    var step1bApplied = false
    let step1bWord = String(chars)
    if step1bWord.hasSuffix("ied") {
        let replacement = chars.count == 4 ? "ie" : "i"
        chars.removeLast(3)
        chars.append(contentsOf: Array(replacement))
    } else if step1bWord.hasSuffix("eed") {
        // A matching EED whose measure fails ends the step; it must not fall
        // through and be reconsidered as ED (for example, `feed`).
        _ = applyRule(&chars, suffix: "eed", replacement: "ee", { c, e in measureOf(c, e) > 0 })
    } else if step1bWord.hasSuffix("ed") {
        step1bApplied = applyRule(&chars, suffix: "ed", replacement: "", { c, e in containsVowel(c, e) })
    } else if step1bWord.hasSuffix("ing") {
        step1bApplied = applyRule(&chars, suffix: "ing", replacement: "", { c, e in containsVowel(c, e) })
    }

    if step1bApplied {
        // Follow-up rules after ED or ING removal (Porter 1980 §1b, second part).
        // AT→ATE, BL→BLE, IZ→IZE are checked first;
        // then double-consonant → single (if not L, S, Z);
        // then (m=1 and *o) → E.
        let n = chars.count
        let _ = applyRule(&chars, suffix: "at", replacement: "ate", { _, _ in true })
             || applyRule(&chars, suffix: "bl", replacement: "ble", { _, _ in true })
             || applyRule(&chars, suffix: "iz", replacement: "ize", { _, _ in true })
        // None of the above fired — check double-consonant and CVC rules.
        if chars.count == n {
            let end = chars.count
            let last = end > 0 ? chars[end - 1] : Character(" ")
            if endsDoubleConsonant(chars, end) && last != "l" && last != "s" && last != "z" {
                // Reduce double consonant to single: e.g. -nn → -n, -mm → -m.
                chars.removeLast()
            } else if measureOf(chars, chars.count) == 1 && endsCVC(chars, chars.count) {
                // (m=1 and *o): append E (e.g. hop → hope).
                chars.append("e")
            }
        }
    }

    // ── Step 1c ────────────────────────────────────────────────────────────
    // NLTK: (*c and not c) Y → I. This deliberately stems fly→fli but
    // leaves enjoy→enjoy and one-consonant stems unchanged.
    applyRule(&chars, suffix: "y", replacement: "i", {
        c, e in e > 1 && !isVowelAt(c, e - 1)
    })

    // ── Step 2 ─────────────────────────────────────────────────────────────
    // (m>0) Long-suffix mappings; first match wins.
    // Order follows the original paper.
    applyNltkPorterStep2(&chars)

    // ── Step 3 ─────────────────────────────────────────────────────────────
    // (m>0) Moderately-long suffix mappings.
    let step3Rules: [(String, String)] = [
        ("icate", "ic"),
        ("ative", ""),
        ("alize", "al"),
        ("iciti", "ic"),
        ("ical",  "ic"),
        ("ful",   ""),
        ("ness",  ""),
    ]
    let step3Word = String(chars)
    for (suffix, replacement) in step3Rules where step3Word.hasSuffix(suffix) {
        _ = applyRule(&chars, suffix: suffix, replacement: replacement, { c, e in measureOf(c, e) > 0 })
        break
    }

    // ── Step 4 ─────────────────────────────────────────────────────────────
    // (m>1) Short-suffix removal; first match wins.
    // The ION rule has the additional condition *S or *T (stem ends in s or t).
    let step4Rules: [(String, ([Character], Int) -> Bool)] = [
        ("al",    { c, e in measureOf(c, e) > 1 }),
        ("ance",  { c, e in measureOf(c, e) > 1 }),
        ("ence",  { c, e in measureOf(c, e) > 1 }),
        ("er",    { c, e in measureOf(c, e) > 1 }),
        ("ic",    { c, e in measureOf(c, e) > 1 }),
        ("able",  { c, e in measureOf(c, e) > 1 }),
        ("ible",  { c, e in measureOf(c, e) > 1 }),
        ("ant",   { c, e in measureOf(c, e) > 1 }),
        ("ement", { c, e in measureOf(c, e) > 1 }),
        ("ment",  { c, e in measureOf(c, e) > 1 }),
        ("ent",   { c, e in measureOf(c, e) > 1 }),
        // ION: additionally requires stem ends in s or t (*S or *T).
        ("ion",   { c, e in measureOf(c, e) > 1 && e > 0 && (c[e - 1] == "s" || c[e - 1] == "t") }),
        ("ou",    { c, e in measureOf(c, e) > 1 }),
        ("ism",   { c, e in measureOf(c, e) > 1 }),
        ("ate",   { c, e in measureOf(c, e) > 1 }),
        ("iti",   { c, e in measureOf(c, e) > 1 }),
        ("ous",   { c, e in measureOf(c, e) > 1 }),
        ("ive",   { c, e in measureOf(c, e) > 1 }),
        ("ize",   { c, e in measureOf(c, e) > 1 }),
    ]
    let step4Word = String(chars)
    for (suffix, condition) in step4Rules where step4Word.hasSuffix(suffix) {
        _ = applyRule(&chars, suffix: suffix, replacement: "", condition)
        break
    }

    // ── Step 5a ────────────────────────────────────────────────────────────
    // Remove final E when (m>1) or (m=1 and not *o).
    let end5a = chars.count
    if end5a > 0 && chars[end5a - 1] == "e" {
        let stemLen = end5a - 1
        let m = measureOf(chars, stemLen)
        if m > 1 || (m == 1 && !endsCVC(chars, stemLen)) {
            chars.removeLast()
        }
    }

    // ── Step 5b ────────────────────────────────────────────────────────────
    // (m>1 and *d and *L): reduce final double-L to single L.
    let end5b = chars.count
    if measureOf(chars, end5b) > 1
        && endsDoubleConsonant(chars, end5b)
        && end5b > 0 && chars[end5b - 1] == "l" {
        chars.removeLast()
    }

    return String(chars)
}

// MARK: - §2 Token metrics

/// Tokenises a string into Porter-stemmed tokens of its normalised form.
/// Used internally by f1Score and rouge1F.
/// §2: "prediction_tokens = [ps.stem(w) for w in normalize_answer(prediction).split()]"
private func stemmedTokens(_ s: String) -> [String] {
    normalizeAnswer(s).split(separator: " ").map { porterStem(String($0)) }
}

/// Computes the token-level F1 score between a prediction and a single gold answer.
///
/// Uses Porter-stemmed tokens of the normalised strings. Precision and recall are
/// computed over the multiset intersection (Counter &) of stemmed tokens.
/// Returns 0.0 when the intersection is empty (including when either string
/// normalises to zero tokens).
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md: f1_score(prediction, ground_truth).
func f1Score(prediction: String, goldAnswer: String) -> Double {
    let predTokens  = stemmedTokens(prediction)
    let goldTokens  = stemmedTokens(goldAnswer)

    // Multiset intersection via counts (Counter & in Python).
    var predCounts = [String: Int]()
    for t in predTokens { predCounts[t, default: 0] += 1 }
    var goldCounts = [String: Int]()
    for t in goldTokens { goldCounts[t, default: 0] += 1 }

    var numSame = 0
    for (tok, predCount) in predCounts {
        if let goldCount = goldCounts[tok] {
            numSame += min(predCount, goldCount)
        }
    }

    guard numSame > 0 else { return 0.0 }
    let precision = Double(numSame) / Double(predTokens.count)
    let recall    = Double(numSame) / Double(goldTokens.count)
    return (2.0 * precision * recall) / (precision + recall)
}

/// Computes the multi-answer F1 for category-1 questions.
///
/// Both prediction and gold are split on commas into candidate and gold parts.
/// The score is the mean over gold parts of the maximum F1 of any prediction
/// part against that gold part.
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md:
///   f1(prediction, ground_truths) = np.mean([max([f1_score(p, gt) for p in predictions])
///                                             for gt in ground_truths])
func multiAnswerF1(prediction: String, goldAnswer: String) -> Double {
    let predictions = prediction.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    let groundTruths = goldAnswer.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }

    guard !groundTruths.isEmpty else { return 0.0 }

    let perGold = groundTruths.map { gt in
        predictions.map { p in f1Score(prediction: p, goldAnswer: gt) }.max() ?? 0.0
    }
    return perGold.reduce(0.0, +) / Double(perGold.count)
}

/// Computes order-independent exact match over normalised token SETS.
///
/// Returns 1.0 when set(normalize(prediction).split()) == set(normalize(gold).split()),
/// 0.0 otherwise. Note: set equality, not multiset — repeated tokens are ignored.
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md:
///   set(prediction.split()) == set(ground_truth.split())
func exactMatch(prediction: String, goldAnswer: String) -> Double {
    let predSet = Set(normalizeAnswer(prediction).split(separator: " ").map(String.init))
    let goldSet = Set(normalizeAnswer(goldAnswer).split(separator: " ").map(String.init))
    return predSet == goldSet ? 1.0 : 0.0
}

/// Computes the ROUGE-1 F-score (unigram F) over stemmed normalised tokens.
///
/// The official LoCoMo implementation uses `scores["rouge-1"]["f"]` from the
/// rouge library, which is equivalent to the token-level F1 on stemmed normalised
/// strings. This function returns the same value as f1Score for the same inputs.
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md: rouge1F uses stemmed-normalized strings,
/// returns scores["rouge-1"]["f"] (unigram F).
func rouge1F(prediction: String, goldAnswer: String) -> Double {
    // Rouge-1 F = unigram precision-recall harmonic mean over stemmed tokens,
    // which is identical to f1Score. Implemented separately for API clarity.
    f1Score(prediction: prediction, goldAnswer: goldAnswer)
}

// MARK: - §3 Per-question scoring

/// Scores one question given its category, the model's prediction, and the
/// gold answer string.
///
/// Category routing (§3 of LOCOMO_OFFICIAL_PROTOCOL.md):
///   - Categories 2, 3, 4 → f1Score (category-3 gold truncated at first ';').
///   - Category 1          → multiAnswerF1.
///   - Category 5          → binary: 1.0 iff prediction contains
///       "no information available" or "not mentioned" (case-insensitive).
///   - Any other category  → throws LoCoMoSpecError.invalidCategory.
///
/// - Parameters:
///   - category:    Integer category from the LoCoMo question record (1–5).
///   - prediction:  The model's output string.
///   - goldAnswer:  The gold answer string (possibly multi-value for cat 1,
///                  possibly semicolon-separated for cat 3).
/// - Returns: Metric value in [0.0, 1.0].
/// - Throws: `LoCoMoSpecError.invalidCategory` when category ∉ {1,2,3,4,5}.
func scoreQuestion(category: Int, prediction: String, goldAnswer: String) throws -> Double {
    switch category {
    case 2, 4:
        // §3: categories 2 and 4 use single-answer f1Score.
        return f1Score(prediction: prediction, goldAnswer: goldAnswer)

    case 3:
        // §3: category 3 (temporal) — gold answer truncated at first ';'.
        // answer = answer.split(';')[0].strip()
        let truncatedGold = goldAnswer.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? goldAnswer
        return f1Score(prediction: prediction, goldAnswer: truncatedGold)

    case 1:
        // §3: category 1 uses multi-answer F1 (comma-split both sides).
        return multiAnswerF1(prediction: prediction, goldAnswer: goldAnswer)

    case 5:
        // §3: category 5 (adversarial) — binary abstention check.
        // 1 iff prediction contains 'no information available' or 'not mentioned'.
        let lower = prediction.lowercased()
        return (lower.contains("no information available") || lower.contains("not mentioned"))
            ? 1.0 : 0.0

    default:
        // §3: "else: raise ValueError" in the reference implementation.
        throw LoCoMoSpecError.invalidCategory(category)
    }
}

// MARK: - §4 Evidence recall

/// Computes the evidence recall for one question given its retrieved context
/// and the ground-truth evidence identifiers.
///
/// Two official forms (§4 of LOCOMO_OFFICIAL_PROTOCOL.md):
///   - **Session form** (context entries start with 'S', e.g. "S3"):
///     An evidence item "D3:12" counts if its session number ("3") appears
///     among the numeric suffixes of the context entries.
///   - **Dia form** (any other prefix):
///     An evidence item counts if it appears verbatim in the context list.
///
/// Special cases (both append recall 1 in the reference implementation):
///   - `context` is nil (the context key is absent from the question record).
///   - `evidence` is empty (the question has no ground-truth evidence).
///
/// - Parameters:
///   - context:  Retrieved context entries (nil = no context field in record).
///   - evidence: Ground-truth evidence identifiers.
/// - Returns: Recall in [0.0, 1.0].
func evidenceRecall(context: [String]?, evidence: [String]) -> Double {
    // §4: if eval_key + '_context' not in line or len(line['evidence']) == 0: append 1
    guard let ctx = context, !evidence.isEmpty else { return 1.0 }

    if ctx.first?.hasPrefix("S") == true {
        // Session form: sessions = [e[1:] for e in ctx]
        // e.g. "S3" → "3"
        let sessions = Set(ctx.map { String($0.dropFirst()) })
        // For each evidence item: ev.split(':')[0][1:] → session number.
        // e.g. "D3:12" → split(':')[0] = "D3" → [1:] = "3"
        let matched = evidence.filter { ev in
            guard let colon = ev.firstIndex(of: ":") else {
                // No colon: treat entire string as session component after drop.
                return sessions.contains(String(ev.dropFirst()))
            }
            let sessionPart = String(ev[ev.startIndex..<colon].dropFirst())
            return sessions.contains(sessionPart)
        }.count
        return Double(matched) / Double(evidence.count)
    } else {
        // Dia form: direct membership check.
        let ctxSet = Set(ctx)
        let matched = evidence.filter { ctxSet.contains($0) }.count
        return Double(matched) / Double(evidence.count)
    }
}

// MARK: - §5 Aggregation

/// Per-category accuracy and recall for the §5 aggregate.
struct LoCoMoSpecCategoryMetrics: Sendable {
    /// Integer category (1–5).
    let category: Int
    /// Mean score rounded to 3 decimal places.
    /// §5: round(acc_counts[k] / total_counts[k], 3)
    let accuracy: Double
    /// Number of questions in this category.
    let questionCount: Int
    /// Mean evidence recall rounded to 3 decimal places.
    /// §5: same rounding; meaningful only in RAG mode.
    let meanRecall: Double
}

/// Full §5 aggregate result.
struct LoCoMoSpecAggregate: Sendable {
    /// Overall accuracy across all categories, rounded to 3 decimals.
    /// §5: round(total_correct / total_questions, 3)
    let overall: Double
    /// Total question count across all categories.
    let totalQuestions: Int
    /// Per-category metrics in the mandated order [4, 1, 2, 3, 5].
    /// §5: "reported in category order [4, 1, 2, 3, 5]"
    let byCategory: [LoCoMoSpecCategoryMetrics]
    /// Overall mean evidence recall rounded to 3 decimals.
    let overallMeanRecall: Double
}

/// Rounds a Double to 3 decimal places (round-half-away-from-zero).
/// §5: round(x, 3) — matches Python's built-in round for values away from
/// the half-boundary.
private func round3(_ x: Double) -> Double {
    (x * 1000.0).rounded() / 1000.0
}

/// Aggregates per-question scores and evidence recalls into §5 summary metrics.
///
/// - Parameter scores: Array of (category, score, evidenceRecall) tuples.
///   `score` is the value returned by `scoreQuestion`;
///   `evidenceRecall` is the value returned by `evidenceRecall(context:evidence:)`.
/// - Returns: A `LoCoMoSpecAggregate` with per-category and overall metrics.
///
/// §5 of LOCOMO_OFFICIAL_PROTOCOL.md:
///   acc_counts[category] += metric_value
///   accuracy = round(acc_counts[k] / total_counts[k], 3)
///   overall  = round(total_correct / total_questions, 3)
///   category order: [4, 1, 2, 3, 5]
func loCoMoSpecAggregate(
    scores: [(category: Int, score: Double, evidenceRecall: Double)]
) -> LoCoMoSpecAggregate {
    // Accumulate per-category totals.
    var accCounts  = [Int: Double]()
    var totalCounts = [Int: Int]()
    var recallSums  = [Int: Double]()

    for item in scores {
        let cat = item.category
        accCounts[cat,   default: 0.0] += item.score
        totalCounts[cat, default: 0]   += 1
        recallSums[cat,  default: 0.0] += item.evidenceRecall
    }

    // §5: category order [4, 1, 2, 3, 5].
    let categoryOrder = [4, 1, 2, 3, 5]
    let byCategory = categoryOrder.map { cat -> LoCoMoSpecCategoryMetrics in
        let count = totalCounts[cat] ?? 0
        let acc   = count > 0 ? round3((accCounts[cat] ?? 0.0) / Double(count)) : 0.0
        let rec   = count > 0 ? round3((recallSums[cat] ?? 0.0) / Double(count)) : 0.0
        return LoCoMoSpecCategoryMetrics(
            category:      cat,
            accuracy:      acc,
            questionCount: count,
            meanRecall:    rec
        )
    }

    // Overall: sum of all acc_counts / sum of all total_counts.
    let totalScore     = accCounts.values.reduce(0.0, +)
    let totalQuestions = totalCounts.values.reduce(0, +)
    let overall        = totalQuestions > 0 ? round3(totalScore / Double(totalQuestions)) : 0.0

    let totalRecall    = recallSums.values.reduce(0.0, +)
    let overallRecall  = totalQuestions > 0 ? round3(totalRecall / Double(totalQuestions)) : 0.0

    return LoCoMoSpecAggregate(
        overall:          overall,
        totalQuestions:   totalQuestions,
        byCategory:       byCategory,
        overallMeanRecall: overallRecall
    )
}
