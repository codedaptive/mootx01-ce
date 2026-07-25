import Foundation
import AriaMCP   // JSONValue

// MARK: - ReviewBuilder  (FAB5-G1 — protocol + the four builders)
//
// A builder reads existing ARIA surfaces through `ReviewSurfaceReading` and
// assembles a `ReviewReport`. It performs NO lens math: every number in a report
// was computed by a lens and parsed out of that lens's response.
//
// Three invariants hold for all four builders, and the tests assert each:
//
//  1. Deterministic. `now` is a parameter; no builder reads the clock. Same
//     `now` + same responses ⇒ byte-identical report.
//  2. Non-throwing. A refused or unparseable surface becomes a section notice.
//     One dead surface degrades one section; the report still builds.
//  3. Provenance-complete. Every emitted item names the tool that produced it
//     and carries the response line it came from.

// MARK: - ReviewConfiguration

/// The knobs the builders read. One value type so a caller configures a Review
/// Center once and every builder agrees.
public struct ReviewConfiguration: Sendable, Equatable {
    /// The wing whose tunnel graph the keystones lens ranks. `moot_lens_keystones`
    /// REQUIRES a wing (it has no estate-wide mode), so this has to be supplied.
    /// Default matches the substrate's own default wing for agent-filed memories.
    public let wing: String
    /// How many keystones to request (`topK`).
    public let keystoneCount: Int
    /// Row cap for `moot_memory_search` and `moot_fact_search`.
    public let searchLimit: Int
    /// How many journal entries to read (`last_n`).
    public let journalEntryCount: Int
    /// Z-score magnitude threshold for the cohesion lens.
    public let cohesionThreshold: Double
    /// Query text for the "recent context" recall. A query is required by
    /// `moot_memory_search`; this is the estate-neutral default the FAB5-H1
    /// SummarizeWorker also uses.
    public let contextQuery: String
    /// Agent whose journal is read. `nil` = the server's own MCP agent identity
    /// (the `moot_read_journal` default).
    public let journalAgent: String?

    public init(
        wing: String = "Agentic Memory",
        keystoneCount: Int = 5,
        searchLimit: Int = 20,
        journalEntryCount: Int = 10,
        cohesionThreshold: Double = 1.5,
        contextQuery: String = "recent work",
        journalAgent: String? = nil
    ) {
        self.wing = wing
        self.keystoneCount = keystoneCount
        self.searchLimit = searchLimit
        self.journalEntryCount = journalEntryCount
        self.cohesionThreshold = cohesionThreshold
        self.contextQuery = contextQuery
        self.journalAgent = journalAgent
    }
}

// MARK: - ReviewBuilder

/// Builds one kind of review.
public protocol ReviewBuilder: Sendable {
    /// Which review this builder produces. Matches the `kind` of every report
    /// it returns.
    var kind: ReviewKind { get }
    /// The knobs this builder reads.
    var configuration: ReviewConfiguration { get }
    /// The window arithmetic this builder uses.
    var schedule: ReviewSchedule { get }

    /// Build the report.
    ///
    /// - Parameters:
    ///   - now: the instant the review is "as of". Injected — never `Date()`.
    ///   - reader: the read seam. Production passes `MootToolCallingReviewReader`.
    /// - Returns: a report, always. Never throws; degraded surfaces become notices.
    func build(now: Date, reader: any ReviewSurfaceReading) async -> ReviewReport
}

// MARK: - Section assembly (shared by all four builders)

extension ReviewBuilder {

    /// Call one surface and turn its response into a section.
    ///
    /// The single funnel every section goes through, so refusal handling and
    /// empty-notice wording are identical across all four reviews:
    ///  - refusal (`isError`) ⇒ empty items, notice = the substrate's message
    ///  - parsed nothing ⇒ empty items, notice = the response's first line, which
    ///    is the surface's own count line ("theme_weather: 0 result(s)")
    ///  - parsed items but `keep` rejected them all ⇒ empty items, notice naming
    ///    both the response count and the criterion nothing met, so "the surface
    ///    is quiet" is never confused with "the surface answered, none qualified"
    ///  - parsed something that `keep` accepted ⇒ items, no notice
    ///
    /// - Parameters:
    ///   - keep: per-item predicate applied after parsing (window clipping,
    ///     status or sign filters). Default keeps everything.
    ///   - keepDescription: what `keep` selects, for the all-filtered notice.
    func section(
        id: String,
        title: String,
        surface: ReviewSurface,
        arguments: [String: JSONValue],
        reader: any ReviewSurfaceReading,
        keep: (ReviewItem) -> Bool = { _ in true },
        keepDescription: String? = nil,
        parse: (String, ReviewProvenanceContext) -> [ReviewItem]
    ) async -> ReviewSection {
        let response = await reader.call(surface, arguments: arguments)
        let context = ReviewProvenanceContext(
            surface: surface,
            arguments: ReviewProvenance.renderArguments(arguments))
        guard !response.isError else {
            return ReviewSection(
                id: id, title: title, items: [],
                notice: Self.refusalNotice(surface: surface, text: response.text))
        }
        let parsed = parse(response.text, context)
        guard !parsed.isEmpty else {
            return ReviewSection(
                id: id, title: title, items: [],
                notice: Self.emptyNotice(surface: surface, text: response.text))
        }
        let items = parsed.filter(keep)
        guard !items.isEmpty else {
            let base = Self.emptyNotice(surface: surface, text: response.text)
            let criterion = keepDescription.map { " — none \($0)" } ?? ""
            return ReviewSection(id: id, title: title, items: [], notice: base + criterion)
        }
        return ReviewSection(id: id, title: title, items: items, notice: nil)
    }

