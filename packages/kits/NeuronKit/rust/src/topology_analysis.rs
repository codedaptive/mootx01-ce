//! TopologyAnalysis — the estate topology snapshot (VIZ_V2). Surfaces
//! SubstrateML's gated Louvain `CommunityDetection` and `EigenvalueCentrality`
//! over a WEIGHTED graph assembled from drawer/tunnel/KGFact descriptors,
//! then shapes the result for the /api/graph wire. Owns no math (I-17);
//! pure and total (I-18) — no store access, no clocks.
//!
//! Peer of the Swift `NeuronKit.graphTopology(drawers:tunnels:facts:)` in
//! `Lenses/TopologyAnalysis.swift` — relocated from the composition layer
//! (Swift GLK / the Rust ARIA handler's inline assembly) because analysis is
//! NeuronKit's lane. Callers perform the estate reads and hand plain
//! descriptors here.
//!
//! Unlike Keystones/Constellation (unit-weight per SPEC § 7.1), topology
//! assembles a weighted graph: tunnel 1.0 (explicit structural link),
//! kgFact 0.3 (derived shared-subject bond — weaker evidence class),
//! lattice 0.2 (derived classification bond — drawers sharing a non-empty
//! udc_code bonded in a star from the earliest-filed member). The weights
//! ride SubstrateML's existing weighted adjacency; nothing new descends to
//! the substrate layer.

use std::collections::{BTreeMap, HashMap};

use substrate_ml::community_detection::CommunityDetection;
use substrate_ml::eigenvalue_centrality::EigenvalueCentrality;

/// Louvain passes per level for the topology snapshot. Higher than the lens
/// default (10) because the dashboard graph is read far less often than the
/// lens surfaces and benefits from the extra convergence on larger estates.
/// Mirrors Swift `NeuronKit.topologyMaxPasses`.
pub const TOPOLOGY_MAX_PASSES: usize = 20;

/// Maximum phase-2 aggregation levels for full Louvain. Typical convergence
/// is 2-4 levels; 10 is generous headroom that still bounds the worst case.
/// Mirrors Swift `NeuronKit.topologyMaxLevels`.
pub const TOPOLOGY_MAX_LEVELS: usize = 10;

/// Louvain resolution (Reichardt-Bornholdt gamma) for the community lenses.
/// Chosen from the scale-invariant absorption bound: a supernode with degree
/// k and edge weight w into a target community merges whenever gamma < w/k.
/// A tunnel-bonded pair (k = 2*1.0 + 0.2 = 2.2) with one lattice bond
/// (w = 0.2) absorbs below 0.2/2.2 ~= 0.0909; 0.05 sits at ~55 % of that
/// bound with headroom for pair members carrying several distinct lattice
/// bonds (bound stays above 0.05 up to ~8 bonds). Large continents joined by
/// weak bridges have merge thresholds ~= w_bridge/m — orders of magnitude
/// smaller — so this gamma collapses tunnel-pair fragments into their
/// lattice stars WITHOUT gluing real continents together. Value hand-derived
/// from the Reichardt-Bornholdt gain formula: ΔQ(γ) = (k_{i,B}−k_{i,A})/m
/// − γ·k_i·(σ_B−σ_A^excl+k_i)/(2m²), with γ=0.05 chosen so the penalty is
/// small enough to absorb pair fragments while leaving the inter-continent
/// bridge gain negative. Mirrors Swift `NeuronKit.topologyResolution`.
pub const TOPOLOGY_RESOLUTION: f64 = 0.05;

/// Maximum number of drawers per KGFact subject group bonded into the
/// shared-subject clique. Planned hardening: a subject shared by many drawers
/// (generic label or data-quality issue) generates O(n²) adjacency edges;
/// capping at KGFACT_CLIQUE_CAP limits one group to at most
/// KGFACT_CLIQUE_CAP*(KGFACT_CLIQUE_CAP-1)/2 = 1 225 edges. Drawers beyond
/// the cap are excluded from bonding for that subject — they still appear in
/// the graph as isolated or tunnel-bonded nodes. Cap hit is printed once per
/// group (no subject content — avoids logging user data).
/// Parity-aligned with `NeuronKit.kgFactCliqueCap` in TopologyAnalysis.swift.
pub const KGFACT_CLIQUE_CAP: usize = 50;

// MARK: input descriptors

/// One drawer, reduced to the fields topology analysis reads. The caller
/// resolves store state (including the tombstone instant) before
/// constructing descriptors — this module never touches a store.
#[derive(Clone, Debug, PartialEq)]
pub struct TopologyDrawerInput {
    pub id: String,
    /// Lattice address; "" = unanchored sentinel.
    pub udc_code: String,
    /// Ingest clock, epoch seconds — the alive(t) playback boundary.
    pub filed_at: i64,
    /// Event time, epoch seconds — the recency signal.
    pub event_time: i64,
    /// True when the drawer is dead. Dead drawers are excluded from all
    /// math and appended with sentinel values.
    pub tombstoned: bool,
    /// The resolved tombstone instant; None when alive, and possibly None
    /// for a dead drawer whose instant could not be resolved (the node
    /// still carries the -1 sentinel in that case).
    pub tombstoned_at: Option<i64>,
}

