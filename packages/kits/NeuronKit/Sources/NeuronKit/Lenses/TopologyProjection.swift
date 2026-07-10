import Foundation

/// Persistable, content-free projection of a topology snapshot into a stable
/// three-level spatial hierarchy. FDC is deliberately absent from every
/// partitioning and coordinate decision; codes are summarized only after the
/// structural projection exists.
struct PersistentTopologyProjection: Sendable {
    struct Node: Sendable {
        let communityKey: String?
        let foldKey: String?
        let x: Double
        let y: Double
        let z: Double
        let representative: Bool
    }

    struct Community: Sendable {
        let rawID: Int
        let stableKey: String
        let size: Int
        let x: Double
        let y: Double
        let z: Double
        let foldCount: Int
        let representativeIDs: [String]
        let classificationPurity: Double
    }

    struct Fold: Sendable {
        let stableKey: String
        let communityKey: String
        let size: Int
        let x: Double
        let y: Double
        let z: Double
        let representativeIDs: [String]
        let dominantUdcCode: String
    }

    struct Bridge: Sendable {
        let level: String
        let sourceKey: String
        let targetKey: String
        let edgeType: String
        let weight: Double
        let edgeCount: Int
    }

    let nodesByID: [String: Node]
    let communities: [Community]
    let folds: [Fold]
    let bridges: [Bridge]
}

enum TopologyProjector {
    private static let targetFoldSize = 192
    private static let maximumFoldsPerCommunity = 64

    private struct Point: Codable, Sendable {
        var x: Double
        var y: Double
        var z: Double

        static let zero = Point(x: 0, y: 0, z: 0)

        static func + (lhs: Point, rhs: Point) -> Point {
            Point(x: lhs.x + rhs.x, y: lhs.y + rhs.y, z: lhs.z + rhs.z)
        }

        static func * (lhs: Point, rhs: Double) -> Point {
            Point(x: lhs.x * rhs, y: lhs.y * rhs, z: lhs.z * rhs)
        }

        func bounded() -> Point {
            Point(x: min(0.98, max(-0.98, x)),
                  y: min(0.78, max(-0.78, y)),
                  z: min(0.82, max(-0.82, z)))
        }
    }

    private struct PreviousSnapshot: Decodable {
        let nodes: [PreviousNode]?
        let communities: [PreviousAggregate]?
        let folds: [PreviousAggregate]?
    }

    private struct PreviousNode: Decodable {
        let id: String
        let communityKey: String?
        let foldKey: String?
        let x: Double?
        let y: Double?
        let z: Double?
    }

    private struct PreviousAggregate: Decodable {
        let stableKey: String
        let x: Double?
        let y: Double?
        let z: Double?
    }

    private struct RawGroup {
        let rawKey: String
        let members: [String]
    }

    private struct BridgeKey: Hashable {
        let level: String
        let source: String
        let target: String
        let edgeType: String
    }

    private struct BridgeValue {
        var weight: Double = 0
        var count: Int = 0
        var sourceRepresentative: (id: String, score: Double)?
        var targetRepresentative: (id: String, score: Double)?
    }

