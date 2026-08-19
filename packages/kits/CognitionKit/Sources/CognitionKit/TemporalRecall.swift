import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit

/// The window mode for temporal recall (decision record
/// DECISION_SEARCH_STRATEGY_RECIPES_2026-08-19, item 4, ruling Q1).
public enum TemporalWindowMode: String, Sendable {
    /// The window is a BOOST: in-window candidates rank first, everything
    /// else is retained after them. Safe against a wrong date parse.
    case loose
    /// The window is a HARD FILTER: only in-window candidates return. The
    /// retry/refocus mode for when a loose or ordinary recall came back weak.
    case tight
}

/// One temporal-recall match.
public struct TemporalMatch: Sendable, Equatable, Codable {
    public let id: String
    public let room: String
    public let content: String
    /// The drawer's event time in UTC ISO8601, or nil when it carried none.
    public let eventTime: String?
    /// Whether the drawer's event time fell inside the applied window(s).
    public let inWindow: Bool
    public init(id: String, room: String, content: String,
                eventTime: String?, inWindow: Bool) {
        self.id = id
        self.room = room
        self.content = content
        self.eventTime = eventTime
        self.inWindow = inWindow
    }
}

/// The recipe's outcome: matches plus the window facts the tool surface
/// narrates (which windows applied and where they came from).
public struct TemporalRecallOutcome: Sendable {
    public let matches: [TemporalMatch]
    /// The applied windows (empty when none resolved — loose mode only).
    public let windows: [QueryDateWindow]
    /// "explicit" (from/to args), "parsed" (query text), or "none".
    public let windowSource: String
    public let mode: TemporalWindowMode
}

/// Temporal-recall errors. Tight mode without a resolvable window is caller
/// misuse and fails loud — a tight filter over no window would silently
/// return everything or nothing depending on interpretation, and both lie.
public enum TemporalRecallError: Error, CustomStringConvertible {
    case tightModeRequiresWindow
    case invalidExplicitWindow(String)
    public var description: String {
        switch self {
        case .tightModeRequiresWindow:
            return "temporal_recall: window \"tight\" requires a date — none was "
                + "parsed from the query and no from/to was supplied"
        case .invalidExplicitWindow(let raw):
            return "temporal_recall: from/to must be YYYY-MM-DD or "
                + "YYYY-MM-DDTHH:MM:SSZ; got '\(raw)'"
        }
    }
}

/// TemporalRecall — the query-date window recipe. The EVENT_TIME_STUDY
/// measured that filed real dates move nothing because no lane reads the
/// QUERY's date; this recipe is that reading (SPEC ascent, pure sequencing —
/// the parse and window math live in NeuronKit.QueryDateWindow; the recipe
/// owns no algorithm):
///   a. WINDOW RESOLUTION: explicit `from`/`to` arguments win; else
///      `NeuronKit.parseQueryDateExpression(query)`. Month-only expressions
///      ("in July") expand against the coarse pool's own event-time year
///      span, so the estate's real timeline — not a clock — supplies the
///      candidate years (deterministic; no Date() anywhere).
///   b. GLK FETCH: the same coarse, high-recall, body-free grab as
///      PreciseRecall (.unionBest, .raw), with a WIDER default pool: the
///      window is the discriminator here, so recall must deliver material
///      for it to act on.
///   c. WINDOW APPLICATION: loose — stable re-rank, window membership as
///      the primary key and coarse rank as the tie-break; nothing dropped.
///      tight — filter to the window, coarse order retained.
///   d. LATE HYDRATION of the surviving `limit` rows only.
/// Read-only, deterministic (I-6).
public enum TemporalRecall {

    /// Default coarse pool. Wider than PreciseRecall's 30: the date window
    /// discriminates cheaply, so the grab errs toward recall.
    public static let defaultPool = 120

