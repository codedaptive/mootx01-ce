// EdgeFetcher.swift
//
// The edge-graph input to the assembler. The CC0 concept seed carries
// labels and bucketing hints but not the subclass/instance relations
// that the collapse rule needs to build a single-parent tree. Those
// relations are Wikidata properties P279 (subclass of) and P31
// (instance of). This file isolates the fetch behind a protocol so the
// network conformer is swappable for a fixture in tests and offline CI.
//
// The one-hop rule (the explosion bound): a fetch returns the
// P279/P31 edges of every seed concept, and admits each edge's parent
// even when the parent lies outside the seed. An out-of-seed parent is
// a routing node — it carries its child to the correct spine class
// through the collapse rule, but it is never itself emitted as a canon
// entry. The fetch does NOT recurse: a routing node's own parents are
// never fetched (no second hop, no transitive closure). The seed
// concepts are mostly leaves whose P279/P31 parents are broader
// concepts outside the seed; admitting those parents one hop out is
// what keeps the hierarchy connected (live measurement: ~42% of seed
// concepts have no in-seed parent), and the single-hop bound keeps the
// graph small — roughly +1.5 routing nodes per seed concept.

import Foundation
import os

/// Structured errors raised by LatticeLib's pipeline surface. Per the
/// project convention, errors are a typed enum rather than optionals
/// plus logging. v1 has a single case — the live edge fetch is the
/// only operation that can fail in a way the assembler machinery
/// (pure, total) cannot; file I/O in the writer propagates system
/// errors directly.
public enum MOOTx01Error: Error, Sendable, Equatable {
    /// The Wikidata Query Service returned a non-success HTTP status.
    case edgeFetchFailed(statusCode: Int)
}

/// A source of subclass/instance edges for a set of source identities.
/// Conformers apply the one-hop rule: every returned edge's child is a
/// member of `qids`; the parent may lie one hop outside `qids` (a
/// routing node). Conformers never recurse past that single hop.
public protocol EdgeSource: Sendable {
    /// Returns the P279/P31 edges whose child is in `qids`. The child of
    /// every returned edge is a member of `qids`; the parent may be a
    /// one-hop routing node outside `qids`.
    func edges(for qids: Set<String>) async throws -> [SourceEdge]
}

/// A fixture edge source for tests and offline CI. Holds a fixed edge
/// list and applies the same one-hop rule the network conformer
/// applies: edges whose child is in the seed are kept, and their
/// parents are admitted even when out of seed (routing nodes). An edge
/// whose child is NOT in the seed is dropped, so a fixture cannot
/// smuggle in a concept the seed never named as a child.
public struct FixtureEdgeSource: EdgeSource {
    private let fixture: [SourceEdge]

    public init(_ fixture: [SourceEdge]) {
        self.fixture = fixture
    }

    public func edges(for qids: Set<String>) async throws -> [SourceEdge] {
        fixture.filter { qids.contains($0.child) }
    }
}

/// The live Wikidata CC0 conformer. Queries the Wikidata Query Service
/// SPARQL endpoint for P279 and P31 edges restricted to the seed QID
/// set, batching the set so no single query is unbounded. All Wikidata
/// statement data is CC0 1.0; the access date and endpoint are recorded
/// by the caller in the build provenance.
public struct WikidataEdgeSource: EdgeSource {
    /// The public Wikidata Query Service SPARQL endpoint.
    public static let defaultEndpoint = URL(string: "https://query.wikidata.org/sparql")!

    private let endpoint: URL
    private let batchSize: Int
    private let session: URLSession
    private static let log = Logger(subsystem: "com.mootx01.kit", category: "LatticeLib")

    /// - Parameters:
    ///   - endpoint: the SPARQL endpoint (defaults to WDQS).
    ///   - batchSize: how many QIDs to bind per query. The default of
    ///     200 keeps each query well under the service's query-size and
    ///     timeout limits while minimising round-trips for a 2026-QID
    ///     seed.
    ///   - session: the URLSession used for requests; injectable for
    ///     testing the request shaping without hitting the network.
    public init(
        endpoint: URL = WikidataEdgeSource.defaultEndpoint,
        batchSize: Int = 200,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.batchSize = batchSize
        self.session = session
    }

