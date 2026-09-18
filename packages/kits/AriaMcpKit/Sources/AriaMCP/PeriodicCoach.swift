/// Deterministic coaching block renderer for the Moot Modes periodic coaching system.
///
/// ## Tone contract
///
/// Bob's positive-reinforcement shape (spec §4): praise the parts done right by
/// name, then ONE improvement framed as friendly confidence ("I bet next time…").
/// Never scolding, never more than one suggestion per block. ~80 token cap.
///
/// ## Template selection
///
/// Templates are selected deterministically from the session's call counters.
/// No LLM is involved. The first matching template wins; the fallback always fires.
///
/// ## Golden pin
///
/// `renderBlock(for:)` is the entry point tested by `PeriodicCoachTests.swift`
/// and the Rust twin `periodic_coach.rs`. The golden-pin fixture at
/// `Tests/Conformance/modes_coaching_fixture.json` pins one specific counter
/// snapshot → exact block text in both ports.
///
/// ## Block format
///
/// ```
/// [Moot coaching · call N]
/// <praise sentence>
/// <one improvement sentence framed as "I bet …">
/// Modes available: <attribution breakdown>.
/// ```
///
/// The block is appended to the FIRST text block of the result (after the
/// normal `hint:` prefix the dispatch layer would add — coaching rides on the
/// normal response). The total block is capped at ~80 tokens; truncation is
/// handled by the template cap: no template body exceeds three sentences.
enum PeriodicCoach {

    // MARK: - Public entry point

    /// Render the coaching block for the given snapshot.
    ///
    /// - Parameter snapshot: Immutable counter state at the time of the coaching trigger.
    /// - Returns: The full coaching block string (including the header line).
    static func renderBlock(for snapshot: CoachingSnapshot) -> String {
        let header = "[Moot coaching · call \(snapshot.totalCalls)]"
        let body = selectTemplate(snapshot: snapshot)
        let modesLine = modesAvailableLine(snapshot: snapshot)
        return "\(header)\n\(body)\n\(modesLine)"
    }

    // MARK: - Template selection

    /// Select the best-matching template from the snapshot.
    ///
    /// Templates are evaluated in priority order; the first match wins.
    /// The fallback template always matches.
    private static func selectTemplate(snapshot: CoachingSnapshot) -> String {
        // Template 1: Heavy search pattern — moot_memory_search dominant.
        if let searchCount = snapshot.toolCounts["moot_memory_search"],
           searchCount >= 5 {
            let hydrationCount = snapshot.toolCounts["moot_memory_get"] ?? 0
            if hydrationCount > 0 {
                return "Nice run: \(searchCount) searches and every hydration you made was on a row you'd already ranked — that's the cheap-pile pattern working. I bet recall_precise earns a place when you know the subject exactly."
            }
            return "Good searching — \(searchCount) queries this session. I bet moot_memory_get on rank-1 IDs would save you a round-trip when you already know what you need."
        }

        // Template 2: Filing pattern — moot_file_memory dominant.
        if let fileCount = snapshot.toolCounts["moot_file_memory"],
           fileCount >= 3 {
            let confirmCount = snapshot.toolCounts["moot_confirm_memory"] ?? 0
            if confirmCount == 0 {
                return "Good filing — \(fileCount) memories stored this session. I bet moot_confirm_memory on your most important ones marks them user-verified, which puts them on the recall fast path."
            }
            return "Solid filing: \(fileCount) memories stored, \(confirmCount) confirmed. I bet moot_link_memories between related ones builds the association graph so future searches surface the cluster."
        }

        // Template 3: Fact-heavy pattern — moot_file_fact dominant.
        if let factCount = snapshot.toolCounts["moot_file_fact"],
           factCount >= 3 {
            return "You're building the knowledge graph — \(factCount) facts filed. I bet moot_fact_timeline for your main subject shows you what the estate knows over time."
        }

        // Template 4: Bigram pattern — search→get bigram strong (good pattern, reinforce).
        let searchToGet = snapshot.bigramCounts["moot_memory_search→moot_memory_get"] ?? 0
        if searchToGet >= 2 {
            return "Great pattern: search then immediately get — you're navigating by relevance rank. I bet adding recall_temporal to your toolkit answers date-anchored questions in one call."
        }

        // Template 5: Single-mode session — praise the focus.
        if let topMode = topMode(snapshot: snapshot), topMode.1 >= 3 {
            return "Focused \(topMode.0) session — \(topMode.1) calls in that mode. I bet a quick moot_estate_status at the start of your next session orients you even faster."
        }

        // Fallback: general positive reinforcement.
        let toolCount = snapshot.toolCounts.count
        return "Good session — \(snapshot.totalCalls) calls across \(toolCount) tool\(toolCount == 1 ? "" : "s"). I bet moot_estate_status teaches you a tool you haven't tried yet."
    }

    // MARK: - Modes available line

    /// Render the "Modes available: …" attribution breakdown.
    ///
    /// Shows top-2 used modes by percentage and marks unused modes.
    private static func modesAvailableLine(snapshot: CoachingSnapshot) -> String {
        let total = snapshot.modeAttributionCounts.values.reduce(0, +)
        guard total > 0 else {
            return "Modes available: Recall, Filing, Lenses, Vault, Curator (try mode:\"Recall=Auto\" on your next search)."
        }

        // Sort modes by attribution count (descending); tiebreak by mode name ascending
        // for determinism. Matches Rust's .sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0))).
        let sorted = snapshot.modeAttributionCounts.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key < $1.key // tiebreak: mode name ascending
        }
        let allModeNames = MootMode.allCases.map(\.rawValue)
        var parts: [String] = []

        for (name, count) in sorted.prefix(3) {
            let pct = Int(Double(count) / Double(total) * 100)
            parts.append("\(name) (\(pct)%)")
        }

        // Mark modes with zero attribution as unused (up to 2).
        let usedNames = Set(snapshot.modeAttributionCounts.keys)
        let unused = allModeNames.filter { !usedNames.contains($0) }.prefix(2)
        for name in unused {
            parts.append("\(name) (unused)")
        }

        return "Modes available: \(parts.joined(separator: ", "))."
    }

    // MARK: - Helpers

    /// Return the top attributed mode name and its call count, or nil when no
    /// mode attribution has been recorded.
    ///
    /// Tiebreak: descending count, then name ascending (same rule as `modesAvailableLine`).
    /// A deterministic tiebreak is required so both ports produce identical output
    /// when two modes share the highest attribution count.
    private static func topMode(snapshot: CoachingSnapshot) -> (String, Int)? {
        snapshot.modeAttributionCounts
            .sorted { lhs, rhs in
                // Primary: higher count wins.
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                // Tiebreak: name ascending (alphabetical).
                return lhs.key < rhs.key
            }
            .first
            .map { ($0.key, $0.value) }
    }
}