/// One tunnel, reduced to the fields topology analysis reads. Tunnels with
/// either endpoint absent contribute nothing to the graph.
#[derive(Clone, Debug, PartialEq)]
pub struct TopologyTunnelInput {
    pub source_drawer_id: Option<String>,
    pub target_drawer_id: Option<String>,
    pub filed_at: i64,
    /// None = live. A dead tunnel appears as an edge with `tombstonedTs`
    /// set but never enters the community adjacency.
    pub tombstoned_at: Option<i64>,
}

/// One KGFact, reduced to the shared-subject bonding inputs.
#[derive(Clone, Debug, PartialEq)]
pub struct TopologyFactInput {
    pub subject: String,
    pub source_drawer_id: String,
}

// MARK: output types

/// A node in the estate topology graph. `community_id: -1` is the
/// "no community" sentinel carried by dead nodes.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphTopologyNode {
    pub id: String,
    pub community_id: i64,
    /// Eigenvalue centrality normalised to [0, 1].
    pub centrality: f64,
    /// ISO-8601 event time (recency signal).
    pub last_active_ts: Option<String>,
    /// ISO-8601 ingest timestamp (`filed_at`) — the alive(t) boundary.
    pub created_ts: Option<String>,
    /// ISO-8601 tombstone instant; None = alive now (or unresolved for a
    /// dead node, which the -1 sentinel still marks dead).
    pub tombstoned_ts: Option<String>,
}

/// An edge in the estate topology graph. edge_type "tunnel" = explicit
/// LocusKit tunnel; "kgFact" = derived shared-subject bond (created_ts and
/// tombstoned_ts always None — no single ingest instant, live facts only);
/// "lattice" = derived classification bond (star from earliest-filedAt hub,
/// weight 0.2, all timestamps None — feeds Louvain adjacency only).
#[derive(Clone, Debug, PartialEq)]
pub struct GraphTopologyEdge {
    pub source: String,
    pub target: String,
    pub edge_type: &'static str,
    pub weight: f64,
    pub created_ts: Option<String>,
    pub tombstoned_ts: Option<String>,
}

/// One detected Louvain community summarised for constellation labelling.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphTopologyCommunity {
    /// The Louvain community label — matches member nodes' `community_id`.
    pub id: i64,
    /// Number of live drawers assigned to this community.
    pub size: usize,
    /// Most frequent non-empty `udc_code` among members; frequency ties
    /// break lexicographically ascending; "" when every code is empty.
    pub dominant_udc_code: String,
}

/// Full topology snapshot for one estate.
#[derive(Clone, Debug, PartialEq)]
pub struct GraphTopology {
    pub nodes: Vec<GraphTopologyNode>,
    pub edges: Vec<GraphTopologyEdge>,
    /// Number of distinct Louvain communities detected.
    pub community_count: usize,
    /// Per-community summaries, sorted by size descending then id ascending.
    pub communities: Vec<GraphTopologyCommunity>,
}

// MARK: epoch → ISO-8601

/// Format epoch MILLISECONDS (ADR-023) as "YYYY-MM-DDTHH:MM:SSZ" (UTC, second
/// precision — topology timestamps are display values). Hand-rolled
/// civil-from-days (Howard Hinnant's algorithm) — no chrono, per the
/// no-external-deps constraint. 400-year leap cycles are exact; negative
/// (pre-1970) values split via Euclidean division so the time-of-day components
/// are always in range. Relocated from the ARIA Rust handler — the formatter
/// belongs with the analysis whose output it shapes.
pub fn epoch_to_iso8601(epoch_ms: i64) -> String {
    // The civil-from-days math is seconds-based; reduce ms → seconds here.
    let secs = epoch_ms.div_euclid(1000);
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    let (hh, mm, ss) = (rem / 3600, (rem % 3600) / 60, rem % 60);

    // Civil-from-days: shift epoch to 0000-03-01-based eras of 146,097 days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };

    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}Z")
}

// MARK: analysis