    /// A section for a facet no existing read-only surface can answer. Named
    /// explicitly rather than silently omitted, and never filled with a plausible
    /// substitute — a consumer must be able to tell "nothing to report" from
    /// "nothing can be reported yet".
    func gapSection(id: String, title: String, gap: String) -> ReviewSection {
        ReviewSection(id: id, title: title, items: [], notice: gap)
    }

    /// Notice text for a refused surface: name the tool, then quote the reason.
    static func refusalNotice(surface: ReviewSurface, text: String) -> String {
        let reason = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty
            ? "\(surface.rawValue) refused the call and gave no reason."
            : "\(surface.rawValue): \(reason)"
    }

    /// Notice text for a surface that answered but yielded no items. The first
    /// response line is the surface's own summary ("keystones: 0 result(s)",
    /// "contradicts_tunnels: none"), which is the most honest thing to show.
    static func emptyNotice(surface: ReviewSurface, text: String) -> String {
        let firstLine = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty
            ? "\(surface.rawValue) returned nothing."
            : "\(surface.rawValue): \(firstLine)"
    }
}

// MARK: - Shared argument builders
//
// One place per surface where its argument dictionary is composed, so all four
// builders call each lens with the same shape and a schema change lands once.

extension ReviewBuilder {

    /// `moot_lens_theme_weather` — default half-life (7 days) left implicit so the
    /// substrate owns the default.
    var themeWeatherArguments: [String: JSONValue] { [:] }

    /// `moot_lens_keystones` — wing is required by the tool; topK is clamped
    /// server-side at 500.
    var keystoneArguments: [String: JSONValue] {
        [
            "wing": .string(configuration.wing),
            "topK": .integer(Int64(configuration.keystoneCount)),
        ]
    }

    /// `moot_lens_cohesion` — estate mode (no `dataset_id`).
    var cohesionArguments: [String: JSONValue] {
        ["threshold": .double(configuration.cohesionThreshold)]
    }

    /// `moot_lens_contradiction` — takes no arguments beyond the estate.
    var contradictionArguments: [String: JSONValue] { [:] }

    /// `moot_memory_search` — hybrid recall of the review's context query.
    var recallArguments: [String: JSONValue] {
        [
            "query": .string(configuration.contextQuery),
            "limit": .integer(Int64(configuration.searchLimit)),
        ]
    }

    /// `moot_fact_search` — no query, so every active fact within the row cap.
    var factArguments: [String: JSONValue] {
        ["limit": .integer(Int64(configuration.searchLimit))]
    }

    /// `moot_read_journal` — agent omitted means the server's own MCP identity.
    var journalArguments: [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "last_n": .integer(Int64(configuration.journalEntryCount)),
        ]
        if let agent = configuration.journalAgent {
            arguments["agent"] = .string(agent)
        }
        return arguments
    }

    /// `moot_lens_drift` — splits before/after at the review window's start.
    func driftArguments(splitAt: Date) -> [String: JSONValue] {
        ["splitAt": .string(ReviewSchedule.iso8601(splitAt))]
    }

    /// Keep items whose filed instant falls inside the window. Items with no
    /// instant are KEPT: `moot_memory_search` reports no filed time, and dropping
    /// its results would empty the recall sections entirely. The window is
    /// documented as advisory for those surfaces.
    func withinWindow(_ window: ReviewWindow) -> (ReviewItem) -> Bool {
        { item in
            guard let occurredAt = item.occurredAt else { return true }
            return window.contains(occurredAt)
        }
    }
}

// MARK: - DashboardReviewBuilder

/// The estate as it stands: what has momentum, what holds the graph together,
/// what conflicts. No time window — the dashboard is a "right now" surface.
public struct DashboardReviewBuilder: ReviewBuilder {
    public let kind = ReviewKind.dashboard
    public let configuration: ReviewConfiguration
    public let schedule: ReviewSchedule

