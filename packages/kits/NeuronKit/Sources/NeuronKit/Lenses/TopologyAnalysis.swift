import CoreFoundation
import Foundation
import OSLog
import SubstrateML

// TopologyAnalysis — the estate topology snapshot (VIZ_V2). Surfaces
// SubstrateML's gated Louvain CommunityDetection and EigenvalueCentrality
// over a WEIGHTED graph assembled from drawer/tunnel/KGFact descriptors,
// then shapes the result for the /api/graph wire. Owns no math (I-17);
// pure and total — no estate I/O, no side effects beyond a perf log.
//
// Relocated from GeniusLocusKit (which had called SubstrateML directly,
// putting analysis in the composition layer). Analysis is NeuronKit's lane;
// callers (ARIA_MCP) perform the estate reads and tombstone-instant
// resolution, then hand plain descriptors to this function.
//
// Unlike Keystones/Constellation (unit-weight per SPEC § 7.1), topology
// assembles a weighted graph: tunnel 1.0 (explicit structural link),
// kgFact 0.3 (derived shared-subject bond — weaker evidence class),
// lattice 0.2 (derived classification bond — drawers sharing a non-empty
// udcCode bonded in a star from the earliest-filed member). The weights
// ride SubstrateML's existing weighted adjacency; nothing new descends to
// the substrate layer.

// Module-scoped logger. Fleet standard: subsystem "com.mootx01.kit",
// category = module name.
private let topologyLogger = Logger(subsystem: "com.mootx01.kit", category: "NeuronKit")

// MARK: - Input descriptors

/// One drawer, reduced to the fields topology analysis reads. The caller
/// resolves estate I/O — including the tombstone instant, which may require
/// an audit-trail read (see ARIA_MCP's graphSnapshot) — before constructing
/// descriptors, keeping this module free of store access (NeuronKit
/// boundary: no DrawerStore).
public struct TopologyDrawerInput: Sendable, Equatable {
    public let id: String
    /// Lattice address; "" = unanchored sentinel.
    public let udcCode: String
    /// Ingest clock — when the row entered the estate (alive(t) boundary).
    public let filedAt: Date
    /// Event time — when the thing happened in the world (recency signal).
    public let eventTime: Date
    /// True when the drawer is dead (state axis or stamp). Dead drawers are
    /// excluded from all math and appended with sentinel values.
    public let tombstoned: Bool
    /// The resolved tombstone instant; nil when alive, and possibly nil for
    /// a dead drawer whose instant could not be resolved (the node still
    /// carries the -1 sentinel in that case).
    public let tombstonedAt: Date?

    public init(id: String, udcCode: String, filedAt: Date, eventTime: Date,
                tombstoned: Bool, tombstonedAt: Date?) {
        self.id = id; self.udcCode = udcCode
        self.filedAt = filedAt; self.eventTime = eventTime
        self.tombstoned = tombstoned; self.tombstonedAt = tombstonedAt
    }
}

/// One tunnel, reduced to the fields topology analysis reads. Tunnels with
/// either endpoint absent contribute nothing to the graph.
public struct TopologyTunnelInput: Sendable, Equatable {
    public let sourceDrawerId: String?
    public let targetDrawerId: String?
    public let filedAt: Date
    /// nil = live. A dead tunnel appears as an edge with `tombstonedTs` set
    /// but never enters the community adjacency.
    public let tombstonedAt: Date?

    public init(sourceDrawerId: String?, targetDrawerId: String?,
                filedAt: Date, tombstonedAt: Date?) {
        self.sourceDrawerId = sourceDrawerId; self.targetDrawerId = targetDrawerId
        self.filedAt = filedAt; self.tombstonedAt = tombstonedAt
    }
}

/// One KGFact, reduced to the shared-subject bonding inputs.
public struct TopologyFactInput: Sendable, Equatable {
    public let subject: String
    public let sourceDrawerID: String

    public init(subject: String, sourceDrawerID: String) {
        self.subject = subject; self.sourceDrawerID = sourceDrawerID
    }
}

// MARK: - Output types

