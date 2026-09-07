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

/// The candidate-grab arm (ruling Q1 2026-08-19: build BOTH and compare).
public enum TemporalGrab: String, Sendable {
    /// The lexical coarse grab only (v1 behavior): the window re-orders or
    /// filters what the hybrid lanes surfaced.
    case pool
    /// The lexical grab UNIONED with a date-indexed store fetch: drawers
    /// whose eventTime falls inside the (max-padded) window join the pool
    /// even when no lexical lane surfaced them. Fixes the measured
    /// "evidence never in the pool" miss class.
    case dated
}

/// One temporal-recall match.
public struct TemporalMatch: Sendable, Equatable, Codable {
    public let id: String
    public let room: String
    public let content: String
    /// The drawer's event time in UTC ISO8601, or nil when it carried none.
    public let eventTime: String?
    /// Whether the drawer's event time fell inside the applied window(s)
    /// (at the applied pad — see `padDays`).
    public let inWindow: Bool
    /// Sliding-window distance: 0 = inside the stated window; n = inside
    /// only after widening by ±n days (ruling Q2, cap ±10); nil = outside
    /// every padded window (loose-mode tail rows only).
    public let padDays: Int?
    public init(id: String, room: String, content: String,
                eventTime: String?, inWindow: Bool, padDays: Int? = nil) {
        self.id = id
        self.room = room
        self.content = content
        self.eventTime = eventTime
        self.inWindow = inWindow
        self.padDays = padDays
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
    /// The grab arm that supplied the candidates.
    public let grab: TemporalGrab
    /// The sliding-window pad (days) at which the member quorum was met;
    /// 0 = the stated window sufficed. Meaningless when `windows` is empty.
    public let appliedPad: Int
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

    /// Sliding-window hard cap (ruling Q2): the window may widen ±1 day at a
    /// time while members < limit, never beyond ±10 days.
    public static let maxPadDays = 10

    /// Member re-rank ceiling: at most this many in-window members are
    /// hydrated and affinity-folded (a month window over a dated grab can
    /// admit hundreds; the fold must stay bounded). Members beyond the cap
    /// keep coarse order after the folded block, within their pad tier.
    public static let rerankCap = 200

    /// Parses the fixed "YYYY-MM-DDTHH:MM:SSZ" bound shape to a Date.
    /// Deterministic (fixed UTC grammar, no locale, no clock).
    private static func isoDate(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

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
    /// Internal (not private) so the strict-shape contract is pinned by a
    /// direct test (codex finding 2026-08-26).
    internal static func explicitBound(_ raw: String, isFrom: Bool) throws -> String {
        // Strict shape validation (codex finding 2026-08-26): the previous
        // checks (length 10 + hyphen at 4; length 20 + trailing Z) accepted
        // values like "2023-aa-bb", which downstream shiftISODay force-
        // unwraps into a fatal trap — attacker-reachable through the public
        // moot_recall_temporal from/to arguments. Every character position
        // is now verified, so only genuine "YYYY-MM-DD" /
        // "YYYY-MM-DDTHH:MM:SSZ" shapes pass (all-ASCII by construction,
        // which the Rust twin's narration slicing also relies on).
        func matchesShape(_ s: String, _ shape: String) -> Bool {
            guard s.count == shape.count else { return false }
            for (c, template) in zip(s, shape) {
                if template == "9" {
                    guard c.isASCII, c.isNumber else { return false }
                } else {
                    guard c == template else { return false }
                }
            }
            return true
        }
        if matchesShape(raw, "9999-99-99") {
            return raw + (isFrom ? "T00:00:00Z" : "T23:59:59Z")
        }
        if matchesShape(raw, "9999-99-99T99:99:99Z") {
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
        to: String? = nil,
        grab: TemporalGrab = .pool
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
            origin: .internal,
            // Sub-span scoring is an additive-cost stage this caller does not
            // request; every caller names the switch (ruling 2026-09-07).
            subSpanScoring: .off)
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
        // Gap 3 scanner fork: the query ASKS FOR a date but states none
        // ("When did X happen?"). No window can apply — the date is the
        // ANSWER — so loose mode ranks REAL-dated memories (two-clock
        // backfilled eventTime, != filedAt) first and the caller reads the
        // date off the returned rows' event_time.
        let dateSeeking = windows.isEmpty && isDateSeekingQuery(query)
        if dateSeeking { source = "date-seeking" }

        // c'. DATED GRAB (ruling Q1: second arm) — when a window resolved,
        //     fetch drawers BY DATE from the store (eventAfter/eventBefore,
        //     window pre-padded to the ±10 cap so the sliding expansion below
        //     has material) and union them into the pool. This is what makes
        //     evidence the lexical lanes never surfaced reachable at all.
        var candidatePool = candidates
        if grab == .dated && !windows.isEmpty {
            let windowFilters: [LocusKit.Filter] = windows.compactMap { w in
                let padded = paddedWindow(w, days: maxPadDays)
                guard let s = isoDate(padded.start), let e = isoDate(padded.end) else {
                    return nil
                }
                return .all([.eventAfter(s), .eventBefore(e)])
            }
            if !windowFilters.isEmpty {
                let datedFrame = LocusKit.RecallFrame(
                    filterChain: [LocusKit.Filter.all([filter, .any(windowFilters)])],
                    hydrationLevel: .bitmapOnly,
                    limit: poolSize,
                    ordering: .byCaptureTimeDesc)
                let datedRequest = GLKRecallRequest(
                    frame: datedFrame,
                    mode: .unionBest,
                    scoring: .raw,
                    limit: poolSize,
                    fallback: .allowDegraded,
                    queryText: query,
                    traceLimit: limit,
                    origin: .internal,
                    // Sub-span scoring off, as on the lexical pool request above.
                    subSpanScoring: .off)
                let datedResult = try await kit.recall(handle, datedRequest)
                var seen = Set(candidatePool.map(\.id))
                for (index, hit) in datedResult.hits.enumerated() where !seen.contains(hit.id) {
                    seen.insert(hit.id)
                    // Dated-only candidates rank after the lexical pool: their
                    // coarse rank continues past the pool's tail, so the
                    // affinity fold (not arrival order) decides their place.
                    candidatePool.append(NeuronKit.ReductionCandidate.from(
                        hit: hit, coarseRank: candidatePool.count + index))
                }
            }
        }

        // c. WINDOW APPLICATION with SLIDING EXPANSION (ruling Q2) —
        //    padDays(c) = the smallest pad in 0...maxPadDays at which the
        //    candidate's event time falls inside some window; nil = outside
        //    even the widest. The applied pad is the smallest one whose
        //    member count reaches `limit` (or the cap if none does).
        func padDays(_ c: NeuronKit.ReductionCandidate) -> Int? {
            guard let et = c.eventTime, !windows.isEmpty else { return nil }
            let iso = isoString(et)
            for pad in 0...maxPadDays {
                if windows.contains(where: {
                    windowContains(paddedWindow($0, days: pad), eventTime: iso)
                }) {
                    return pad
                }
            }
            return nil
        }
        // Date-seeking membership: a candidate is a "member" when it carries
        // a REAL event date (eventTime present and != filedAt); pad 0. The
        // ordinary path computes sliding-window pads.
        let flagged: [(candidate: NeuronKit.ReductionCandidate, pad: Int?)] =
            dateSeeking
            ? candidatePool.map { c in
                let real = c.eventTime != nil && c.filedAt != nil && c.eventTime != c.filedAt
                return (c, real ? 0 : nil)
            }
            : candidatePool.map { ($0, padDays($0)) }
        var appliedPad = 0
        if !windows.isEmpty {
            while appliedPad < maxPadDays,
                  flagged.count(where: { ($0.pad ?? .max) <= appliedPad }) < limit {
                appliedPad += 1
            }
        }
        let members = flagged.filter { ($0.pad ?? .max) <= appliedPad }
        let outsiders = flagged.filter { ($0.pad ?? .max) > appliedPad }

        // c''. WITHIN-WINDOW RE-RANK (ruling Q3, deterministic): the members
        //     are affinity-folded with the same composition machinery
        //     PreciseRecall uses, then ordered pad-first (date proximity is
        //     the primary key, affinity the secondary). The fold is bounded
        //     by `rerankCap`; members beyond the cap keep coarse order after
        //     the folded block. Pre-selection into the cap is (pad, coarse).
        let preselected = members.sorted {
            ($0.pad ?? .max, $0.candidate.coarseRank)
                < ($1.pad ?? .max, $1.candidate.coarseRank)
        }
        let foldSet = Array(preselected.prefix(rerankCap))
        let overflow = Array(preselected.dropFirst(rerankCap))
        let padByID = Dictionary(uniqueKeysWithValues: foldSet.map { ($0.candidate.id, $0.pad ?? 0) })
        // Query-side §8.3 lattice anchor (W2.5 Track S); the default text
        // composition never reads it, but lattice-bearing compositions can.
        //
        // M4: read the pre-computed anchor from `result.queryLatticeAnchor` rather
        // than re-deriving. The RecallDirector derives it exactly once inside
        // compileSketch (single-derivation doctrine).
        let temporalReductionQuery = NeuronKit.ReductionQuery(
            text: query,
            udcCode: result.queryLatticeAnchor?.udcCode ?? "",
            qid: result.queryLatticeAnchor?.qid ?? "")
        let folded = try await NeuronKit.reduceLate(
            composition: NeuronKit.CompositionGrid.named(nil),
            query: temporalReductionQuery,
            candidates: foldSet.map(\.candidate),
            limit: foldSet.count,
            hydrate: { ids in try await kit.hydrate(handle, ids: ids) })
        // Pad-first over the affinity order: enumerate the fold order so the
        // sort is explicitly stable on (pad, affinityIndex).
        let rankedMembers: [(NeuronKit.ReductionCandidate, Int)] = folded.enumerated()
            .map { (index, c) in (c, index) }
            .sorted { (padByID[$0.0.id] ?? 0, $0.1) < (padByID[$1.0.id] ?? 0, $1.1) }
            .map { ($0.0, padByID[$0.0.id] ?? 0) }
            + overflow.map { ($0.candidate, $0.pad ?? 0) }

        // Final ordering. Loose keeps everything: members first, then the
        // outsiders in coarse order (v1 semantics, now pad-aware). Tight
        // returns members only.
        let survivorsWithPad: [(NeuronKit.ReductionCandidate, Int?)]
        switch mode {
        case .loose:
            survivorsWithPad = Array((rankedMembers.map { ($0.0, Int?($0.1)) }
                + outsiders.map { ($0.candidate, $0.pad) }).prefix(limit))
        case .tight:
            survivorsWithPad = Array(rankedMembers.map { ($0.0, Int?($0.1)) }.prefix(limit))
        }

        // d. LATE HYDRATION for any survivor the fold did not hydrate (loose
        //    outsiders and overflow members). A hydrate failure is a failed
        //    recall, not an empty one — the error propagates.
        let unhydrated = survivorsWithPad.filter { $0.0.content.isEmpty }.map { $0.0.id }
        let bodies = unhydrated.isEmpty
            ? [:] : try await kit.hydrate(handle, ids: unhydrated)
        let matches = survivorsWithPad.map { candidate, pad in
            TemporalMatch(
                id: candidate.id,
                room: candidate.room,
                content: candidate.content.isEmpty
                    ? (bodies[candidate.id] ?? "") : candidate.content,
                eventTime: candidate.eventTime.map(isoString),
                inWindow: pad != nil,
                padDays: pad)
        }
        return TemporalRecallOutcome(
            matches: matches, windows: windows, windowSource: source, mode: mode,
            grab: grab, appliedPad: windows.isEmpty ? 0 : appliedPad)
    }
}

// Note: the private `reductionQuery(for:)` helper was removed in M4.
// The anchor is now derived once by the RecallDirector's compileSketch and
// surfaced via GLKRecallResult.queryLatticeAnchor. TemporalRecall reads it
// there; no re-derivation here (single-derivation doctrine).