    public init(
        configuration: ReviewConfiguration = ReviewConfiguration(),
        schedule: ReviewSchedule = ReviewSchedule()
    ) {
        self.configuration = configuration
        self.schedule = schedule
    }

    public func build(now: Date, reader: any ReviewSurfaceReading) async -> ReviewReport {
        let window = schedule.window(for: kind, now: now)
        // Sequential, not concurrent: the reader is one actor-backed transport
        // and a review is not latency-critical. Sequential order also makes the
        // recorded call sequence deterministic, which the tests assert.
        let momentum = await section(
            id: "momentum", title: "review.section.momentum",
            surface: .themeWeather, arguments: themeWeatherArguments, reader: reader,
            parse: ReviewLineParsing.themeWeather)
        let keystones = await section(
            id: "keystones", title: "review.section.keystones",
            surface: .keystones, arguments: keystoneArguments, reader: reader,
            parse: ReviewLineParsing.keystones)
        let conflicts = await section(
            id: "conflicts", title: "review.section.conflicts",
            surface: .contradiction, arguments: contradictionArguments, reader: reader,
            parse: ReviewLineParsing.contradictionTunnels)
        return ReviewReport(
            kind: kind, generatedAt: now, window: window,
            sections: [momentum, keystones, conflicts])
    }
}

// MARK: - MorningReviewBuilder

/// Today's context plus what is still open: the journal since yesterday, a
/// recall of recent work, and the contradiction findings still awaiting a call.
public struct MorningReviewBuilder: ReviewBuilder {
    public let kind = ReviewKind.morning
    public let configuration: ReviewConfiguration
    public let schedule: ReviewSchedule

    public init(
        configuration: ReviewConfiguration = ReviewConfiguration(),
        schedule: ReviewSchedule = ReviewSchedule()
    ) {
        self.configuration = configuration
        self.schedule = schedule
    }

    public func build(now: Date, reader: any ReviewSurfaceReading) async -> ReviewReport {
        let window = schedule.window(for: kind, now: now)
        let journal = await section(
            id: "journal", title: "review.section.journal",
            surface: .journal, arguments: journalArguments, reader: reader,
            keep: withinWindow(window),
            keepDescription: "filed inside the review window",
            parse: ReviewLineParsing.journal)
        let context = await section(
            id: "context", title: "review.section.context",
            surface: .memorySearch, arguments: recallArguments, reader: reader,
            parse: ReviewLineParsing.drawers)
        // Open work = the hunter's PROPOSED contradiction edges: findings that
        // need a human accept/reject (moot_review_tunnel), not settled history.
        let openWork = await section(
            id: "open-work", title: "review.section.openWork",
            surface: .contradiction, arguments: contradictionArguments, reader: reader,
            keep: { $0.status == .proposed },
            keepDescription: "awaiting review",
            parse: ReviewLineParsing.contradictionTunnels)
        return ReviewReport(
            kind: kind, generatedAt: now, window: window,
            sections: [journal, context, openWork])
    }
}

// MARK: - EndOfDayReviewBuilder

/// What changed, what was decided, what wants attention: the day's recall, the
/// facts filed today, and the lexical odd-ones-out.
public struct EndOfDayReviewBuilder: ReviewBuilder {
    public let kind = ReviewKind.endOfDay
    public let configuration: ReviewConfiguration
    public let schedule: ReviewSchedule

    public init(
        configuration: ReviewConfiguration = ReviewConfiguration(),
        schedule: ReviewSchedule = ReviewSchedule()
    ) {
        self.configuration = configuration
        self.schedule = schedule
    }

    public func build(now: Date, reader: any ReviewSurfaceReading) async -> ReviewReport {
        let window = schedule.window(for: kind, now: now)
        let changes = await section(
            id: "changes", title: "review.section.changes",
            surface: .memorySearch, arguments: recallArguments, reader: reader,
            parse: ReviewLineParsing.drawers)
        // Decisions = KG facts, clipped to today by their `filed=` stamp. A fact
        // is the estate's record of a settled call, which is what an end-of-day
        // review asks for.
        let decisions = await section(
            id: "decisions", title: "review.section.decisions",
            surface: .factSearch, arguments: factArguments, reader: reader,
            keep: withinWindow(window),
            keepDescription: "filed inside the review window",
            parse: ReviewLineParsing.facts)
        let attention = await section(
            id: "attention", title: "review.section.attention",
            surface: .cohesion, arguments: cohesionArguments, reader: reader,
            parse: ReviewLineParsing.cohesionOutliers)
        return ReviewReport(
            kind: kind, generatedAt: now, window: window,
            sections: [changes, decisions, attention])
    }
}