/// A node in the estate topology graph, enriched with Louvain community
/// assignment and eigenvalue centrality from the weighted structure graph.
public struct GraphTopologyNode: Sendable, Equatable, Codable {
    public let id: String
    /// Louvain community index — nodes in the same community share dense
    /// intra-community tunnels relative to inter-community connections.
    /// -1 = the "no community" sentinel carried by dead nodes.
    public let communityId: Int
    /// Eigenvalue centrality normalised to [0, 1]. Higher = more connected hub.
    public let centrality: Double
    public let lastActiveTs: String?
    /// ISO-8601 ingest timestamp — the drawer's `filedAt` (ingest clock), so
    /// playback clients can reconstruct the graph as it existed at time t.
    public let createdTs: String?
    /// ISO-8601 tombstone instant; nil = alive now. Dead nodes carry
    /// `communityId: -1` and `centrality: 0.0` and never participate in the
    /// community math — playback shows an entity within [createdTs, tombstonedTs).
    public let tombstonedTs: String?
    /// FDC/UDC classification code of the drawer this node represents (e.g. "657",
    /// "615.85"). Nil when the drawer is unanchored (empty-string udcCode from the
    /// input is normalized here to nil — empty strings never cross this boundary).
    /// Dead nodes (communityId == -1) retain their code: the field is informational
    /// and independent of the node's alive/dead state.
    public let udcCode: String?

    public init(id: String, communityId: Int, centrality: Double, lastActiveTs: String?,
                createdTs: String?, tombstonedTs: String?, udcCode: String? = nil) {
        self.id = id; self.communityId = communityId
        self.centrality = centrality; self.lastActiveTs = lastActiveTs
        self.createdTs = createdTs
        self.tombstonedTs = tombstonedTs
        self.udcCode = udcCode
    }
}

/// A directed edge in the estate topology graph.
/// edgeType "tunnel": explicit LocusKit Tunnel (sourceDrawerId → targetDrawerId).
/// edgeType "kgFact": implicit bond between drawers sharing a KGFact subject.
/// edgeType "lattice": derived classification bond — drawers sharing a non-empty
/// udcCode, star topology from the earliest-filedAt hub. Feeds Louvain only.
public struct GraphTopologyEdge: Sendable, Equatable, Codable {
    public let source: String
    public let target: String
    public let edgeType: String
    public let weight: Double
    /// ISO-8601 ingest timestamp. Tunnel edges carry the tunnel's `filedAt`;
    /// kgFact edges are nil — a derived bond aggregates facts filed at
    /// different instants, so there is no honest single ingest instant.
    public let createdTs: String?
    /// ISO-8601 tombstone instant; nil = alive now. Dead tunnel edges keep
    /// their real source/target but are excluded from the community adjacency.
    /// kgFact edges are derived from live facts only, so theirs is always nil.
    public let tombstonedTs: String?

    public init(source: String, target: String, edgeType: String, weight: Double, createdTs: String?, tombstonedTs: String?) {
        self.source = source; self.target = target
        self.edgeType = edgeType; self.weight = weight
        self.createdTs = createdTs
        self.tombstonedTs = tombstonedTs
    }
}

/// One detected Louvain community summarised for constellation labelling.
public struct GraphTopologyCommunity: Sendable, Equatable, Codable {
    /// The Louvain community label — matches member nodes' `communityId`.
    public let id: Int
    /// Number of live drawers assigned to this community.
    public let size: Int
    /// Most frequent non-empty `udcCode` among the community's member drawers.
    /// Frequency ties break lexicographically ascending for determinism;
    /// "" when every member drawer has an empty code.
    public let dominantUdcCode: String

    public init(id: Int, size: Int, dominantUdcCode: String) {
        self.id = id; self.size = size; self.dominantUdcCode = dominantUdcCode
    }
}

/// Full topology snapshot for one estate.
public struct GraphTopology: Sendable, Equatable, Codable {
    public let nodes: [GraphTopologyNode]
    public let edges: [GraphTopologyEdge]
    /// Number of distinct Louvain communities detected.
    public let communityCount: Int
    /// Per-community summaries, sorted by size descending then id ascending.
    public let communities: [GraphTopologyCommunity]