/// Compute the estate topology snapshot from plain descriptors.
///
/// Live/dead partition comes from the descriptors. All math — adjacency,
/// Louvain, centrality, community aggregation — runs over LIVE entities
/// only. Dead entities appear in the output (nodes with `community_id: -1`,
/// `centrality: 0.0`; edges with `tombstoned_ts` set) but never in the
/// adjacency, so they cannot shift community structure.
///
/// The graph is WEIGHTED: tunnel edges 1.0, kgFact shared-subject bonds 0.3,
/// lattice bonds 0.2. Lattice bonding groups live drawers sharing a non-empty
/// `udc_code` in a star topology.
///
/// ADJACENCY SPLIT: EigenvalueCentrality runs on the tunnel+kgFact adjacency
/// only. Lattice edges are appended to the Louvain adjacency after centrality
/// to prevent lattice star hubs from minting topology-artifact keystones.
/// Mirrors the Swift implementation field-for-field.
/// `estate` and `ts` thread into SubstrateML so VizGraph telemetry rows carry
/// the correct estate tag and timestamp. Callers must inject the timestamp —
/// never read a clock inside NeuronKit or SubstrateML.
pub fn graph_topology(
    drawers: &[TopologyDrawerInput],
    tunnels: &[TopologyTunnelInput],
    facts: &[TopologyFactInput],
    estate: &str,
    ts: f64,
) -> GraphTopology {
    let live: Vec<&TopologyDrawerInput> = drawers.iter().filter(|d| !d.tombstoned).collect();
    let dead: Vec<&TopologyDrawerInput> = drawers.iter().filter(|d| d.tombstoned).collect();
    let live_tunnels: Vec<&TopologyTunnelInput> =
        tunnels.iter().filter(|t| t.tombstoned_at.is_none()).collect();
    let dead_tunnels: Vec<&TopologyTunnelInput> =
        tunnels.iter().filter(|t| t.tombstoned_at.is_some()).collect();

    // The math universe is LIVE drawers only.
    let node_ids: Vec<&str> = live.iter().map(|d| d.id.as_str()).collect();
    let index_of: HashMap<&str, usize> =
        node_ids.iter().enumerate().map(|(i, s)| (*s, i)).collect();

    // Undirected WEIGHTED adjacency — SubstrateML's input shape.
    let mut adjacency: Vec<Vec<(usize, f64)>> = vec![Vec::new(); node_ids.len()];

    // Tunnel edges: explicit drawer-to-drawer structural links (weight 1.0).
    for t in &live_tunnels {
        let (Some(src), Some(tgt)) = (&t.source_drawer_id, &t.target_drawer_id) else { continue };
        let (Some(&i), Some(&j)) = (index_of.get(src.as_str()), index_of.get(tgt.as_str())) else { continue };
        if i == j { continue }
        adjacency[i].push((j, 1.0));
        adjacency[j].push((i, 1.0));
    }

    // KGFact edges: group facts by subject; drawers sharing ≥1 identical
    // subject are weakly connected (weight 0.3). BTreeMap keeps subject
    // iteration deterministic.
    let mut subject_index: BTreeMap<&str, Vec<&str>> = BTreeMap::new();
    for f in facts {
        subject_index.entry(f.subject.as_str()).or_default().push(f.source_drawer_id.as_str());
    }
    let mut kg_edges: Vec<GraphTopologyEdge> = Vec::new();
    for (_, drawer_ids) in subject_index.iter().filter(|(_, v)| v.len() > 1) {
        // Dedup while preserving deterministic order.
        let mut unique: Vec<&str> = drawer_ids.clone();
        unique.sort_unstable();
        unique.dedup();
        // Planned hardening: cap group size to prevent O(n²) edge explosion
        // on pathological inputs (generic subject shared by many drawers).
        // Drawers beyond KGFACT_CLIQUE_CAP receive no bond for this subject.
        // Parity: mirrors NeuronKit.kgFactCliqueCap in TopologyAnalysis.swift.
        if unique.len() > KGFACT_CLIQUE_CAP {
            eprintln!(
                "NeuronKit.graph_topology: KGFact group has {} drawers; capping at {} (planned hardening)",
                unique.len(), KGFACT_CLIQUE_CAP
            );
            unique.truncate(KGFACT_CLIQUE_CAP);
        }
        for i in 0..unique.len() {
            for j in (i + 1)..unique.len() {
                // created_ts is None: a shared-subject bond aggregates facts
                // filed at different instants — no single ingest instant.
                kg_edges.push(GraphTopologyEdge {
                    source: unique[i].to_string(),
                    target: unique[j].to_string(),
                    edge_type: "kgFact",
                    weight: 0.3,
                    created_ts: None,
                    tombstoned_ts: None,
                });
                if let (Some(&ni), Some(&nj)) = (index_of.get(unique[i]), index_of.get(unique[j])) {
                    if ni != nj {
                        adjacency[ni].push((nj, 0.3));
                        adjacency[nj].push((ni, 0.3));
                    }
                }
            }
        }
    }

    // Lattice edges: group live drawers by non-empty udc_code; for each group ≥2,
    // star-bond from the hub (earliest filed_at; id ascending on tie — deterministic
    // regardless of input permutation). Weight 0.2 — evidence hierarchy:
    // tunnel 1.0 (explicit) > kgFact 0.3 (derived semantic) > lattice 0.2
    // (derived classification).
    let mut lattice_edges: Vec<GraphTopologyEdge> = Vec::new();
    let mut code_groups: BTreeMap<&str, Vec<&TopologyDrawerInput>> = BTreeMap::new();
    for d in &live {
        if !d.udc_code.is_empty() {
            code_groups.entry(d.udc_code.as_str()).or_default().push(d);
        }
    }
    for (_, group) in code_groups.iter().filter(|(_, v)| v.len() > 1) {
        // Hub = earliest filed_at; ties broken by id ascending (deterministic
        // across permuted input orders — same snapshot on every call).
        let hub = group.iter()
            .min_by(|a, b| a.filed_at.cmp(&b.filed_at).then(a.id.cmp(&b.id)))
            .unwrap();
        for member in group.iter().filter(|m| m.id != hub.id) {
            // created_ts: None — derived bond, no single ingest instant (mirrors kgFact).
            // tombstoned_ts: None — derived from live drawers only.
            lattice_edges.push(GraphTopologyEdge {
                source: hub.id.clone(),
                target: member.id.clone(),
                edge_type: "lattice",
                weight: 0.2,
                created_ts: None,
                tombstoned_ts: None,
            });
        }
    }

    // ADJACENCY SPLIT — centrality is computed BEFORE lattice edges are
    // appended to the adjacency. A lattice star hub would otherwise become
    // the estate's top keystone by topology artifact alone.
    // "centrality means explicit structural prominence; lattice bonds are
    // derived classification and must not mint keystones."
    // Louvain adjacency receives all three classes: tunnel + kgFact + lattice.
    //
    // Thread estate and ts so VizGraph telemetry carries the correct estate
    // identifier and timestamp — not empty/0 defaults.
    let centralities = EigenvalueCentrality::compute(
        &adjacency,
        EigenvalueCentrality::DEFAULT_MAX_ITERATIONS,
        EigenvalueCentrality::DEFAULT_TOLERANCE,
        estate,
        ts,
    );

    // Append lattice edges to the Louvain adjacency only (after centrality).
    for edge in &lattice_edges {
        if let (Some(&ni), Some(&nj)) = (index_of.get(edge.source.as_str()), index_of.get(edge.target.as_str())) {
            if ni != nj {
                adjacency[ni].push((nj, 0.2));
                adjacency[nj].push((ni, 0.2));
            }
        }
    }
    // Full Louvain (phase 1 + aggregation) at the lens resolution:
    // phase-1 alone locks tunnel-bonded pairs out of their lattice stars
    // (the section-7.3 pair-locking limitation), fragmenting the dashboard
    // continents.
    let labels = CommunityDetection::detect_full(
        &adjacency, TOPOLOGY_MAX_LEVELS, TOPOLOGY_MAX_PASSES,
        TOPOLOGY_RESOLUTION, estate, ts);

    // Normalize centrality to [0, 1] against the max value.
    let max_c = centralities.iter().cloned().fold(0.0_f64, f64::max);
    let norm = if max_c > 0.0 { max_c } else { 1.0 };

    let mut nodes: Vec<GraphTopologyNode> = live.iter().enumerate()
        .map(|(i, d)| GraphTopologyNode {
            id: d.id.clone(),
            community_id: labels.get(i).map(|&l| l as i64).unwrap_or(0),
            centrality: centralities.get(i).map(|c| c / norm).unwrap_or(0.0),
            last_active_ts: Some(epoch_to_iso8601(d.event_time)),
            // Ingest clock, not event semantics: filed_at is when the drawer
            // entered the estate — the alive(t) playback boundary.
            created_ts: Some(epoch_to_iso8601(d.filed_at)),
            tombstoned_ts: None,
        })
        .collect();

    // Dead drawers APPENDED after the live nodes: community_id -1 is the
    // "no community" sentinel; centrality 0.0 — dead entities carry no
    // structural prominence.
    nodes.extend(dead.iter().map(|d| GraphTopologyNode {
        id: d.id.clone(),
        community_id: -1,
        centrality: 0.0,
        last_active_ts: Some(epoch_to_iso8601(d.event_time)),
        created_ts: Some(epoch_to_iso8601(d.filed_at)),
        tombstoned_ts: d.tombstoned_at.map(epoch_to_iso8601),
    }));

    let tunnel_edge = |t: &TopologyTunnelInput| -> Option<GraphTopologyEdge> {
        let src = t.source_drawer_id.as_ref()?;
        let tgt = t.target_drawer_id.as_ref()?;
        Some(GraphTopologyEdge {
            source: src.clone(),
            target: tgt.clone(),
            edge_type: "tunnel",
            weight: 1.0,
            created_ts: Some(epoch_to_iso8601(t.filed_at)),
            tombstoned_ts: t.tombstoned_at.map(epoch_to_iso8601),
        })
    };
    let mut edges: Vec<GraphTopologyEdge> =
        live_tunnels.iter().filter_map(|t| tunnel_edge(t)).collect();
    edges.extend(kg_edges);
    edges.extend(lattice_edges);
    // Dead tunnels appended last with the tombstone instant; they were
    // excluded from the adjacency above. Order mirrors Swift:
    // tunnels + kgFacts + lattice + dead tunnels.
    edges.extend(dead_tunnels.iter().filter_map(|t| tunnel_edge(t)));

    // Count distinct community labels to report the discovered partition.
    let mut distinct: Vec<usize> = labels.clone();
    distinct.sort_unstable();
    distinct.dedup();
    let community_count = distinct.len();

    // Per-community summaries: group live drawers by Louvain label, then
    // pick the dominant UDC code. BTreeMap keeps ids ordered so the final
    // sort's id-ascending tie-break is stable.
    let mut members_by_community: BTreeMap<i64, Vec<&TopologyDrawerInput>> = BTreeMap::new();
    for (i, d) in live.iter().enumerate() {
        let label = labels.get(i).map(|&l| l as i64).unwrap_or(0);
        members_by_community.entry(label).or_default().push(d);
    }
    let mut communities: Vec<GraphTopologyCommunity> = members_by_community.iter()
        .map(|(id, members)| {
            // Most frequent non-empty udc_code; frequency ties break
            // lexicographically ascending; "" when all codes are empty.
            let mut counts: HashMap<&str, usize> = HashMap::new();
            for m in members {
                if !m.udc_code.is_empty() {
                    *counts.entry(m.udc_code.as_str()).or_insert(0) += 1;
                }
            }
            let dominant = counts.iter()
                // On equal counts the lexicographically smaller code compares
                // greater here, so max_by selects it.
                .max_by(|a, b| a.1.cmp(b.1).then(b.0.cmp(a.0)))
                .map(|(code, _)| (*code).to_string())
                .unwrap_or_default();
            GraphTopologyCommunity { id: *id, size: members.len(), dominant_udc_code: dominant }
        })
        .collect();
    communities.sort_by(|a, b| b.size.cmp(&a.size).then(a.id.cmp(&b.id)));

    GraphTopology { nodes, edges, community_count, communities }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: i64 = 1_700_000_000;

    fn drawer(id: &str, udc: &str) -> TopologyDrawerInput {
        TopologyDrawerInput {
            id: id.to_string(), udc_code: udc.to_string(),
            filed_at: T0, event_time: T0, tombstoned: false, tombstoned_at: None,
        }
    }

    fn dead_drawer(id: &str, at: Option<i64>) -> TopologyDrawerInput {
        TopologyDrawerInput {
            id: id.to_string(), udc_code: String::new(),
            filed_at: T0, event_time: T0, tombstoned: true, tombstoned_at: at,
        }
    }

    fn tunnel(src: &str, tgt: &str) -> TopologyTunnelInput {
        TopologyTunnelInput {
            source_drawer_id: Some(src.to_string()),
            target_drawer_id: Some(tgt.to_string()),
            filed_at: T0, tombstoned_at: None,
        }
    }

    fn dead_tunnel(src: &str, tgt: &str, at: i64) -> TopologyTunnelInput {
        TopologyTunnelInput {
            source_drawer_id: Some(src.to_string()),
            target_drawer_id: Some(tgt.to_string()),
            filed_at: T0, tombstoned_at: Some(at),
        }
    }

    /// Three drawers tunnel-linked into a triangle. Phase-1 Louvain cannot
    /// merge an isolated pair (modularity gain 0), and even a lone triangle
    /// needs a bridge for positive gain — fixtures use the bridged pair.
    fn triangle(tag: &str, udcs: [&str; 3]) -> (Vec<TopologyDrawerInput>, Vec<TopologyTunnelInput>, Vec<String>) {
        let ids: Vec<String> = (0..3).map(|i| format!("{tag}-{i}")).collect();
        let drawers = ids.iter().zip(udcs).map(|(id, u)| drawer(id, u)).collect();
        let tunnels = vec![
            tunnel(&ids[0], &ids[1]), tunnel(&ids[0], &ids[2]), tunnel(&ids[1], &ids[2]),
        ];
        (drawers, tunnels, ids)
    }

    // Known vectors for the civil-from-days formatter, including pre-1970
    // Euclidean splits, century non-leap (1900) and 400-year leap (2000).
    #[test]
    fn epoch_to_iso8601_known_vectors() {
        // Inputs are epoch MILLISECONDS (ADR-023); ×1000 the seconds vectors.
        assert_eq!(epoch_to_iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(epoch_to_iso8601(86_399_000), "1970-01-01T23:59:59Z");
        assert_eq!(epoch_to_iso8601(951_782_400_000), "2000-02-29T00:00:00Z");
        assert_eq!(epoch_to_iso8601(1_717_200_000_000), "2024-06-01T00:00:00Z");
        assert_eq!(epoch_to_iso8601(-1_000), "1969-12-31T23:59:59Z");
        assert_eq!(epoch_to_iso8601(-2_208_988_800_000), "1900-01-01T00:00:00Z");
    }

    #[test]
    fn nodes_carry_created_ts_from_filed_at() {
        let topo = graph_topology(&[drawer("a", "510")], &[], &[], "", 0.0);
        assert_eq!(topo.nodes[0].created_ts.as_deref(), Some(epoch_to_iso8601(T0).as_str()));
        assert_eq!(topo.nodes[0].last_active_ts.as_deref(), Some(epoch_to_iso8601(T0).as_str()));
        assert_eq!(topo.nodes[0].tombstoned_ts, None);
    }

    #[test]
    fn tunnel_edges_carry_created_ts() {
        let topo = graph_topology(
            &[drawer("a", ""), drawer("b", "")],
            &[tunnel("a", "b")], &[], "", 0.0);
        let e = topo.edges.iter().find(|e| e.edge_type == "tunnel").unwrap();
        assert!(e.created_ts.is_some());
        assert_eq!(e.tombstoned_ts, None);
    }

    #[test]
    fn kg_fact_bonds_weight_03_nil_timestamps() {
        let facts = vec![
            TopologyFactInput { subject: "s".into(), source_drawer_id: "a".into() },
            TopologyFactInput { subject: "s".into(), source_drawer_id: "b".into() },
        ];
        // estate/ts: explicit sentinels — unit tests have no estate context.
        let topo = graph_topology(&[drawer("a", ""), drawer("b", "")], &[], &facts, "", 0.0);
        let kg = topo.edges.iter().find(|e| e.edge_type == "kgFact").unwrap();
        assert_eq!(kg.weight, 0.3);
        assert_eq!(kg.created_ts, None);
        assert_eq!(kg.tombstoned_ts, None);
    }

    #[test]
    fn bridged_triangles_merge_into_one_community_at_lens_resolution() {
        // Mirrors Swift communitiesSmallFixture. At gamma 0.05 the
        // full-weight tunnel bridge merges the condensed triangle
        // supernodes (gain = 1.0/7.8 - 0.05*7.8*15.6/(2*7.8^2) = +0.078).
        // Correct lens behavior: the bridge is an EXPLICIT tunnel — the
        // strongest evidence class — and the absorption bound
        // w/k = 1.0/7.8 ~= 0.128 sits above gamma.
        let (md, mt, mids) = triangle("math", ["510", "510", "510"]);
        let (ad, at, aids) = triangle("art", ["700", "700", "700"]);
        let mut tunnels = [mt, at].concat();
        tunnels.push(tunnel(&mids[0], &aids[0]));
        let topo = graph_topology(&[md, ad].concat(), &tunnels, &[], "", 0.0);
        assert_eq!(topo.communities.len(), 1);
        assert_eq!(topo.communities[0].size, 6);
        // 510 and 700 tie at 3 members each; ascending tie-break -> "510".
        assert_eq!(topo.communities[0].dominant_udc_code, "510");
        // Community id matches every member node's assignment.
        for id in mids.iter().chain(aids.iter()) {
            let n = topo.nodes.iter().find(|n| &n.id == id).unwrap();
            assert_eq!(n.community_id, topo.communities[0].id);
        }
    }

    #[test]
    fn dominant_ties_break_lexicographically_ascending() {
        // DISJOINT triangles — a full-weight bridge would merge them at
        // gamma 0.05 (see the bridged-triangles test) and destroy the
        // per-community tie this test exercises. Disjoint components can
        // never merge: there is no candidate edge for any gamma.
        let (ld, lt, _lids) = triangle("tie", ["700", "510", ""]);
        let (rd, rt, _rids) = triangle("uni", ["900", "900", "900"]);
        let tunnels = [lt, rt].concat();
        let topo = graph_topology(&[ld, rd].concat(), &tunnels, &[], "", 0.0);
        let tied = topo.communities.iter().find(|c| c.dominant_udc_code != "900").unwrap();
        assert_eq!(tied.size, 3);
        assert_eq!(tied.dominant_udc_code, "510");
    }

    #[test]
    fn star_of_pairs_forms_one_community_end_to_end() {
        // Mirrors Swift starOfPairsOneCommunity — the live-estate pathology
        // MISSION_LOUVAIN_PHASE2 exists for. 8 drawers = 4 tunnel-bonded
        // pairs (w 1.0) sharing udcCode "652"; lattice bonding stars every
        // drawer to the earliest-filed hub at w 0.2. Phase-1 alone locks
        // the 4 pairs; at gamma 0.05 the condensed pair supernodes
        // (k = 2.4, edge 0.4 into the hub pair) merge — absorption bound
        // 0.4/2.4 ~= 0.167 > 0.05. ONE community end-to-end.
        let mut drawers = Vec::new();
        let mut tunnels = Vec::new();
        for p in 0..4i64 {
            let a = format!("p{}a", p);
            let b = format!("p{}b", p);
            // Distinct filed_at per drawer keeps hub selection deterministic.
            drawers.push(TopologyDrawerInput {
                id: a.clone(), udc_code: "652".into(),
                filed_at: T0 + p * 2, event_time: T0,
                tombstoned: false, tombstoned_at: None,
            });
            drawers.push(TopologyDrawerInput {
                id: b.clone(), udc_code: "652".into(),
                filed_at: T0 + p * 2 + 1, event_time: T0,
                tombstoned: false, tombstoned_at: None,
            });
            tunnels.push(tunnel(&a, &b));
        }
        let topo = graph_topology(&drawers, &tunnels, &[], "", 0.0);
        assert_eq!(topo.community_count, 1);
        assert_eq!(topo.communities.len(), 1);
        assert_eq!(topo.communities[0].size, 8);
        assert_eq!(topo.communities[0].dominant_udc_code, "652");
    }

    #[test]
    fn dead_drawer_carries_sentinels_and_instant_and_skips_communities() {
        let died = T0 + 999;
        let (ld, lt, _) = triangle("live", ["510", "510", "510"]);
        let mut drawers = ld;
        drawers.push(dead_drawer("dead", Some(died)));
        let topo = graph_topology(&drawers, &lt, &[], "", 0.0);
        let dead = topo.nodes.iter().find(|n| n.id == "dead").unwrap();
        assert_eq!(dead.community_id, -1);
        assert_eq!(dead.centrality, 0.0);
        assert_eq!(dead.tombstoned_ts.as_deref(), Some(epoch_to_iso8601(died).as_str()));
        assert_eq!(topo.communities.iter().map(|c| c.size).sum::<usize>(), 3);
    }

    #[test]
    fn dead_drawer_with_unresolved_instant_keeps_sentinel() {
        let topo = graph_topology(&[dead_drawer("dead", None)], &[], &[], "", 0.0);
        assert_eq!(topo.nodes[0].community_id, -1);
        assert_eq!(topo.nodes[0].tombstoned_ts, None);
    }

    #[test]
    fn partition_invariant_under_unrelated_tombstone() {
        let (md, mt, mids) = triangle("math", ["510", "510", "510"]);
        let (ad, at, aids) = triangle("art", ["700", "700", "700"]);
        let mut tunnels = [mt, at].concat();
        tunnels.push(tunnel(&mids[0], &aids[0]));

        let partition = |extra: &[TopologyDrawerInput]| -> std::collections::BTreeSet<Vec<String>> {
            let drawers = [md.clone(), ad.clone(), extra.to_vec()].concat();
            let topo = graph_topology(&drawers, &tunnels, &[], "", 0.0);
            let mut by_comm: BTreeMap<i64, Vec<String>> = BTreeMap::new();
            for n in topo.nodes.iter().filter(|n| n.community_id >= 0) {
                by_comm.entry(n.community_id).or_default().push(n.id.clone());
            }
            by_comm.into_values().map(|mut v| { v.sort(); v }).collect()
        };

        assert_eq!(partition(&[]), partition(&[dead_drawer("unrelated", Some(T0 + 1))]));
    }

    #[test]
    fn dead_tunnel_ships_but_never_bonds() {
        let died = T0 + 2000;
        let (md, mt, mids) = triangle("math", ["510", "510", "510"]);
        let (ad, at, aids) = triangle("art", ["700", "700", "700"]);
        let mut tunnels = [mt, at].concat();
        // The ONLY bridge is dead — partition must keep the triangles apart,
        // while the edge still ships for playback.
        tunnels.push(dead_tunnel(&mids[0], &aids[0], died));
        let topo = graph_topology(&[md, ad].concat(), &tunnels, &[], "", 0.0);
        assert_eq!(topo.communities.len(), 2);
        let dead_edge = topo.edges.iter().find(|e| e.tombstoned_ts.is_some()).unwrap();
        assert_eq!(dead_edge.source, mids[0]);
        assert_eq!(dead_edge.target, aids[0]);
    }

    #[test]
    fn empty_inputs_produce_empty_topology() {
        let topo = graph_topology(&[], &[], &[], "", 0.0);
        assert!(topo.nodes.is_empty());
        assert!(topo.edges.is_empty());
        assert!(topo.communities.is_empty());
        assert_eq!(topo.community_count, 0);
    }

    // --- lattice bond contracts (L-series) ---

    fn drawer_at(id: &str, udc: &str, filed_at: i64) -> TopologyDrawerInput {
        TopologyDrawerInput {
            id: id.to_string(), udc_code: udc.to_string(),
            filed_at, event_time: T0, tombstoned: false, tombstoned_at: None,
        }
    }

    /// L1: Three drawers sharing a non-empty udc_code with no tunnels produce
    /// 2 lattice star edges from the earliest hub; weight 0.2; nil timestamps.
    /// A pure 3-star under phase-1 Louvain yields ≤ 2 communities (not 3 singletons).
    #[test]
    fn lattice_star_edges_weight_and_nil_timestamps() {
        let hub = drawer_at("hub", "510", T0);
        let m1  = drawer_at("m1",  "510", T0 + 100);
        let m2  = drawer_at("m2",  "510", T0 + 200);
        let topo = graph_topology(&[hub, m1, m2], &[], &[], "", 0.0);
        let lat: Vec<_> = topo.edges.iter().filter(|e| e.edge_type == "lattice").collect();
        assert_eq!(lat.len(), 2);
        assert!(lat.iter().all(|e| e.source == "hub"));
        assert!(lat.iter().all(|e| (e.weight - 0.2).abs() < 1e-9));
        // Derived bond — no single ingest instant; live-only.
        assert!(lat.iter().all(|e| e.created_ts.is_none()));
        assert!(lat.iter().all(|e| e.tombstoned_ts.is_none()));
        // Louvain merges at least some nodes: from 3 singletons → at most 2 communities.
        assert!(topo.community_count <= 2);
    }

    /// L2: Hub selection is deterministic under permuted input order.
    /// Earliest filed_at wins; ties break by id ascending.
    #[test]
    fn lattice_hub_determinism_filed_at_then_id() {
        let t_early = T0;
        let t_late  = T0 + 1000;
        // Code 300: "cc" earliest → hub. Code 400: "aaa" < "bbb" on tie → hub.
        let drawers_fwd = vec![
            drawer_at("aa", "300", t_late),
            drawer_at("bb", "300", t_late),
            drawer_at("cc", "300", t_early),
            drawer_at("aaa", "400", t_late),
            drawer_at("bbb", "400", t_late),
        ];
        let drawers_rev = vec![
            drawer_at("cc", "300", t_early),
            drawer_at("bb", "300", t_late),
            drawer_at("aa", "300", t_late),
            drawer_at("bbb", "400", t_late),
            drawer_at("aaa", "400", t_late),
        ];
        for drawers in [drawers_fwd, drawers_rev] {
            let topo = graph_topology(&drawers, &[], &[], "", 0.0);
            let lat300: Vec<_> = topo.edges.iter()
                .filter(|e| e.edge_type == "lattice" && ["aa","bb","cc"].contains(&e.source.as_str()))
                .collect();
            assert!(lat300.iter().all(|e| e.source == "cc"),
                "hub for code 300 must be cc (earliest filed_at)");
            let lat400: Vec<_> = topo.edges.iter()
                .filter(|e| e.edge_type == "lattice" && ["aaa","bbb"].contains(&e.source.as_str()))
                .collect();
            assert!(lat400.iter().all(|e| e.source == "aaa"),
                "hub for code 400 must be aaa (id tie-break ascending)");
        }
    }

    /// L3: Centrality uses tunnel+kgFact adjacency only.
    /// A node with 2 tunnel connections outranks a lattice hub of 5 members.
    #[test]
    fn centrality_split_tunnel_outranks_lattice_hub() {
        let mut drawers: Vec<TopologyDrawerInput> = vec![
            drawer_at("lat-hub", "510", T0),
        ];
        for i in 1..=5 {
            drawers.push(drawer_at(&format!("lat-m{i}"), "510", T0 + i));
        }
        drawers.push(drawer("tunnel-node", ""));
        drawers.push(drawer("t-peer-1", ""));
        drawers.push(drawer("t-peer-2", ""));
        let tunnels = vec![tunnel("tunnel-node", "t-peer-1"), tunnel("tunnel-node", "t-peer-2")];
        let topo = graph_topology(&drawers, &tunnels, &[], "", 0.0);
        let lat_hub_c = topo.nodes.iter().find(|n| n.id == "lat-hub").unwrap().centrality;
        let tunnel_c  = topo.nodes.iter().find(|n| n.id == "tunnel-node").unwrap().centrality;
        assert!(tunnel_c > lat_hub_c,
            "tunnel-connected node must outrank lattice hub in centrality");
    }

    /// L4: Empty udc_code drawers and singleton groups produce zero lattice edges.
    #[test]
    fn lattice_empty_code_and_singletons_produce_no_edges() {
        let topo = graph_topology(&[
            drawer("a", ""),
            drawer("b", ""),
            drawer("c", "999"), // singleton — only one drawer with this code
        ], &[], &[], "", 0.0);
        assert!(topo.edges.iter().all(|e| e.edge_type != "lattice"));
    }

    /// L5: A tombstoned drawer in a udc_code group is excluded from the star.
    #[test]
    fn lattice_tombstoned_drawer_excluded() {
        let live1 = drawer_at("live-1", "700", T0);
        let live2 = drawer_at("live-2", "700", T0 + 1);
        let dead  = TopologyDrawerInput {
            id: "dead".to_string(), udc_code: "700".to_string(),
            filed_at: T0 + 2, event_time: T0, tombstoned: true, tombstoned_at: Some(T0 + 100),
        };
        let topo = graph_topology(&[live1, live2, dead], &[], &[], "", 0.0);
        let lat: Vec<_> = topo.edges.iter().filter(|e| e.edge_type == "lattice").collect();
        assert_eq!(lat.len(), 1, "only the 2 live drawers bond");
        assert_eq!(lat[0].source, "live-1");
        assert_eq!(lat[0].target, "live-2");
        assert!(!lat.iter().any(|e| e.source == "dead" || e.target == "dead"));
    }
}