    public func edges(for qids: Set<String>) async throws -> [SourceEdge] {
        // Sort the QID set so batching is deterministic across runs.
        let sorted = qids.sorted()
        var collected: [SourceEdge] = []
        var index = 0
        while index < sorted.count {
            let batch = Array(sorted[index..<min(index + batchSize, sorted.count)])
            let edges = try await fetchBatch(batch)
            collected.append(contentsOf: edges)
            index += batchSize
        }
        // Deduplicate and sort for determinism; the same seed produces
        // the same edge list regardless of batch boundaries.
        let unique = Set(collected).sorted { ($0.child, $0.parent) < ($1.child, $1.parent) }
        return unique
    }

    /// Fetches one batch. The query asks for any P279 or P31 edge whose
    /// child is in the batch. Every such edge is kept: the child is in
    /// the seed by construction, and the parent is admitted even when it
    /// lies outside the seed (a one-hop routing node). The single hop is
    /// the explosion bound — a routing node's own parents are never
    /// queried.
    private func fetchBatch(_ batch: [String]) async throws -> [SourceEdge] {
        let values = batch.map { "wd:\($0)" }.joined(separator: " ")
        // P279 = subclass of, P31 = instance of. Both feed the
        // single-parent collapse as candidate parents.
        let sparql = """
        SELECT ?child ?parent WHERE { \
        VALUES ?child { \(values) } \
        ?child (wdt:P279|wdt:P31) ?parent . \
        }
        """
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "query", value: sparql),
            URLQueryItem(name: "format", value: "json"),
        ]
        var request = URLRequest(url: components.url!)
        // WDQS requires a descriptive User-Agent and returns SPARQL JSON.
        request.setValue("LatticeLib-build/0.1 (https://github.com/mootx01; CC0 canon build)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/sparql-results+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            Self.log.error("WDQS batch failed, HTTP \(code, privacy: .public)")
            throw MOOTx01Error.edgeFetchFailed(statusCode: code)
        }

        let results = try JSONDecoder().decode(SPARQLResults.self, from: data)
        var edges: [SourceEdge] = []
        for binding in results.results.bindings {
            guard let child = binding.child?.entityID,
                  let parent = binding.parent?.entityID else { continue }
            // One hop: the child is in the batch (and the seed); the
            // parent is admitted whether or not it is in the seed. An
            // out-of-seed parent is a routing node, identified downstream
            // as an edge parent absent from the concept set.
            edges.append(SourceEdge(child: child, parent: parent))
        }
        return edges
    }
}

/// The fetch coordinator. Wraps any `EdgeSource` so callers depend on a
/// single entry point regardless of whether the source is the network
/// or a fixture. Kept as a thin seam: the executable builds it with a
/// `WikidataEdgeSource`, tests build it with a `FixtureEdgeSource`.
public struct EdgeFetcher: Sendable {
    private let source: EdgeSource

    public init(source: EdgeSource) {
        self.source = source
    }

    /// Fetches the subclass/instance edges whose child is in `qids` from
    /// the wrapped source. Parents may be one-hop routing nodes outside
    /// `qids`; the one-hop bound is the source's responsibility, and the
    /// fetcher does not relax it into a second hop.
    public func fetch(for qids: Set<String>) async throws -> [SourceEdge] {
        try await source.edges(for: qids)
    }
}

// MARK: - SPARQL response model

/// The subset of the SPARQL JSON results format the edge fetch reads.
private struct SPARQLResults: Decodable {
    let results: Results
    struct Results: Decodable {
        let bindings: [Binding]
    }
    struct Binding: Decodable {
        let child: Term?
        let parent: Term?
    }
    /// A bound term. For entity values the `value` is a full Wikidata
    /// entity URI; `entityID` extracts the trailing Q-ID.
    struct Term: Decodable {
        let value: String
        /// Extracts the Q-ID from a Wikidata entity URI such as
        /// `http://www.wikidata.org/entity/Q42`, or nil if the term is
        /// not an entity URI.
        var entityID: String? {
            guard let last = value.split(separator: "/").last else { return nil }
            let id = String(last)
            return id.hasPrefix("Q") ? id : nil
        }
    }
}