    public init(nodes: [GraphTopologyNode], edges: [GraphTopologyEdge], communityCount: Int, communities: [GraphTopologyCommunity]) {
        self.nodes = nodes; self.edges = edges; self.communityCount = communityCount
        self.communities = communities
    }
}

// MARK: - Analysis

extension NeuronKit {

    /// Louvain passes per level for the topology snapshot. Higher than the
    /// lens default (10) because the dashboard graph is read far less often
    /// than the lens surfaces and benefits from the extra convergence on
    /// larger estates. Preserved from the original GeniusLocusKit
    /// implementation so the relocation is behavior-identical.
    public static let topologyMaxPasses = 20

    /// Maximum phase-2 aggregation levels for full Louvain. Typical
    /// convergence is 2–4 levels; 10 is generous headroom that still bounds
    /// the worst case.
    public static let topologyMaxLevels = 10

    /// Louvain resolution (Reichardt-Bornholdt gamma) for the community
    /// lenses. Chosen from the scale-invariant absorption bound: a supernode
    /// with degree k and edge weight w into a target community merges
    /// whenever gamma < w/k. A tunnel-bonded pair (k = 2·1.0 + 0.2 = 2.2)
    /// with one lattice bond (w = 0.2) absorbs below 0.2/2.2 ≈ 0.0909;
    /// 0.05 sits at ~55 % of that bound with headroom for pair members
    /// carrying several distinct lattice bonds (bound stays above 0.05 up
    /// to ~8 bonds). Large continents joined by weak bridges have merge
    /// thresholds ≈ w_bridge/m — orders of magnitude smaller — so this
    /// gamma collapses tunnel-pair fragments into their lattice stars
    /// WITHOUT gluing real continents together. Value hand-derived from
    /// the Reichardt-Bornholdt gain formula: ΔQ(γ) = (k_{i,B}−k_{i,A})/m
    /// − γ·k_i·(σ_B−σ_A^excl+k_i)/(2m²), with γ=0.05 chosen so the
    /// penalty is small enough to absorb pair fragments while leaving the
    /// inter-continent bridge gain negative.
    public static let topologyResolution = 0.05

    /// Maximum number of drawers per KGFact subject group bonded into the
    /// shared-subject clique. Planned hardening: a subject shared by many
    /// drawers (generic label or data-quality issue) generates O(n²) adjacency
    /// edges; capping at kgFactCliqueCap limits one group to at most
    /// kgFactCliqueCap*(kgFactCliqueCap-1)/2 = 1 225 edges. Drawers beyond
    /// the cap are excluded from bonding for that subject — they still appear
    /// in the graph as isolated or tunnel-bonded nodes. Cap hit is logged once
    /// per group at warning level (no subject content — avoids leaking user data).
    /// Parity-aligned with KGFACT_CLIQUE_CAP in topology_analysis.rs.
    public static let kgFactCliqueCap = 50

