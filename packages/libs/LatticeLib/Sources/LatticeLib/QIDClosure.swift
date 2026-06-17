// QIDClosure.swift
//
// The Q-ID taxonomic-closure surface: a process-global static lookup over
// the pinned Wikidata direct-edge graph (`QIDClosureEdges.json`). It loads
// the edge graph ONCE per process (mirroring `FDCRuntime`'s `Bundle.module`
// resource load) and exposes the TRANSITIVE ancestor closure of any Q-ID.
//
// The bundled artifact is a pinned, build-time, offline Wikidata snapshot of
// direct P31/P279 (instance-of / subclass-of) edges:
//
//   { "edges": { "<qid>": ["<sorted direct parent qids>", ...] }, ... }
//
// produced by the Q-ID closure ETL (EE build tooling) and checked in like the FDC
// artifacts. The runtime NEVER re-queries Wikidata — the closure is computed
// locally by BFS over these pinned edges. This keeps `ancestors(of:)` pure,
// deterministic, and byte-identical to the Rust port (`qid_closure.rs`).
//
// `ancestors(of:)` returns the transitive closure (all ancestors reachable by
// walking P31/P279 edges to the roots), EXCLUDING the queried qid itself,
// sorted numerically by the integer part of the Q-ID. Empty/unknown qid → [].
// Results are memoized per distinct qid per process.

import Foundation

/// The pinned Q-ID taxonomic-closure surface.
///
/// `QIDClosure.ancestors(of:)` returns the transitive P31/P279 ancestor
/// closure of a Wikidata Q-ID over the bundled, pinned edge graph. The graph
/// is a build-time offline snapshot — the runtime never re-queries Wikidata.
/// Mirrors the Rust `lattice_lib::qid_closure::ancestors` exactly: same edges,
/// same BFS, same numeric sort, same exclusion of the queried qid.
public enum QIDClosure {

    /// The transitive ancestor closure of `qid` over the pinned P31/P279 edge
    /// graph, sorted numerically by the integer part of the Q-ID and EXCLUDING
    /// `qid` itself. An empty or unknown qid (or unavailable artifact) → `[]`.
    ///
    /// Deterministic and pure over the pinned artifact. The result is memoized
    /// per distinct qid for the life of the process: the closure of a given qid
    /// is computed at most once. Byte-identical to the Rust port.
    ///
    /// - Parameter qid: A Wikidata Q-ID, e.g. `"Q146"`. A leading `"Q"` is
    ///   expected; any string with no edges resolves to `[]`.
    /// - Returns: The sorted ancestor Q-IDs, e.g. `["Q336", "Q729", ...]`.
    public static func ancestors(of qid: String) -> [String] {
        guard !qid.isEmpty, let graph = edges else { return [] }

        // Memoization: the closure of a distinct qid is computed once per
        // process. `os_unfair_lock` guards the cache; the BFS itself runs
        // outside the lock so concurrent callers for different qids do not
        // serialize on the compute. A lost-update race (two threads computing
        // the same qid) is harmless — the closure is pure, so both produce the
        // identical array and the last writer wins with the same value.
        os_unfair_lock_lock(&memoLock)
        let cached = memo[qid]
        os_unfair_lock_unlock(&memoLock)
        if let cached { return cached }

        let result = Self.computeClosure(of: qid, in: graph)

        os_unfair_lock_lock(&memoLock)
        memo[qid] = result
        os_unfair_lock_unlock(&memoLock)
        return result
    }

    /// True when the bundled edge graph loaded and the surface is ready.
    public static var isAvailable: Bool { edges != nil }

    /// The pinned-artifact version string (`"version"` field of the bundled
    /// graph), or `"0.0.0-unavailable"` when the artifact failed to load.
    /// Callers record it as provenance.
    public static var dataVersion: String { graphFile?.version ?? "0.0.0-unavailable" }

    // MARK: - BFS over the pinned edges

    /// Compute the transitive closure of `qid` by breadth-first walk over the
    /// direct-edge map, excluding `qid` itself, returned sorted numerically by
    /// the integer part of the Q-ID. The walk is iterative (no recursion depth
    /// bound) and dedupes via the `seen` set, so cycles in the source graph —
    /// were any present — terminate. Identical control flow to the Rust port's
    /// `ancestors`.
    private static func computeClosure(of qid: String, in edges: [String: [String]]) -> [String] {
        var seen = Set<String>()
        // Seed the frontier with the direct parents of `qid` (not `qid`), so
        // `qid` is excluded from its own closure.
        var frontier: [String] = edges[qid] ?? []
        while let node = frontier.popLast() {
            if seen.contains(node) { continue }
            seen.insert(node)
            if let parents = edges[node] { frontier.append(contentsOf: parents) }
        }
        return seen.sorted(by: Self.qidLess)
    }

    /// Numeric ordering by the integer part of the Q-ID ("Q146" < "Q1084" <
    /// "Q25265"). Q-IDs are "Q" followed by digits; the integer parse is the
    /// canonical sort the pinned artifact and the Rust port both use. A Q-ID
    /// whose digits do not parse sorts as `0` (defensive; the pinned artifact
    /// never contains such a value).
    static func qidLess(_ a: String, _ b: String) -> Bool {
        let na = qidInt(a)
        let nb = qidInt(b)
        if na != nb { return na < nb }
        // Stable tie-break on the raw string (parse-failure collisions only).
        return a < b
    }

    /// The integer part of a Q-ID ("Q146" → 146). Returns 0 when the value has
    /// no parseable trailing integer (defensive; not present in the artifact).
    static func qidInt(_ qid: String) -> UInt64 {
        let digits = qid.drop(while: { !$0.isNumber })
        return UInt64(digits) ?? 0
    }

    // MARK: - artifact loading (once per process)

    /// The decoded edge graph: `{ "<qid>": [<direct parent qids>] }`. Decoded
    /// once per process from `Bundle.module`'s `QIDClosureEdges.json`.
    private struct GraphFile: Decodable {
        let edges: [String: [String]]
        let version: String
    }

    /// The decoded graph file, loaded once per process. Mirrors
    /// `FDCRuntime`'s `load(...)` via `Bundle.module`.
    private static let graphFile: GraphFile? = {
        guard let url = Bundle.module.url(forResource: "QIDClosureEdges", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GraphFile.self, from: data)
    }()

    /// The direct-edge adjacency map, or `nil` when the artifact is
    /// unavailable.
    private static var edges: [String: [String]]? { graphFile?.edges }

    /// Per-qid closure memo. `nonisolated(unsafe)` because all access is
    /// guarded by `memoLock` (the same idiom `WordClassTable` uses for its
    /// process-global live snapshot).
    nonisolated(unsafe) private static var memo: [String: [String]] = [:]
    nonisolated(unsafe) private static var memoLock = os_unfair_lock()
}