    static func project(_ topology: GraphTopology, previousSnapshot: Data?) -> PersistentTopologyProjection {
        let previous = previousSnapshot.flatMap { try? JSONDecoder().decode(PreviousSnapshot.self, from: $0) }
        let previousNodes = Dictionary(uniqueKeysWithValues: (previous?.nodes ?? []).map { ($0.id, $0) })

        let liveNodes = topology.nodes.filter { $0.communityId >= 0 && $0.tombstonedTs == nil }
        let liveByID = Dictionary(uniqueKeysWithValues: liveNodes.map { ($0.id, $0) })
        let liveIDs = Set(liveByID.keys)

        // Classification/lattice edges are visual metadata, never structural input.
        let structuralEdges = topology.edges.filter {
            $0.edgeType != "lattice" && $0.tombstonedTs == nil &&
                liveIDs.contains($0.source) && liveIDs.contains($0.target)
        }.sorted {
            ($0.source, $0.target, $0.edgeType) < ($1.source, $1.target, $1.edgeType)
        }
        var adjacency: [String: [String]] = [:]
        var weightedAdjacency: [String: [String: Double]] = [:]
        adjacency.reserveCapacity(liveNodes.count)
        for edge in structuralEdges where edge.source != edge.target {
            adjacency[edge.source, default: []].append(edge.target)
            adjacency[edge.target, default: []].append(edge.source)
            weightedAdjacency[edge.source, default: [:]][edge.target, default: 0] += edge.weight
            weightedAdjacency[edge.target, default: [:]][edge.source, default: 0] += edge.weight
        }
        for id in adjacency.keys { adjacency[id] = Array(Set(adjacency[id]!)).sorted() }

        let membersByRawCommunity = Dictionary(grouping: liveNodes, by: \.communityId)
        let communityGroups = membersByRawCommunity.keys.sorted().map { rawID in
            RawGroup(rawKey: String(rawID), members: membersByRawCommunity[rawID]!.map(\.id).sorted())
        }
        let previousCommunityPairs: [(String, String)] = previousNodes.values.compactMap {
            guard let key = $0.communityKey, !key.isEmpty else { return nil }
            return ($0.id, key)
        }
        let previousCommunityByMember = Dictionary(uniqueKeysWithValues: previousCommunityPairs)
        let communityKeys = stableKeys(for: communityGroups,
                                       previousKeyByMember: previousCommunityByMember,
                                       prefix: "c")

        var foldGroups: [RawGroup] = []
        for rawID in membersByRawCommunity.keys.sorted() {
            let members = membersByRawCommunity[rawID]!.sorted { $0.id < $1.id }
            for (index, ids) in partitionFolds(members: members, adjacency: adjacency).enumerated() {
                let rawKey = "\(rawID):\(index)"
                foldGroups.append(RawGroup(rawKey: rawKey, members: ids))
            }
        }
        let previousFoldPairs: [(String, String)] = previousNodes.values.compactMap {
            guard let key = $0.foldKey, !key.isEmpty else { return nil }
            return ($0.id, key)
        }
        let previousFoldByMember = Dictionary(uniqueKeysWithValues: previousFoldPairs)
        let foldKeys = stableKeys(for: foldGroups,
                                  previousKeyByMember: previousFoldByMember,
                                  prefix: "f")

        var communityKeyByNode: [String: String] = [:]
        var foldKeyByNode: [String: String] = [:]
        for group in communityGroups {
            let stable = communityKeys[group.rawKey]!
            for id in group.members { communityKeyByNode[id] = stable }
        }
        for group in foldGroups {
            let stable = foldKeys[group.rawKey]!
            for id in group.members { foldKeyByNode[id] = stable }
        }

        let centralityByID = Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, $0.centrality) })
        var bridgeValues: [BridgeKey: BridgeValue] = [:]
        for edge in structuralEdges {
            guard let sourceCommunity = communityKeyByNode[edge.source],
                  let targetCommunity = communityKeyByNode[edge.target],
                  let sourceFold = foldKeyByNode[edge.source],
                  let targetFold = foldKeyByNode[edge.target] else { continue }
            if sourceCommunity != targetCommunity {
                accumulateBridge(level: "community", source: sourceCommunity, target: targetCommunity,
                                 edge: edge, centralityByID: centralityByID, values: &bridgeValues)
            }
            if sourceFold != targetFold {
                accumulateBridge(level: "fold", source: sourceFold, target: targetFold,
                                 edge: edge, centralityByID: centralityByID, values: &bridgeValues)
            }
        }

        let previousCommunityPositions = positions(previous?.communities)
        let previousFoldPositions = positions(previous?.folds)
        let communityPositions = aggregatePositions(
            keys: communityGroups.compactMap { communityKeys[$0.rawKey] },
            previous: previousCommunityPositions,
            bridges: bridgeValues.filter { $0.key.level == "community" },
            radius: 0.72)

        var representatives = Set<String>()
        for value in bridgeValues.values {
            if let id = value.sourceRepresentative?.id { representatives.insert(id) }
            if let id = value.targetRepresentative?.id { representatives.insert(id) }
        }

        var foldPositions: [String: Point] = [:]
        for communityGroup in communityGroups.sorted(by: { $0.rawKey < $1.rawKey }) {
            let communityKey = communityKeys[communityGroup.rawKey]!
            let center = communityPositions[communityKey] ?? .zero
            let localGroups = foldGroups.filter { $0.rawKey.hasPrefix("\(communityGroup.rawKey):") }
            let localKeys = localGroups.compactMap { foldKeys[$0.rawKey] }.sorted()
            let keySet = Set(localKeys)
            let prior = Dictionary(uniqueKeysWithValues: localKeys.compactMap { key in
                previousFoldPositions[key].map { (key, $0) }
            })
            let localBridges = bridgeValues.filter {
                $0.key.level == "fold" && keySet.contains($0.key.source) && keySet.contains($0.key.target)
            }
            let localPositions = aggregatePositions(
                keys: localKeys, previous: prior, bridges: localBridges,
                radius: 0.17, fallbackCenter: center)
            foldPositions.merge(localPositions) { _, new in new }
        }

        var foldSummaries: [PersistentTopologyProjection.Fold] = []
        for group in foldGroups.sorted(by: { foldKeys[$0.rawKey]! < foldKeys[$1.rawKey]! }) {
            let foldKey = foldKeys[group.rawKey]!
            let rawCommunity = group.rawKey.split(separator: ":").first.map(String.init)!
            let communityKey = communityKeys[rawCommunity]!
            let center = communityPositions[communityKey] ?? .zero
            let point = foldPositions[foldKey] ?? center
            foldPositions[foldKey] = point

            let top = group.members.sorted {
                let l = centralityByID[$0] ?? 0
                let r = centralityByID[$1] ?? 0
                return l != r ? l > r : $0 < $1
            }.prefix(3)
            representatives.formUnion(top)
            let dominant = dominantCode(group.members.compactMap { liveByID[$0]?.udcCode })
            foldSummaries.append(.init(stableKey: foldKey, communityKey: communityKey,
                                       size: group.members.count,
                                       x: point.x, y: point.y, z: point.z,
                                       representativeIDs: Array(top), dominantUdcCode: dominant))
        }

        var communitySummaries: [PersistentTopologyProjection.Community] = []
        for group in communityGroups.sorted(by: { communityKeys[$0.rawKey]! < communityKeys[$1.rawKey]! }) {
            let key = communityKeys[group.rawKey]!
            let point = communityPositions[key] ?? .zero
            let top = group.members.sorted {
                let l = centralityByID[$0] ?? 0
                let r = centralityByID[$1] ?? 0
                return l != r ? l > r : $0 < $1
            }.prefix(3)
            representatives.formUnion(top)
            let codes = group.members.compactMap { liveByID[$0]?.udcCode }.filter { !$0.isEmpty && $0 != "000" }
            let dominantCount = Dictionary(grouping: codes, by: { $0 }).values.map(\.count).max() ?? 0
            let foldCount = foldGroups.lazy.filter { $0.rawKey.hasPrefix("\(group.rawKey):") }.count
            communitySummaries.append(.init(
                rawID: Int(group.rawKey) ?? 0, stableKey: key, size: group.members.count,
                x: point.x, y: point.y, z: point.z, foldCount: foldCount,
                representativeIDs: Array(top),
                classificationPurity: group.members.isEmpty ? 0 : Double(dominantCount) / Double(group.members.count)))
        }

        // Existing nodes are fixed landmarks. New nodes begin at a stable
        // hash anchor inside their fold, then relax toward structural
        // neighbours. This earns local position from relationships without
        // moving the mental map that a prior snapshot established.
        var livePositions: [String: Point] = [:]
        for group in foldGroups.sorted(by: { foldKeys[$0.rawKey]! < foldKeys[$1.rawKey]! }) {
            let foldKey = foldKeys[group.rawKey]!
            guard let center = foldPositions[foldKey] else { continue }
            let members = group.members.sorted()
            let memberSet = Set(members)
            let spread = min(0.12, 0.025 + sqrt(Double(max(1, members.count))) * 0.003)
            var positions: [String: Point] = [:]
            var fixed = Set<String>()
            for id in members {
                if let prior = previousNodes[id].flatMap(point) {
                    positions[id] = prior
                    fixed.insert(id)
                } else {
                    positions[id] = (center + hashDirection(id) * spread).bounded()
                }
            }
            let anchors = positions
            let movable = members.filter { !fixed.contains($0) }
            for _ in 0..<16 {
                var next = positions
                for id in movable {
                    guard let neighborMap = weightedAdjacency[id], !neighborMap.isEmpty else { continue }
                    let neighbors = neighborMap.sorted { $0.key < $1.key }.compactMap {
                        neighbor, weight -> (Point, Double)? in
                        guard memberSet.contains(neighbor), let position = positions[neighbor] else { return nil }
                        return (position, max(0.01, weight))
                    }
                    guard !neighbors.isEmpty else { continue }
                    let total = neighbors.reduce(0) { $0 + $1.1 }
                    let average = neighbors.reduce(Point.zero) { $0 + $1.0 * ($1.1 / total) }
                    next[id] = (anchors[id]! * 0.58 + average * 0.42).bounded()
                }
                positions = next
            }
            livePositions.merge(positions) { _, new in new }
        }

        var projectedNodes: [String: PersistentTopologyProjection.Node] = [:]
        projectedNodes.reserveCapacity(topology.nodes.count)
        for node in topology.nodes {
            if let communityKey = communityKeyByNode[node.id],
               let foldKey = foldKeyByNode[node.id], let position = livePositions[node.id] {
                projectedNodes[node.id] = .init(
                    communityKey: communityKey, foldKey: foldKey,
                    x: position.x, y: position.y, z: position.z,
                    representative: representatives.contains(node.id))
            } else {
                // Dead/historical-only nodes retain their last known coordinates.
                // Legacy snapshots without them receive a deterministic outer-shell
                // position; no current community is fabricated.
                let position = previousNodes[node.id].flatMap(point) ?? (hashDirection(node.id) * 0.9).bounded()
                projectedNodes[node.id] = .init(
                    communityKey: nil, foldKey: nil,
                    x: position.x, y: position.y, z: position.z,
                    representative: false)
            }
        }

        let bridges = bridgeValues.map { key, value in
            PersistentTopologyProjection.Bridge(
                level: key.level, sourceKey: key.source, targetKey: key.target,
                edgeType: key.edgeType, weight: value.weight, edgeCount: value.count)
        }.sorted {
            ($0.level, $0.sourceKey, $0.targetKey, $0.edgeType) <
                ($1.level, $1.sourceKey, $1.targetKey, $1.edgeType)
        }

        return PersistentTopologyProjection(
            nodesByID: projectedNodes,
            communities: communitySummaries,
            folds: foldSummaries,
            bridges: bridges)
    }

    private static func partitionFolds(
        members: [GraphTopologyNode], adjacency: [String: [String]]
    ) -> [[String]] {
        let ids = members.map(\.id).sorted()
        guard ids.count > targetFoldSize else { return ids.isEmpty ? [] : [ids] }
        let desired = min(maximumFoldsPerCommunity,
                          max(1, Int(ceil(Double(ids.count) / Double(targetFoldSize)))))
        let memberSet = Set(ids)
        let score = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.centrality) })
        var seeds = [ids.max {
            let l = score[$0] ?? 0, r = score[$1] ?? 0
            return l != r ? l < r : $0 > $1
        }!]

        while seeds.count < desired {
            let distance = distances(from: seeds, within: memberSet, adjacency: adjacency)
            let candidates = ids.filter { !seeds.contains($0) }
            guard let next = candidates.max(by: { lhs, rhs in
                let ld = distance[lhs] ?? Int.max
                let rd = distance[rhs] ?? Int.max
                if ld != rd { return ld < rd }
                let lc = score[lhs] ?? 0, rc = score[rhs] ?? 0
                return lc != rc ? lc < rc : lhs > rhs
            }) else { break }
            seeds.append(next)
        }
        seeds.sort()

        var owner: [String: String] = [:]
        var distance: [String: Int] = [:]
        var queue: [String] = []
        for seed in seeds { owner[seed] = seed; distance[seed] = 0; queue.append(seed) }
        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            let nextDistance = (distance[current] ?? 0) + 1
            for neighbor in adjacency[current] ?? [] where memberSet.contains(neighbor) {
                let currentOwner = owner[current]!
                let shouldTake = distance[neighbor] == nil || nextDistance < distance[neighbor]! ||
                    (nextDistance == distance[neighbor]! && currentOwner < owner[neighbor]!)
                if shouldTake {
                    distance[neighbor] = nextDistance
                    owner[neighbor] = currentOwner
                    queue.append(neighbor)
                }
            }
        }
        for id in ids where owner[id] == nil {
            owner[id] = seeds[Int(fnv1a(id) % UInt64(seeds.count))]
        }
        return Dictionary(grouping: ids, by: { owner[$0]! })
            .sorted { $0.key < $1.key }.map { $0.value.sorted() }
    }

    private static func distances(
        from seeds: [String], within members: Set<String>, adjacency: [String: [String]]
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        var queue = seeds.sorted()
        for seed in queue { result[seed] = 0 }
        var head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            let next = result[current]! + 1
            for neighbor in adjacency[current] ?? [] where members.contains(neighbor) && result[neighbor] == nil {
                result[neighbor] = next
                queue.append(neighbor)
            }
        }
        return result
    }

    private static func stableKeys(
        for groups: [RawGroup], previousKeyByMember: [String: String], prefix: String
    ) -> [String: String] {
        struct Candidate {
            let raw: String
            let previous: String
            let overlap: Int
            let size: Int
        }
        var candidates: [Candidate] = []
        let previousSizes = Dictionary(grouping: previousKeyByMember.values, by: { $0 }).mapValues(\.count)
        for group in groups {
            let counts = Dictionary(grouping: group.members.compactMap { previousKeyByMember[$0] }, by: { $0 })
            for (key, members) in counts {
                let largerMembership = max(group.members.count, previousSizes[key] ?? 0)
                guard members.count * 2 > largerMembership else { continue }
                candidates.append(Candidate(raw: group.rawKey, previous: key,
                                            overlap: members.count, size: group.members.count))
            }
        }
        candidates.sort {
            if $0.overlap != $1.overlap { return $0.overlap > $1.overlap }
            let lhsRatio = Double($0.overlap) / Double(max(1, $0.size))
            let rhsRatio = Double($1.overlap) / Double(max(1, $1.size))
            if lhsRatio != rhsRatio { return lhsRatio > rhsRatio }
            if $0.previous != $1.previous { return $0.previous < $1.previous }
            return $0.raw < $1.raw
        }
        var result: [String: String] = [:]
        var usedPrevious = Set<String>()
        for candidate in candidates where result[candidate.raw] == nil && !usedPrevious.contains(candidate.previous) {
            result[candidate.raw] = candidate.previous
            usedPrevious.insert(candidate.previous)
        }
        for group in groups where result[group.rawKey] == nil {
            result[group.rawKey] = "\(prefix)-\(hex(fnv1a(group.members.joined(separator: "\u{1}"))))"
        }
        return result
    }

    private static func accumulateBridge(
        level: String, source: String, target: String, edge: GraphTopologyEdge,
        centralityByID: [String: Double], values: inout [BridgeKey: BridgeValue]
    ) {
        let ordered = source < target ? (source, target, edge.source, edge.target) :
            (target, source, edge.target, edge.source)
        let key = BridgeKey(level: level, source: ordered.0, target: ordered.1, edgeType: edge.edgeType)
        var value = values[key] ?? BridgeValue()
        value.weight += edge.weight
        value.count += 1
        let sourceScore = centralityByID[ordered.2] ?? 0
        if value.sourceRepresentative == nil || sourceScore > value.sourceRepresentative!.score ||
            (sourceScore == value.sourceRepresentative!.score && ordered.2 < value.sourceRepresentative!.id) {
            value.sourceRepresentative = (ordered.2, sourceScore)
        }
        let targetScore = centralityByID[ordered.3] ?? 0
        if value.targetRepresentative == nil || targetScore > value.targetRepresentative!.score ||
            (targetScore == value.targetRepresentative!.score && ordered.3 < value.targetRepresentative!.id) {
            value.targetRepresentative = (ordered.3, targetScore)
        }
        values[key] = value
    }

    private static func aggregatePositions(
        keys: [String], previous: [String: Point], bridges: [BridgeKey: BridgeValue],
        radius: Double, fallbackCenter: Point = .zero
    ) -> [String: Point] {
        let orderedBridges = bridges.sorted {
            ($0.key.level, $0.key.source, $0.key.target, $0.key.edgeType) <
                ($1.key.level, $1.key.source, $1.key.target, $1.key.edgeType)
        }
        var positions: [String: Point] = [:]
        for key in keys.sorted() {
            if let old = previous[key] { positions[key] = old }
        }
        for key in keys.sorted() where positions[key] == nil {
            let neighbors = orderedBridges.compactMap { bridge, value -> (Point, Double)? in
                let other = bridge.source == key ? bridge.target : (bridge.target == key ? bridge.source : "")
                guard !other.isEmpty, let point = positions[other] else { return nil }
                return (point, max(0.01, value.weight))
            }
            if neighbors.isEmpty {
                positions[key] = (fallbackCenter + hashDirection(key) * radius).bounded()
            } else {
                let total = neighbors.reduce(0) { $0 + $1.1 }
                let center = neighbors.reduce(Point.zero) { $0 + $1.0 * ($1.1 / total) }
                positions[key] = (center + hashDirection(key) * (radius * 0.28)).bounded()
            }
        }
        // On a first projection, lightly pull connected communities toward one
        // another while retaining a strong deterministic spatial anchor.
        if previous.isEmpty {
            let anchors = positions
            for _ in 0..<12 {
                var next = positions
                for key in keys.sorted() {
                    let neighbors = orderedBridges.compactMap { bridge, value -> (Point, Double)? in
                        let other = bridge.source == key ? bridge.target : (bridge.target == key ? bridge.source : "")
                        guard !other.isEmpty, let point = positions[other] else { return nil }
                        return (point, max(0.01, value.weight))
                    }
                    guard !neighbors.isEmpty else { continue }
                    let total = neighbors.reduce(0) { $0 + $1.1 }
                    let average = neighbors.reduce(Point.zero) { $0 + $1.0 * ($1.1 / total) }
                    next[key] = (anchors[key]! * 0.76 + average * 0.24).bounded()
                }
                positions = next
            }
        }
        return positions
    }

    private static func positions(_ aggregates: [PreviousAggregate]?) -> [String: Point] {
        Dictionary(uniqueKeysWithValues: (aggregates ?? []).compactMap {
            guard let x = $0.x, let y = $0.y, let z = $0.z else { return nil }
            return ($0.stableKey, Point(x: x, y: y, z: z))
        })
    }

    private static func point(_ node: PreviousNode) -> Point? {
        guard let x = node.x, let y = node.y, let z = node.z else { return nil }
        return Point(x: x, y: y, z: z)
    }

    private static func dominantCode(_ codes: [String]) -> String {
        let usable = codes.filter { !$0.isEmpty && $0 != "000" }
        let counts = Dictionary(grouping: usable, by: { $0 }).mapValues(\.count)
        return counts.max {
            $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
        }?.key ?? ""
    }

    private static func hashDirection(_ value: String) -> Point {
        func unit(_ salt: String) -> Double {
            Double(fnv1a(value + salt) & 0xffff) / 32_767.5 - 1
        }
        var x = unit("x"), y = unit("y"), z = unit("z")
        let length = sqrt(x * x + y * y + z * z)
        if length < 0.000_001 { x = 1; y = 0; z = 0 }
        else { x /= length; y /= length; z /= length }
        // A restrained brain-like ellipsoid, with no viewport-dependent scale.
        return Point(x: x * 0.98, y: y * 0.76, z: z * 0.80)
    }

    private static func fnv1a(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    private static func hex(_ value: UInt64) -> String {
        String(value, radix: 16, uppercase: false)
    }
}