    /// Fixed UTC ISO8601 rendering for drawer event times (no fractional
    /// seconds — the same wire shape the import boundary accepts).
    private static func isoString(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    /// Parses an explicit from/to argument: a bare date expands to the day's
    /// bound (start for `from`, end for `to`); a full datetime passes through.
    private static func explicitBound(_ raw: String, isFrom: Bool) throws -> String {
        if raw.count == 10, raw[raw.index(raw.startIndex, offsetBy: 4)] == "-" {
            return raw + (isFrom ? "T00:00:00Z" : "T23:59:59Z")
        }
        if raw.count == 20, raw.hasSuffix("Z") {
            return raw
        }
        throw TemporalRecallError.invalidExplicitWindow(raw)
    }

    /// Runs temporal recall. See the type comment for the ascent.
    ///
    /// - Parameters mirror PreciseRecall where shared; `from`/`to` are the
    ///   explicit window override (either or both; explicit wins over parse),
    ///   `mode` is loose (boost) or tight (filter).
    public static func run(
        kit: GeniusLocusKit,
        handle: EstateHandle,
        query: String,
        filter: LocusKit.Filter,
        limit: Int,
        pool: Int = defaultPool,
        mode: TemporalWindowMode = .loose,
        from: String? = nil,
        to: String? = nil
    ) async throws -> TemporalRecallOutcome {
        let poolSize = max(pool, limit)

        // b. GLK FETCH — identical shape to PreciseRecall's coarse grab
        //    (body-free, high-recall .raw lane, trace budget = caller limit).
        let frame = LocusKit.RecallFrame(
            filterChain: [filter],
            hydrationLevel: .bitmapOnly,
            limit: poolSize,
            ordering: .byCaptureTimeDesc)
        let request = GLKRecallRequest(
            frame: frame,
            mode: .unionBest,
            scoring: .raw,
            limit: poolSize,
            fallback: .allowDegraded,
            queryText: query,
            traceLimit: limit,
            origin: .internal)
        let result = try await kit.recall(handle, request)
        let candidates = result.hits.enumerated().map { index, hit in
            NeuronKit.ReductionCandidate.from(hit: hit, coarseRank: index)
        }

        // a. WINDOW RESOLUTION (explicit wins; month-only expands against the
        //    pool's own event-time years).
        var windows: [QueryDateWindow] = []
        var source = "none"
        if from != nil || to != nil {
            let start = try from.map { try explicitBound($0, isFrom: true) }
                ?? "0000-01-01T00:00:00Z"
            let end = try to.map { try explicitBound($0, isFrom: false) }
                ?? "9999-12-31T23:59:59Z"
            windows = [QueryDateWindow(start: start, end: end, matchedText: "explicit")]
            source = "explicit"
        } else {
            switch parseQueryDateExpression(query) {
            case .anchored(let w):
                windows = w
                source = "parsed"
            case .monthOnly(let month, let text):
                let years = candidates.compactMap { $0.eventTime }.map {
                    Int(isoString($0).prefix(4))!
                }
                if let lo = years.min(), let hi = years.max() {
                    windows = expandMonthOnly(month: month, matchedText: text,
                                              years: lo...hi)
                    source = "parsed"
                }
            case .none:
                break
            }
        }
        if windows.isEmpty && mode == .tight {
            throw TemporalRecallError.tightModeRequiresWindow
        }

        // c. WINDOW APPLICATION — deterministic: membership primary, coarse
        //    rank secondary; a candidate with no event time is never in-window.
        func inWindow(_ c: NeuronKit.ReductionCandidate) -> Bool {
            guard let et = c.eventTime else { return false }
            let iso = isoString(et)
            return windows.contains { windowContains($0, eventTime: iso) }
        }
        let ordered: [(NeuronKit.ReductionCandidate, Bool)]
        switch mode {
        case .loose:
            let flagged = candidates.map { ($0, inWindow($0)) }
            ordered = flagged.filter(\.1) + flagged.filter { !$0.1 }
        case .tight:
            ordered = candidates.filter(inWindow).map { ($0, true) }
        }
        let survivors = Array(ordered.prefix(limit))

        // d. LATE HYDRATION of survivors only. A hydrate failure is a failed
        //    recall, not an empty one — the error propagates (PreciseRecall's
        //    fail-closed rule).
        let bodies = try await kit.hydrate(handle, ids: survivors.map { $0.0.id })
        let matches = survivors.map { candidate, isIn in
            TemporalMatch(
                id: candidate.id,
                room: candidate.room,
                content: bodies[candidate.id] ?? candidate.content,
                eventTime: candidate.eventTime.map(isoString),
                inWindow: isIn)
        }
        return TemporalRecallOutcome(
            matches: matches, windows: windows, windowSource: source, mode: mode)
    }
}