// MARK: - WeeklyReviewBuilder

/// The week's housekeeping: what is fading, how the estate's shape shifted, what
/// contradicts, and what is retire-ready.
///
/// The mission also asks for "duplicate". No READ-ONLY surface answers it: the
/// cohesion lens finds odd-ones-out (the opposite of duplicates), and the one
/// tool that reasons about redundancy — `moot_consolidate` — mutates the estate,
/// which this module never does. That facet ships as a named gap section rather
/// than a near-miss mapping. Closing it needs a read-only similarity surface in
/// the substrate; it is not work this layer can do.
public struct WeeklyReviewBuilder: ReviewBuilder {
    public let kind = ReviewKind.weekly
    public let configuration: ReviewConfiguration
    public let schedule: ReviewSchedule

    /// Notice text for the duplicate facet. Substrate-capability prose, not UI
    /// copy — it names the missing surface so a consumer can report it honestly.
    static let duplicateGapNotice = """
        No read-only duplicate-detection surface exists yet: moot_lens_cohesion \
        reports lexical outliers (the opposite of duplicates) and moot_consolidate \
        mutates the estate, which reviews never do.
        """

    public init(
        configuration: ReviewConfiguration = ReviewConfiguration(),
        schedule: ReviewSchedule = ReviewSchedule()
    ) {
        self.configuration = configuration
        self.schedule = schedule
    }

    public func build(now: Date, reader: any ReviewSurfaceReading) async -> ReviewReport {
        let window = schedule.window(for: kind, now: now)
        // Stale = rooms whose recent attention share is BELOW their historical
        // share. Negative momentum is the theme_weather lens's own reading of
        // fading attention; nothing is recomputed here.
        let fading = await section(
            id: "fading", title: "review.section.fading",
            surface: .themeWeather, arguments: themeWeatherArguments, reader: reader,
            keep: { ($0.magnitude ?? 0) < 0 },
            keepDescription: "fading (negative momentum)",
            parse: ReviewLineParsing.themeWeather)
        let drift = await section(
            id: "drift", title: "review.section.drift",
            surface: .drift,
            arguments: driftArguments(splitAt: schedule.splitInstant(for: window)),
            reader: reader,
            parse: ReviewLineParsing.drift)
        let contradicted = await section(
            id: "contradicted", title: "review.section.contradicted",
            surface: .contradiction, arguments: contradictionArguments, reader: reader,
            parse: ReviewLineParsing.contradictionTunnels)
        // Retire-ready = subject+predicate keys with more than one active object.
        // Settled with moot_retire_fact, by the user, in a view — never here.
        let retireReady = await section(
            id: "retire-ready", title: "review.section.retireReady",
            surface: .contradiction, arguments: contradictionArguments, reader: reader,
            parse: ReviewLineParsing.conflictingFacts)
        let duplicates = gapSection(
            id: "duplicates", title: "review.section.duplicates",
            gap: Self.duplicateGapNotice)
        return ReviewReport(
            kind: kind, generatedAt: now, window: window,
            sections: [fading, drift, contradicted, retireReady, duplicates])
    }
}

// MARK: - ReviewBuilderFactory

/// The builder for a given review, so callers (FAB5-G2's views, FAB5-H2's
/// worker, FAB5-K1's panes) switch on `ReviewKind` in one place only.
public enum ReviewBuilderFactory {
    public static func builder(
        for kind: ReviewKind,
        configuration: ReviewConfiguration = ReviewConfiguration(),
        schedule: ReviewSchedule = ReviewSchedule()
    ) -> any ReviewBuilder {
        switch kind {
        case .dashboard:
            return DashboardReviewBuilder(configuration: configuration, schedule: schedule)
        case .morning:
            return MorningReviewBuilder(configuration: configuration, schedule: schedule)
        case .endOfDay:
            return EndOfDayReviewBuilder(configuration: configuration, schedule: schedule)
        case .weekly:
            return WeeklyReviewBuilder(configuration: configuration, schedule: schedule)
        }
    }
}

/// The provenance fields shared by every item parsed out of one response —
/// passed to the parsers so each item can be stamped without re-rendering the
/// argument dictionary per line.
public struct ReviewProvenanceContext: Sendable, Equatable {
    public let surface: ReviewSurface
    public let arguments: [String: String]

    public init(surface: ReviewSurface, arguments: [String: String]) {
        self.surface = surface
        self.arguments = arguments
    }

    /// Stamp one item's provenance with the line it was parsed from.
    public func provenance(line: String) -> ReviewProvenance {
        ReviewProvenance(surface: surface, arguments: arguments, responseLine: line)
    }
}
