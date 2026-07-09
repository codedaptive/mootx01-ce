import Testing
import Foundation
@testable import NeuronKit

/// NeuronKit.graphTopology(drawers:tunnels:facts:) — the estate topology
/// snapshot, relocated from GeniusLocusKit (analysis is NeuronKit's lane).
/// These tests pin the full VIZ_V2 wire contract: createdTs (ingest clock),
/// tombstonedTs dissolution semantics (dead sentinels, live-only math),
/// kgFact shared-subject bonding, and community summaries with dominant
/// UDC codes. Pure-array fixtures — no estate, no store; estate I/O and
/// tombstone-instant resolution are the caller's job (ARIA_MCP).
///
/// Fixture note: graphTopology runs FULL Louvain (detectFull) at the lens
/// resolution gamma = NeuronKit.topologyResolution (0.05). At that gamma,
/// small dense fixtures merge aggressively — two triangles joined by a
/// full-weight tunnel bridge become ONE community (condensed merge gain
/// +0.078 > 0), and a lattice 3-star merges completely. Fixtures that must
/// stay split therefore use DISJOINT components (no gamma merges across a
/// missing edge). Expected community counts below were measured against
/// detectFull at gamma 0.05 and asserted exactly.
@Suite("NeuronKit graphTopology — topology analysis contract")
struct TopologyAnalysisTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private let iso = ISO8601DateFormatter()

    private func drawer(_ id: String, udc: String = "510",
                        filedAt: Date? = nil, eventTime: Date? = nil,
                        tombstoned: Bool = false, tombstonedAt: Date? = nil) -> TopologyDrawerInput {
        TopologyDrawerInput(id: id, udcCode: udc,
                            filedAt: filedAt ?? t0, eventTime: eventTime ?? t0,
                            tombstoned: tombstoned, tombstonedAt: tombstonedAt)
    }

    private func tunnel(_ src: String, _ tgt: String,
                        filedAt: Date? = nil, tombstonedAt: Date? = nil) -> TopologyTunnelInput {
        TopologyTunnelInput(sourceDrawerId: src, targetDrawerId: tgt,
                            filedAt: filedAt ?? t0, tombstonedAt: tombstonedAt)
    }

    /// Three drawers tunnel-linked into a triangle, one per `udcs` entry.
    private func triangle(tag: String, udcs: [String])
        -> (drawers: [TopologyDrawerInput], tunnels: [TopologyTunnelInput], ids: [String]) {
        let ids = (0..<3).map { "\(tag)-\($0)" }
        let drawers = zip(ids, udcs).map { drawer($0, udc: $1) }
        let tunnels = [tunnel(ids[0], ids[1]), tunnel(ids[0], ids[2]), tunnel(ids[1], ids[2])]
        return (drawers, tunnels, ids)
    }

    // MARK: - createdTs (L0)

    @Test("every live node carries a parseable ISO-8601 createdTs equal to filedAt")
    func nodesCarryCreatedTs() throws {
        let filed = Date(timeIntervalSince1970: 1_700_000_123)
        let topo = NeuronKit.graphTopology(
            drawers: [drawer("a", filedAt: filed), drawer("b")],
            tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        #expect(topo.nodes.count == 2)
        let a = try #require(topo.nodes.first { $0.id == "a" })
        let ts = try #require(a.createdTs)
        let parsed = try #require(iso.date(from: ts))
        #expect(abs(parsed.timeIntervalSince(filed)) < 1.0)
    }

    @Test("tunnel edges carry createdTs from the tunnel's filedAt")
    func edgesCarryCreatedTs() throws {
        let filed = Date(timeIntervalSince1970: 1_700_000_456)
        let topo = NeuronKit.graphTopology(
            drawers: [drawer("a"), drawer("b")],
            tunnels: [tunnel("a", "b", filedAt: filed)], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        let edge = try #require(topo.edges.first { $0.edgeType == "tunnel" })
        let ts = try #require(edge.createdTs)
        let parsed = try #require(iso.date(from: ts))
        #expect(abs(parsed.timeIntervalSince(filed)) < 1.0)
        #expect(edge.tombstonedTs == nil)
    }

    // MARK: - kgFact bonding

    @Test("shared-subject facts bond drawers with weight 0.3 and nil timestamps")
    func kgFactBonding() throws {
        let topo = NeuronKit.graphTopology(
            drawers: [drawer("a"), drawer("b")],
            tunnels: [],
            facts: [TopologyFactInput(subject: "s", sourceDrawerID: "a"),
                    TopologyFactInput(subject: "s", sourceDrawerID: "b")],
            estate: "", now: Date(timeIntervalSince1970: 0))
        let kg = try #require(topo.edges.first { $0.edgeType == "kgFact" })
        #expect(kg.weight == 0.3)
        // A derived bond aggregates facts filed at different instants —
        // no honest single ingest instant, and live facts only.
        #expect(kg.createdTs == nil)
        #expect(kg.tombstonedTs == nil)
    }

    // MARK: - communities (L3)

    @Test("bridged triangles merge into ONE community at the lens resolution; dominant code ties break ascending")
    func communitiesSmallFixture() throws {
        let math = triangle(tag: "math", udcs: ["510", "510", "510"])
        let art = triangle(tag: "art", udcs: ["700", "700", "700"])
        let topo = NeuronKit.graphTopology(
            drawers: math.drawers + art.drawers,
            tunnels: math.tunnels + art.tunnels + [tunnel(math.ids[0], art.ids[0])],
            facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        // At gamma 0.05 the full-weight tunnel bridge merges the condensed
        // triangle supernodes (gain = 1.0/7.8 − 0.05·7.8·15.6/(2·7.8²)
        // = +0.078 > 0). This is correct lens behavior: the bridge is an
        // EXPLICIT tunnel — the strongest evidence class — and the
        // absorption bound w/k = 1.0/7.8 ≈ 0.128 sits above gamma.
        #expect(topo.communities.count == 1)
        #expect(topo.communities.map { $0.size } == [6])
        // 510 and 700 tie at 3 members each; ascending tie-break → "510".
        #expect(topo.communities.first?.dominantUdcCode == "510")
        // Community id matches every member node's communityId assignment.
        let merged = try #require(topo.communities.first)
        for id in math.ids + art.ids {
            let node = try #require(topo.nodes.first { $0.id == id })
            #expect(node.communityId == merged.id)
        }
    }

    // Fixture note: the two dominant-code tests below need communities that
    // STAY SEPARATE, so their triangles are DISJOINT — at gamma 0.05 a
    // full-weight bridge would merge them (see communitiesSmallFixture).
    // Disjoint components can never merge: there is no candidate edge for
    // any gamma. Each lone triangle still collapses internally (positive
    // gain at this graph size once the second triangle doubles m).

    @Test("dominant UDC frequency ties break lexicographically ascending")
    func dominantTieBreak() throws {
        // Left triangle codes [700, 510, ""] → 510 and 700 tie at 1;
        // "510" wins ascending. Right triangle is uniform 900.
        let left = triangle(tag: "tie", udcs: ["700", "510", ""])
        let right = triangle(tag: "uni", udcs: ["900", "900", "900"])
        let topo = NeuronKit.graphTopology(
            drawers: left.drawers + right.drawers,
            tunnels: left.tunnels + right.tunnels,
            facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        let tied = try #require(topo.communities.first { $0.dominantUdcCode != "900" })
        #expect(tied.size == 3)
        #expect(tied.dominantUdcCode == "510")
    }

    @Test("communities sort by size descending then id ascending; empty codes give empty dominant")
    func communitiesSortAndEmptyDominant() throws {
        let blank = triangle(tag: "blank", udcs: ["", "", ""])
        let coded = triangle(tag: "coded", udcs: ["999", "999", "999"])
        let topo = NeuronKit.graphTopology(
            drawers: blank.drawers + coded.drawers + [drawer("loner", udc: "111")],
            tunnels: blank.tunnels + coded.tunnels,
            facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        // Triangle communities (size 3) sort before the singleton (size 1).
        #expect(topo.communities.map { $0.size } == topo.communities.map { $0.size }.sorted(by: >))
        #expect(topo.communities.last?.size == 1)
        let blankCommunity = try #require(topo.communities.first { $0.dominantUdcCode == "" && $0.size == 3 })
        #expect(blankCommunity.size == 3)
    }

    // MARK: - star-of-pairs (the live-estate pathology, end-to-end)

    /// The reason MISSION_LOUVAIN_PHASE2 exists: tunnel-bonded pairs sharing
    /// a lattice address fragmented into locked pair-communities under
    /// phase-1 Louvain. Through detectFull at the lens resolution, the
    /// lattice star absorbs every pair — ONE community end-to-end.
    @Test("star-of-pairs: tunnel-bonded pairs sharing a lattice address form ONE community")
    func starOfPairsOneCommunity() throws {
        // 8 drawers = 4 tunnel-bonded pairs, all sharing udcCode "652".
        // Lattice bonding stars every drawer to the earliest-filed hub
        // (p0a) at weight 0.2; the pair tunnels are weight 1.0.
        var drawers: [TopologyDrawerInput] = []
        var tunnels: [TopologyTunnelInput] = []
        for p in 0..<4 {
            let a = "p\(p)a", b = "p\(p)b"
            // Distinct filedAt per drawer keeps hub selection deterministic.
            drawers.append(drawer(a, udc: "652", filedAt: t0.addingTimeInterval(Double(p * 2))))
            drawers.append(drawer(b, udc: "652", filedAt: t0.addingTimeInterval(Double(p * 2 + 1))))
            tunnels.append(tunnel(a, b))
        }
        let topo = NeuronKit.graphTopology(drawers: drawers, tunnels: tunnels, facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        // Phase-1 alone locks the 4 pairs (leaving a 1.0 pair bond for a
        // 0.2 lattice bond is strictly negative gain). At gamma 0.05 the
        // condensed pair supernodes (k = 2.4, edge 0.4 into the hub pair)
        // merge: absorption bound 0.4/2.4 ≈ 0.167 > 0.05.
        #expect(topo.communityCount == 1)
        #expect(topo.communities.count == 1)
        #expect(topo.communities.first?.size == 8)
        #expect(topo.communities.first?.dominantUdcCode == "652")
    }

    // MARK: - tombstones (dissolution)

    @Test("a dead drawer carries sentinels and its tombstone instant, and is excluded from communities")
    func deadDrawerSentinels() throws {
        let died = Date(timeIntervalSince1970: 1_700_000_999)
        let tri = triangle(tag: "live", udcs: ["510", "510", "510"])
        let topo = NeuronKit.graphTopology(
            drawers: tri.drawers + [drawer("dead", tombstoned: true, tombstonedAt: died)],
            tunnels: tri.tunnels, facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        let dead = try #require(topo.nodes.first { $0.id == "dead" })
        #expect(dead.communityId == -1)
        #expect(dead.centrality == 0.0)
        let deadTs = try #require(dead.tombstonedTs)
        let parsed = try #require(iso.date(from: deadTs))
        #expect(abs(parsed.timeIntervalSince(died)) < 1.0)
        // Communities count live members only.
        #expect(topo.communities.reduce(0) { $0 + $1.size } == 3)
    }

    @Test("a dead drawer with unresolved instant still carries the -1 sentinel")
    func deadDrawerUnresolvedInstant() throws {
        let topo = NeuronKit.graphTopology(
            drawers: [drawer("dead", tombstoned: true, tombstonedAt: nil)],
            tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        let dead = try #require(topo.nodes.first)
        #expect(dead.communityId == -1)
        #expect(dead.tombstonedTs == nil)
    }

    @Test("live entities carry nil tombstonedTs")
    func liveEntitiesNilTombstone() throws {
        let topo = NeuronKit.graphTopology(
            drawers: [drawer("a"), drawer("b")],
            tunnels: [tunnel("a", "b")], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        #expect(topo.nodes.allSatisfy { $0.tombstonedTs == nil })
        #expect(topo.edges.allSatisfy { $0.tombstonedTs == nil })
    }

    @Test("tombstoning an unrelated drawer does not perturb the community partition")
    func partitionInvariance() throws {
        let math = triangle(tag: "math", udcs: ["510", "510", "510"])
        let art = triangle(tag: "art", udcs: ["700", "700", "700"])
        let bridge = [tunnel(math.ids[0], art.ids[0])]

        func partition(_ extra: [TopologyDrawerInput]) -> Set<Set<String>> {
            let topo = NeuronKit.graphTopology(
                drawers: math.drawers + art.drawers + extra,
                tunnels: math.tunnels + art.tunnels + bridge, facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
            var byCommunity: [Int: Set<String>] = [:]
            for n in topo.nodes where n.communityId >= 0 {
                byCommunity[n.communityId, default: []].insert(n.id)
            }
            return Set(byCommunity.values)
        }

        let before = partition([])
        let after = partition([drawer("unrelated", tombstoned: true,
                                      tombstonedAt: Date(timeIntervalSince1970: 1_700_001_000))])
        #expect(before == after)
    }

    @Test("a dead tunnel appears as an edge with tombstonedTs but never bonds communities")
    func deadTunnelExcludedFromAdjacency() throws {
        let died = Date(timeIntervalSince1970: 1_700_002_000)
        let math = triangle(tag: "math", udcs: ["510", "510", "510"])
        let art = triangle(tag: "art", udcs: ["700", "700", "700"])
        // The ONLY bridge between the triangles is dead — so the partition
        // must keep them separate, while the edge still ships for playback.
        let topo = NeuronKit.graphTopology(
            drawers: math.drawers + art.drawers,
            tunnels: math.tunnels + art.tunnels +
                     [tunnel(math.ids[0], art.ids[0], tombstonedAt: died)],
            facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        #expect(topo.communities.count == 2)
        let deadEdge = try #require(topo.edges.first { $0.tombstonedTs != nil })
        #expect(deadEdge.source == math.ids[0])
        #expect(deadEdge.target == art.ids[0])
    }

    // MARK: - totality

    @Test("empty inputs produce an empty topology")
    func emptyInputs() {
        let topo = NeuronKit.graphTopology(drawers: [], tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        #expect(topo.nodes.isEmpty)
        #expect(topo.edges.isEmpty)
        #expect(topo.communities.isEmpty)
        #expect(topo.communityCount == 0)
    }

    // MARK: - lattice bonds (L-series)

    /// Contract 1: Three drawers sharing a non-empty udcCode with no tunnels
    /// produce 2 lattice edges (hub→M1, hub→M2), all weight 0.2, nil timestamps.
    ///
    /// Community merging: at the lens resolution (gamma 0.05) the pure
    /// 3-star collapses completely — the last node's gain, exactly 0 under
    /// classical modularity, becomes strictly positive once gamma scales the
    /// penalty term (0.5 − 0.05·0.5 = +0.475). One community of 3.
    @Test("three drawers sharing a udcCode produce lattice star edges from the earliest hub")
    func latticeStarEdges() throws {
        let t1 = Date(timeIntervalSince1970: 1_700_000_100)
        let t2 = Date(timeIntervalSince1970: 1_700_000_200)
        let t3 = Date(timeIntervalSince1970: 1_700_000_300)
        let hubD = TopologyDrawerInput(id: "hub", udcCode: "510",
                                       filedAt: t1, eventTime: t0,
                                       tombstoned: false, tombstonedAt: nil)
        let m1   = TopologyDrawerInput(id: "m1", udcCode: "510",
                                       filedAt: t2, eventTime: t0,
                                       tombstoned: false, tombstonedAt: nil)
        let m2   = TopologyDrawerInput(id: "m2", udcCode: "510",
                                       filedAt: t3, eventTime: t0,
                                       tombstoned: false, tombstonedAt: nil)
        let topo = NeuronKit.graphTopology(drawers: [hubD, m1, m2], tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        let lat = topo.edges.filter { $0.edgeType == "lattice" }
        #expect(lat.count == 2)
        #expect(lat.allSatisfy { $0.source == "hub" })
        #expect(lat.allSatisfy { $0.weight == 0.2 })
        // Derived bonds carry nil timestamps — no single ingest instant, live-only.
        #expect(lat.allSatisfy { $0.createdTs == nil })
        #expect(lat.allSatisfy { $0.tombstonedTs == nil })
        // The whole star merges at the lens resolution.
        #expect(topo.communityCount == 1)
    }

    /// Contract 2: Hub selection is deterministic regardless of input order.
    /// Earliest filedAt wins; ties break by id ascending.
    @Test("hub is the earliest-filedAt drawer; id ascending on tie — deterministic under permutation")
    func latticeHubDeterminism() throws {
        let tEarly = Date(timeIntervalSince1970: 1_700_000_000)
        let tLate  = Date(timeIntervalSince1970: 1_700_001_000)
        // "aa" and "bb" share tLate; "cc" has the earliest time → hub is "cc".
        let aa = TopologyDrawerInput(id: "aa", udcCode: "300",
                                     filedAt: tLate, eventTime: t0,
                                     tombstoned: false, tombstonedAt: nil)
        let bb = TopologyDrawerInput(id: "bb", udcCode: "300",
                                     filedAt: tLate, eventTime: t0,
                                     tombstoned: false, tombstonedAt: nil)
        let cc = TopologyDrawerInput(id: "cc", udcCode: "300",
                                     filedAt: tEarly, eventTime: t0,
                                     tombstoned: false, tombstonedAt: nil)
        // Also check tie-break: "aaa" < "bbb" lexicographically → hub is "aaa".
        let aaa = TopologyDrawerInput(id: "aaa", udcCode: "400",
                                      filedAt: tLate, eventTime: t0,
                                      tombstoned: false, tombstonedAt: nil)
        let bbb = TopologyDrawerInput(id: "bbb", udcCode: "400",
                                      filedAt: tLate, eventTime: t0,
                                      tombstoned: false, tombstonedAt: nil)

        // Permutation 1: cc last
        let topo1 = NeuronKit.graphTopology(drawers: [aa, bb, cc, aaa, bbb], tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        // Permutation 2: cc first
        let topo2 = NeuronKit.graphTopology(drawers: [cc, aa, bb, aaa, bbb], tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))

        for topo in [topo1, topo2] {
            let lat300 = topo.edges.filter { $0.edgeType == "lattice" && ["aa","bb","cc"].contains($0.source) }
            #expect(lat300.allSatisfy { $0.source == "cc" },
                    "hub for code 300 must be cc (earliest filedAt)")
            let lat400 = topo.edges.filter { $0.edgeType == "lattice" && ["aaa","bbb"].contains($0.source) }
            #expect(lat400.allSatisfy { $0.source == "aaa" },
                    "hub for code 400 must be aaa (tie-break: id ascending)")
        }
    }

    /// Contract 3: Centrality is computed BEFORE lattice edges are appended.
    /// A node with 2 tunnel connections outranks a lattice hub bonded to 5 members
    /// (which has zero tunnel degree and therefore zero centrality contribution).
    @Test("centrality split — 2-tunnel node outranks a lattice hub of 5 members")
    func centralitySplitTunnelOutranksLatticeHub() throws {
        // Lattice hub bonded to 5 members via shared udcCode; no tunnels.
        var drawers: [TopologyDrawerInput] = [
            TopologyDrawerInput(id: "lat-hub", udcCode: "510",
                                filedAt: t0, eventTime: t0,
                                tombstoned: false, tombstonedAt: nil)
        ]
        for i in 1...5 {
            drawers.append(TopologyDrawerInput(id: "lat-m\(i)", udcCode: "510",
                                               filedAt: t0.addingTimeInterval(Double(i)),
                                               eventTime: t0, tombstoned: false,
                                               tombstonedAt: nil))
        }
        // A tunnel node explicitly connected to 2 peers.
        drawers.append(TopologyDrawerInput(id: "tunnel-node", udcCode: "",
                                           filedAt: t0, eventTime: t0,
                                           tombstoned: false, tombstonedAt: nil))
        drawers.append(TopologyDrawerInput(id: "t-peer-1", udcCode: "",
                                           filedAt: t0, eventTime: t0,
                                           tombstoned: false, tombstonedAt: nil))
        drawers.append(TopologyDrawerInput(id: "t-peer-2", udcCode: "",
                                           filedAt: t0, eventTime: t0,
                                           tombstoned: false, tombstonedAt: nil))
        let tunnelEdges = [
            TopologyTunnelInput(sourceDrawerId: "tunnel-node", targetDrawerId: "t-peer-1",
                                filedAt: t0, tombstonedAt: nil),
            TopologyTunnelInput(sourceDrawerId: "tunnel-node", targetDrawerId: "t-peer-2",
                                filedAt: t0, tombstonedAt: nil)
        ]
        let topo = NeuronKit.graphTopology(drawers: drawers, tunnels: tunnelEdges, facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        let latHub    = try #require(topo.nodes.first { $0.id == "lat-hub" })
        let tunnelNode = try #require(topo.nodes.first { $0.id == "tunnel-node" })
        // The lattice hub has no tunnel edges, so its centrality score comes
        // purely from the centrality adjacency (tunnel+kgFact only) — it is 0.
        // The tunnel-connected node has explicit structural prominence.
        #expect(tunnelNode.centrality > latHub.centrality,
                "explicit tunnel connections outrank derived lattice classification in centrality")
    }

    /// Contract 4: Drawers with empty udcCode are never lattice-bonded;
    /// singleton groups (only one drawer with a given code) produce no edges.
    @Test("empty udcCode and singleton groups produce zero lattice edges")
    func latticeEmptyCodeAndSingletons() {
        let d1 = TopologyDrawerInput(id: "a", udcCode: "",
                                     filedAt: t0, eventTime: t0,
                                     tombstoned: false, tombstonedAt: nil)
        let d2 = TopologyDrawerInput(id: "b", udcCode: "",
                                     filedAt: t0, eventTime: t0,
                                     tombstoned: false, tombstonedAt: nil)
        // "999" has only one member — no star edge.
        let d3 = TopologyDrawerInput(id: "c", udcCode: "999",
                                     filedAt: t0, eventTime: t0,
                                     tombstoned: false, tombstonedAt: nil)
        let topo = NeuronKit.graphTopology(drawers: [d1, d2, d3], tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        #expect(topo.edges.filter { $0.edgeType == "lattice" }.isEmpty)
    }

    /// Contract 5: A tombstoned drawer sharing a udcCode with live drawers
    /// is excluded from the lattice group — no edge to it.
    @Test("tombstoned drawer in a udcCode group is not lattice-bonded")
    func latticeTombstonedExcluded() throws {
        let live1 = TopologyDrawerInput(id: "live-1", udcCode: "700",
                                        filedAt: t0, eventTime: t0,
                                        tombstoned: false, tombstonedAt: nil)
        let live2 = TopologyDrawerInput(id: "live-2", udcCode: "700",
                                        filedAt: t0.addingTimeInterval(1), eventTime: t0,
                                        tombstoned: false, tombstonedAt: nil)
        let dead  = TopologyDrawerInput(id: "dead", udcCode: "700",
                                        filedAt: t0.addingTimeInterval(2), eventTime: t0,
                                        tombstoned: true,
                                        tombstonedAt: t0.addingTimeInterval(100))
        let topo = NeuronKit.graphTopology(drawers: [live1, live2, dead], tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))
        let lat = topo.edges.filter { $0.edgeType == "lattice" }
        // Only the 2 live drawers bond; the dead drawer contributes no edge.
        #expect(lat.count == 1)
        let latEdge = try #require(lat.first, "expected one lattice edge between live drawers")
        #expect(latEdge.source == "live-1")
        #expect(latEdge.target == "live-2")
        #expect(!lat.contains { $0.source == "dead" || $0.target == "dead" })
    }

    // MARK: - udcCode carry-through (V2-P1a)

    @Test("non-empty udcCode passes through to GraphTopologyNode on live and dead nodes")
    func udcCodeCarryThrough() throws {
        let live = TopologyDrawerInput(id: "anchor", udcCode: "615.85",
                                       filedAt: t0, eventTime: t0,
                                       tombstoned: false, tombstonedAt: nil)
        let dead = TopologyDrawerInput(id: "gone", udcCode: "657",
                                       filedAt: t0, eventTime: t0,
                                       tombstoned: true, tombstonedAt: t0.addingTimeInterval(60))
        let topo = NeuronKit.graphTopology(
            drawers: [live, dead], tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))

        let liveNode = try #require(topo.nodes.first { $0.id == "anchor" })
        #expect(liveNode.udcCode == "615.85", "non-empty code must be carried through on live node")

        let deadNode = try #require(topo.nodes.first { $0.id == "gone" })
        #expect(deadNode.udcCode == "657", "dead nodes retain their udcCode")
    }

    @Test("empty-string udcCode (unanchored sentinel) normalises to nil")
    func udcCodeEmptyNormalisesToNil() throws {
        let unanchored = TopologyDrawerInput(id: "x", udcCode: "",
                                             filedAt: t0, eventTime: t0,
                                             tombstoned: false, tombstonedAt: nil)
        let topo = NeuronKit.graphTopology(
            drawers: [unanchored], tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))

        let node = try #require(topo.nodes.first { $0.id == "x" })
        #expect(node.udcCode == nil, "empty-string udcCode must normalise to nil at GraphTopologyNode boundary")
    }

    @Test("GraphTopologyNode JSON round-trip: udcCode present when set, key absent when nil, tolerates legacy JSON")
    func graphTopologyNodeUdcCodeJsonRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        // GraphTopologyNode is Codable; verify the wire contract:
        // udcCode present in JSON when set; key absent (not null) when nil;
        // decodes without error when key is missing (tolerates pre-V2-P1a snapshots).
        let live = TopologyDrawerInput(id: "anchored", udcCode: "510",
                                       filedAt: t0, eventTime: t0,
                                       tombstoned: false, tombstonedAt: nil)
        let unanchored = TopologyDrawerInput(id: "none", udcCode: "",
                                             filedAt: t0, eventTime: t0,
                                             tombstoned: false, tombstonedAt: nil)
        let topo = NeuronKit.graphTopology(
            drawers: [live, unanchored], tunnels: [], facts: [], estate: "", now: Date(timeIntervalSince1970: 0))

        let anchored = try #require(topo.nodes.first { $0.id == "anchored" })
        let none     = try #require(topo.nodes.first { $0.id == "none" })

        // Encode the anchored node and verify JSON key is present.
        let anchoredData = try encoder.encode(anchored)
        let anchoredJSON = try #require(
            try? JSONSerialization.jsonObject(with: anchoredData) as? [String: Any])
        #expect(anchoredJSON["udcCode"] as? String == "510",
                "udcCode key must be present in JSON when code is set")

        // Encode the unanchored node and verify JSON key is absent (not null).
        let noneData = try encoder.encode(none)
        let noneJSON = try #require(
            try? JSONSerialization.jsonObject(with: noneData) as? [String: Any])
        #expect(noneJSON["udcCode"] == nil,
                "udcCode key must be absent in JSON when code is nil — not null")

        // Decode a JSON snapshot that lacks udcCode — tolerate absence (older snapshots).
        let oldSnapshotJSON = """
            {"id":"legacy","communityId":0,"centrality":0.5,"tombstonedTs":null,\
             "anomaly":false,"nounType":0}
            """.data(using: .utf8)!
        let legacy = try decoder.decode(GraphTopologyNode.self, from: oldSnapshotJSON)
        #expect(legacy.udcCode == nil,
                "GraphTopologyNode must decode without error when udcCode key is absent")
    }
}