    /// Compute the estate topology snapshot from plain descriptors.
    ///
    /// Live/dead partition comes from the descriptors (the caller resolves
    /// store state and tombstone instants). All math — adjacency, Louvain
    /// community detection, eigenvalue centrality, community aggregation —
    /// runs over LIVE entities only. Dead entities appear in the output
    /// (nodes with `communityId: -1`, `centrality: 0.0`; edges with
    /// `tombstonedTs` set) but never in the adjacency, so they cannot shift
    /// community structure.
    ///
    /// The graph is WEIGHTED: tunnel edges 1.0, kgFact shared-subject bonds
    /// 0.3, lattice bonds 0.2. Lattice bonding groups live drawers sharing a
    /// non-empty `udcCode` in a star topology — evidence hierarchy: tunnel
    /// (explicit) > kgFact (derived semantic) > lattice (derived classification).
    ///
    /// ADJACENCY SPLIT: eigenvalue centrality runs on the tunnel+kgFact
    /// adjacency only. Lattice edges feed the Louvain adjacency only —
    /// centrality means explicit structural prominence; lattice bonds are
    /// derived classification and must not mint keystones.
    ///
    /// Performance: CommunityDetection is O(E·passes), EigenvalueCentrality
    /// O(N log N). Elapsed time above 500ms logs a warning — the signal that
    /// an estate has outgrown compute-on-read and the scheduled-snapshot
    /// path should take over.
    /// - Parameters:
    ///   - estate: Estate UUID string for VizGraph telemetry. Threaded to
    ///             SubstrateML so analytics rows (community.assignment,
    ///             centrality.score) carry the correct estate tag rather than
    ///             the empty string that caused live-dashboard analytics to emit
    ///             with estate:"" and ts:0 before this fix.
    ///   - now: Caller-supplied timestamp for telemetry. Never read a clock
    ///          inside NeuronKit or SubstrateML; the caller provides `now`.
    public static func graphTopology(drawers: [TopologyDrawerInput],
                                     tunnels: [TopologyTunnelInput],
                                     facts: [TopologyFactInput],
                                     estate: String,
                                     now: Date) -> GraphTopology {
        // Live/dead partition. The descriptor's `tombstoned` flag is the
        // authoritative dead signal (the caller derives it from the state
        // axis and/or the stamp).
        let live = drawers.filter { !$0.tombstoned }
        let dead = drawers.filter { $0.tombstoned }
        let liveTunnels = tunnels.filter { $0.tombstonedAt == nil }
        let deadTunnels = tunnels.filter { $0.tombstonedAt != nil }

        // The math universe is LIVE drawers only: indexOf, adjacency, Louvain,
        // centrality, and communities aggregation all derive from `nodeIDs`.
        let nodeIDs = live.map { $0.id }
        var indexOf = [String: Int](minimumCapacity: nodeIDs.count)
        for (i, id) in nodeIDs.enumerated() { indexOf[id] = i }

        // Undirected WEIGHTED adjacency: [[(neighbor: Int, weight: Double)]].
        // Matches SubstrateML.CommunityDetection / EigenvalueCentrality input.
        var adjacency: [[(neighbor: Int, weight: Double)]] =
            Array(repeating: [], count: nodeIDs.count)

        // Tunnel edges: explicit drawer-to-drawer structural links (weight 1.0).
        for t in liveTunnels {
            guard let srcID = t.sourceDrawerId,
                  let tgtID = t.targetDrawerId,
                  let i = indexOf[srcID],
                  let j = indexOf[tgtID],
                  i != j else { continue }
            adjacency[i].append((neighbor: j, weight: 1.0))
            adjacency[j].append((neighbor: i, weight: 1.0))
        }

        // KGFact edges: group facts by subject; drawers sharing ≥1 identical
        // subject are weakly connected (weight 0.3). O(F) where F = fact count.
        var subjectIndex: [String: [String]] = [:]
        for fact in facts {
            subjectIndex[fact.subject, default: []].append(fact.sourceDrawerID)
        }
        var kgEdges: [GraphTopologyEdge] = []
        for (_, drawerIDs) in subjectIndex where drawerIDs.count > 1 {
            // Sort for determinism (Set iteration order is insertion-dependent
            // in Swift; sorted() aligns with the Rust port's sort_unstable so
            // both ports build the same edge multiset from the same facts).
            var unique = Array(Set(drawerIDs)).sorted()
            // Planned hardening: cap group size to prevent O(n²) edge
            // explosion. Drawers beyond kgFactCliqueCap receive no bond for
            // this subject. Parity: mirrors KGFACT_CLIQUE_CAP in topology_analysis.rs.
            if unique.count > NeuronKit.kgFactCliqueCap {
                topologyLogger.warning(
                    "NeuronKit.graphTopology: KGFact group has \(unique.count) drawers; capping at \(NeuronKit.kgFactCliqueCap) (planned hardening)")
                unique = Array(unique.prefix(NeuronKit.kgFactCliqueCap))
            }
            for i in 0..<unique.count {
                for j in (i + 1)..<unique.count {
                    // createdTs is nil: a shared-subject bond aggregates facts
                    // filed at different instants — no single ingest instant.
                    kgEdges.append(GraphTopologyEdge(
                        source: unique[i], target: unique[j],
                        edgeType: "kgFact", weight: 0.3, createdTs: nil,
                        tombstonedTs: nil))
                    if let ni = indexOf[unique[i]], let nj = indexOf[unique[j]], ni != nj {
                        adjacency[ni].append((neighbor: nj, weight: 0.3))
                        adjacency[nj].append((neighbor: ni, weight: 0.3))
                    }
                }
            }
        }

        // Lattice edges: group live drawers by non-empty udcCode; for each group ≥2,
        // star-bond from the hub (earliest filedAt; id ascending on tie — deterministic
        // regardless of input permutation). Weight 0.2 — evidence hierarchy:
        // tunnel 1.0 (explicit) > kgFact 0.3 (derived semantic) > lattice 0.2
        // (derived classification).
        var latticeEdges: [GraphTopologyEdge] = []
        var codeGroups: [String: [TopologyDrawerInput]] = [:]
        for d in live where !d.udcCode.isEmpty {
            codeGroups[d.udcCode, default: []].append(d)
        }
        for (_, group) in codeGroups where group.count > 1 {
            // Hub = earliest filedAt; ties broken by id ascending (deterministic
            // across permuted input orders — same snapshot on every call).
            let hub = group.min { a, b in
                if a.filedAt != b.filedAt { return a.filedAt < b.filedAt }
                return a.id < b.id
            }!
            for member in group where member.id != hub.id {
                // createdTs nil: derived bond, no single ingest instant (mirrors kgFact).
                // tombstonedTs nil: derived from live drawers only.
                latticeEdges.append(GraphTopologyEdge(
                    source: hub.id, target: member.id,
                    edgeType: "lattice", weight: 0.2,
                    createdTs: nil, tombstonedTs: nil))
            }
        }

        // ADJACENCY SPLIT — centrality is computed BEFORE lattice edges are
        // appended to the adjacency. A lattice star hub would otherwise become
        // the estate's top keystone by topology artifact alone.
        // "centrality means explicit structural prominence; lattice bonds are
        // derived classification and must not mint keystones."
        // Louvain adjacency receives all three classes: tunnel + kgFact + lattice.
        let startT = CFAbsoluteTimeGetCurrent()
        // Thread estate and ts from the caller so analytics rows carry the
        // correct estate identifier and timestamp.
        let centralities = SubstrateML.EigenvalueCentrality.compute(
            adjacency: adjacency,
            estate: estate,
            ts: now.timeIntervalSince1970)

        // Append lattice edges to the Louvain adjacency only (after centrality).
        for edge in latticeEdges {
            if let i = indexOf[edge.source], let j = indexOf[edge.target], i != j {
                adjacency[i].append((neighbor: j, weight: 0.2))
                adjacency[j].append((neighbor: i, weight: 0.2))
            }
        }
        // Full Louvain (phase 1 + aggregation) at the lens resolution:
        // phase-1 alone locks tunnel-bonded pairs out of their lattice
        // stars (the §7.3 pair-locking limitation), fragmenting the
        // dashboard continents.
        // Thread estate and ts from the caller so the community.assignment
        // analytics row carries the correct estate identifier and timestamp.
        let labels = SubstrateML.CommunityDetection.detectFull(
            adjacency: adjacency, maxLevels: topologyMaxLevels,
            maxPasses: topologyMaxPasses, resolution: topologyResolution,
            estate: estate, ts: now.timeIntervalSince1970)
        let elapsed = CFAbsoluteTimeGetCurrent() - startT
        if elapsed > 0.5 {
            topologyLogger.info(
                "graphTopology took \(elapsed, format: .fixed(precision: 2))s for \(nodeIDs.count) nodes — consider the scheduled-snapshot path")
        }

        // Map integer labels back to drawer IDs.
        var communityMap: [String: Int] = [:]
        for (i, label) in labels.enumerated() where i < nodeIDs.count {
            communityMap[nodeIDs[i]] = label
        }

        // Normalize centrality to [0, 1] against the max value.
        let maxC = centralities.max() ?? 1.0
        let norm = maxC > 0 ? maxC : 1.0
        var centralityMap: [String: Double] = [:]
        for (i, c) in centralities.enumerated() where i < nodeIDs.count {
            centralityMap[nodeIDs[i]] = c / norm
        }

        // ISO8601DateFormatter per call is intentional: this is called at
        // low frequency (graph requests and scheduled topology snapshots);
        // the allocation is negligible.
        let iso = ISO8601DateFormatter()
        var nodes = live.map { d in
            GraphTopologyNode(
                id: d.id,
                communityId: communityMap[d.id] ?? 0,
                centrality: centralityMap[d.id] ?? 0.0,
                lastActiveTs: iso.string(from: d.eventTime),
                // Ingest clock, not event semantics: filedAt is when the drawer
                // entered the estate, which is the alive(t) playback boundary.
                createdTs: iso.string(from: d.filedAt),
                tombstonedTs: nil,
                // Empty-string udcCode ("" = unanchored sentinel) normalizes to nil
                // here so downstream consumers never receive an empty classification.
                udcCode: d.udcCode.isEmpty ? nil : d.udcCode
            )
        }

        // Dead drawers are APPENDED after the live nodes: communityId -1 is
        // the "no community" sentinel and centrality 0.0 reflects that dead
        // entities carry no structural prominence. tombstonedTs may be nil
        // when the caller could not resolve the instant; the -1 sentinel
        // still marks the node dead. udcCode is retained for dead nodes —
        // it is informational and independent of the alive/dead state.
        for d in dead {
            nodes.append(GraphTopologyNode(
                id: d.id,
                communityId: -1,
                centrality: 0.0,
                lastActiveTs: iso.string(from: d.eventTime),
                createdTs: iso.string(from: d.filedAt),
                tombstonedTs: d.tombstonedAt.map { iso.string(from: $0) },
                udcCode: d.udcCode.isEmpty ? nil : d.udcCode
            ))
        }

        let tunnelEdges: [GraphTopologyEdge] = liveTunnels.compactMap { t in
            guard let src = t.sourceDrawerId, let tgt = t.targetDrawerId else { return nil }
            return GraphTopologyEdge(
                source: src, target: tgt, edgeType: "tunnel", weight: 1.0,
                createdTs: iso.string(from: t.filedAt), tombstonedTs: nil)
        }
        // Dead tunnels are appended as edges with their real endpoints and the
        // tombstone instant; they were excluded from the adjacency above.
        let deadTunnelEdges: [GraphTopologyEdge] = deadTunnels.compactMap { t in
            guard let src = t.sourceDrawerId, let tgt = t.targetDrawerId else { return nil }
            return GraphTopologyEdge(
                source: src, target: tgt, edgeType: "tunnel", weight: 1.0,
                createdTs: iso.string(from: t.filedAt),
                tombstonedTs: t.tombstonedAt.map { iso.string(from: $0) })
        }

        // Count distinct community labels to report the discovered partition.
        let communityCount = Set(labels).count

        // Per-community summaries for constellation labelling: group live
        // drawers by their Louvain label, then pick the dominant UDC code.
        var membersByCommunity: [Int: [TopologyDrawerInput]] = [:]
        for d in live {
            membersByCommunity[communityMap[d.id] ?? 0, default: []].append(d)
        }
        let communities: [GraphTopologyCommunity] = membersByCommunity.map { (id, members) in
            // Most frequent non-empty udcCode among member drawers. Frequency
            // ties break lexicographically ascending so repeated snapshots of
            // an unchanged estate agree byte-for-byte. "" when all codes empty.
            var counts: [String: Int] = [:]
            for m in members where !m.udcCode.isEmpty {
                counts[m.udcCode, default: 0] += 1
            }
            let dominant = counts.max { a, b in
                a.value != b.value ? a.value < b.value : a.key > b.key
            }?.key ?? ""
            return GraphTopologyCommunity(id: id, size: members.count, dominantUdcCode: dominant)
        }.sorted { a, b in
            a.size != b.size ? a.size > b.size : a.id < b.id
        }

        return GraphTopology(
            nodes: nodes,
            edges: tunnelEdges + kgEdges + latticeEdges + deadTunnelEdges,
            communityCount: communityCount,
            communities: communities
        )
    }
}
