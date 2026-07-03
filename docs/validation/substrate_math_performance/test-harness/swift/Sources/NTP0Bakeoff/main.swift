// NTP0Bakeoff/main.swift
//
// Executable bakeoff runner for NT-P0 Merkle/commitment math.
// Measures the actual in-repo SubstrateKernel SHA-256, HMAC-backed
// keyed commitment, Apple platform crypto where available, and
// Merkle root APIs.

import Foundation
import Harness
import PlatformCryptoCandidate
import SubstrateKernel
import SubstrateTypes

nonisolated(unsafe) var sink: UInt64 = 0

struct PayloadCase {
    let name: String
    let shaPayload: [UInt8]
    let leafPayload: [UInt8]
}

struct MeasureStats {
    let coldUs: Double
    let p50Us: Double
    let p95Us: Double
    let p99Us: Double
    let samples: Int
    let opsPerSample: Int
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let ordered = values.sorted()
    let raw = Int(ceil((p / 100.0) * Double(ordered.count))) - 1
    let idx = min(ordered.count - 1, max(0, raw))
    return ordered[idx]
}

@inline(never)
func digestWord(_ bytes: [UInt8]) -> UInt64 {
    var out: UInt64 = 0
    let n = min(8, bytes.count)
    for i in 0..<n {
        out |= UInt64(bytes[i]) << UInt64(i * 8)
    }
    return out
}

func keyedCommitmentInput(forCanonicalLeafPayload payload: [UInt8]) -> [UInt8] {
    var committed = [UInt8]()
    committed.reserveCapacity(1 + payload.count)
    committed.append(MerkleCommitment.DomainTag.keyedCommitment)
    committed.append(contentsOf: payload)
    return committed
}

func measure(samples: Int = 41, opsPerSample: Int, _ body: () -> UInt64) -> MeasureStats {
    let coldStart = DispatchTime.now().uptimeNanoseconds
    sink ^= body()
    let coldEnd = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<3 {
        sink ^= body()
    }

    var times = [Double]()
    times.reserveCapacity(samples)
    for _ in 0..<samples {
        var local: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<opsPerSample {
            local ^= body()
        }
        let end = DispatchTime.now().uptimeNanoseconds
        sink ^= local
        times.append(Double(end - start) / Double(opsPerSample) / 1_000.0)
    }

    return MeasureStats(
        coldUs: Double(coldEnd - coldStart) / 1_000.0,
        p50Us: percentile(times, 50),
        p95Us: percentile(times, 95),
        p99Us: percentile(times, 99),
        samples: samples,
        opsPerSample: opsPerSample)
}

func statsJSON(_ stats: MeasureStats) -> [String: Any] {
    [
        "cold_us": stats.coldUs,
        "p50_us": stats.p50Us,
        "p95_us": stats.p95Us,
        "p99_us": stats.p99Us,
        "samples": stats.samples,
        "ops_per_sample": stats.opsPerSample,
    ]
}

func bytes(count: Int, seed: UInt64) -> [UInt8] {
    var state = seed
    var out = [UInt8]()
    out.reserveCapacity(count)
    while out.count < count {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        for shift in stride(from: 0, through: 56, by: 8) where out.count < count {
            out.append(UInt8((z >> UInt64(shift)) & 0xFF))
        }
    }
    return out
}

func uuidBytes(_ byte: UInt8) -> [UInt8] {
    [UInt8](repeating: byte, count: 16)
}

func vectorPayloads(recordCount: Int, dimension: Int) -> [MerkleVectorPayload] {
    var out = [MerkleVectorPayload]()
    out.reserveCapacity(recordCount)
    for i in 0..<recordCount {
        let model = i % 2 == 0 ? "alpha-v1" : "zeta-v1"
        var values = [Float32]()
        values.reserveCapacity(dimension)
        for j in 0..<dimension {
            let raw = Float32(((i + 1) * (j + 3)) % 97)
            values.append((raw - 48.0) / 97.0)
        }
        out.append(MerkleVectorPayload(modelID: model, vectorIndex: UInt32(recordCount - i), values: values))
    }
    return out
}

func leafPayload(totalApproxBytes: Int, drawerByte: UInt8) -> [UInt8] {
    let fixed = 1 + 16 + 8 + 4
    let contentSize = max(0, totalApproxBytes - fixed)
    return MerkleCommitment.canonicalLeafPayload(
        drawerIDBytes: uuidBytes(drawerByte),
        contentNFCUTF8: bytes(count: contentSize, seed: UInt64(drawerByte)),
        vectors: [])
}

func vectorHeavyLeafPayload() -> [UInt8] {
    MerkleCommitment.canonicalLeafPayload(
        drawerIDBytes: uuidBytes(0x44),
        contentNFCUTF8: bytes(count: 512, seed: 0x44),
        vectors: vectorPayloads(recordCount: 32, dimension: 128))
}

func makePayloadCases() -> [PayloadCase] {
    [
        PayloadCase(name: "256B", shaPayload: bytes(count: 256, seed: 1), leafPayload: leafPayload(totalApproxBytes: 256, drawerByte: 0x11)),
        PayloadCase(name: "4KB", shaPayload: bytes(count: 4_096, seed: 2), leafPayload: leafPayload(totalApproxBytes: 4_096, drawerByte: 0x22)),
        PayloadCase(name: "64KB", shaPayload: bytes(count: 65_536, seed: 3), leafPayload: leafPayload(totalApproxBytes: 65_536, drawerByte: 0x33)),
        PayloadCase(name: "vector_heavy", shaPayload: vectorHeavyLeafPayload(), leafPayload: vectorHeavyLeafPayload()),
    ]
}

func opsPerSample(for bytes: Int) -> Int {
    if bytes <= 512 { return 1_000 }
    if bytes <= 4_096 { return 250 }
    if bytes <= 20_000 { return 80 }
    return 25
}

func b1Throughput() -> [[String: Any]] {
    let key = Array("nt-p0 measurement key".utf8)
    // Hoist the SymmetricKey creation out of the measurement loop.
    // Production code creates the estate key once and reuses it;
    // measuring key creation per-call inflated 256B HMAC timings
    // by ~2.4x due to allocation overhead (Codex/Sonnet divergence).
    let platformKey = PlatformCryptoCandidate.isAvailable
        ? PlatformCryptoCandidate.makeSymmetricKey(key) : nil
    return makePayloadCases().map { payload in
        let shaOps = opsPerSample(for: payload.shaPayload.count)
        let hmacOps = opsPerSample(for: payload.leafPayload.count)
        let sha = measure(opsPerSample: shaOps) {
            digestWord(SHA256.hash(payload.shaPayload))
        }
        let hmac = measure(opsPerSample: hmacOps) {
            digestWord(MerkleCommitment.keyedCommitment(
                forCanonicalLeafPayload: payload.leafPayload,
                key: key,
                keyVersion: 1).wireBytes)
        }

        var row: [String: Any] = [
            "payload": payload.name,
            "sha_payload_bytes": payload.shaPayload.count,
            "hmac_leaf_payload_bytes": payload.leafPayload.count,
            "sha256_scalar": statsJSON(sha),
            "hmac_scalar": statsJSON(hmac),
            "platform_crypto_available": false,
            "selected_sha_candidate": "sha256_scalar",
            "selected_hmac_candidate": "hmac_scalar",
        ]

        if PlatformCryptoCandidate.isAvailable {
        let scalarSHA = SHA256.hash(payload.shaPayload)
        let platformSHA = PlatformCryptoCandidate.sha256(payload.shaPayload)
        precondition(platformSHA == scalarSHA,
                     "platform SHA256 must byte-equal SubstrateKernel scalar SHA256")

        let commitmentInput = keyedCommitmentInput(forCanonicalLeafPayload: payload.leafPayload)
        let scalarHMAC = MerkleCommitment.keyedCommitment(
            forCanonicalLeafPayload: payload.leafPayload,
            key: key,
            keyVersion: 1).wireBytes
        let platformHMAC = PlatformCryptoCandidate.hmacSHA256(key: key, data: commitmentInput)
        precondition(platformHMAC == scalarHMAC,
                     "platform HMAC-SHA256 must byte-equal GrantHKDF scalar HMAC")

        let platformSHAStats = measure(opsPerSample: shaOps) {
            digestWord(PlatformCryptoCandidate.sha256(payload.shaPayload))
        }
        let platformHMACStats = measure(opsPerSample: hmacOps) {
            digestWord(PlatformCryptoCandidate.hmacSHA256(using: platformKey!, data: commitmentInput))
        }

        let shaSpeedup = sha.p50Us / platformSHAStats.p50Us
        let hmacSpeedup = hmac.p50Us / platformHMACStats.p50Us
        row["platform_crypto_available"] = true
        row["platform_crypto_implementation"] = PlatformCryptoCandidate.implementationName
        row["sha256_platform"] = statsJSON(platformSHAStats)
        row["hmac_platform"] = statsJSON(platformHMACStats)
        row["sha256_platform_conformance"] = "pass"
        row["hmac_platform_conformance"] = "pass"
        row["sha256_platform_speedup_p50"] = shaSpeedup
        row["hmac_platform_speedup_p50"] = hmacSpeedup
        row["selection_rule"] = "select more complex candidate only if p50 improves by at least 20%"
        row["selected_sha_candidate"] = shaSpeedup >= 1.20 ? "sha256_platform" : "sha256_scalar"
        row["selected_hmac_candidate"] = hmacSpeedup >= 1.20 ? "hmac_platform" : "hmac_scalar"
        }

        return row
    }
}

func fixedRoot(_ byte: UInt8) -> MerkleRoot {
    MerkleRoot(unchecked: [UInt8](repeating: byte, count: 32))
}

func children(count: Int, base: UInt8, replacingFirstWith first: MerkleRoot? = nil) -> [MerkleChild] {
    var out = [MerkleChild]()
    out.reserveCapacity(count)
    for i in 0..<count {
        let idByte = UInt8((Int(base) + i) & 0xFF)
        let root = i == 0 ? (first ?? fixedRoot(idByte)) : fixedRoot(idByte)
        out.append(MerkleChild(childID: UUID(uuid: (
            idByte, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, idByte
        )), root: root))
    }
    return out
}

func b2WritePath() -> [[String: Any]] {
    let payloads = (0..<128).map { leafPayload(totalApproxBytes: 4_096, drawerByte: UInt8($0 & 0x7F)) }
    var idx = 0
    let baseline = measure(opsPerSample: 500) {
        let payload = payloads[idx % payloads.count]
        idx &+= 1
        return UInt64(payload.count) ^ UInt64(payload[0])
    }
    idx = 0
    let hashOnly = measure(opsPerSample: 120) {
        let payload = payloads[idx % payloads.count]
        idx &+= 1
        return digestWord(MerkleCommitment.hashLeafPayload(payload).wireBytes)
    }
    idx = 0
    let rollup = measure(opsPerSample: 40) {
        let payload = payloads[idx % payloads.count]
        idx &+= 1
        let leaf = MerkleCommitment.rootForLeafPayload(payload)
        let room = MerkleCommitment.interiorRoot(children: children(count: 16, base: 0x10, replacingFirstWith: leaf))
        let wing = MerkleCommitment.interiorRoot(children: children(count: 8, base: 0x40, replacingFirstWith: room))
        let estate = MerkleCommitment.interiorRoot(children: children(count: 4, base: 0x80, replacingFirstWith: wing))
        return digestWord(estate.wireBytes)
    }
    var rows: [[String: Any]] = [
        ["candidate": "capture_baseline_no_hash", "measurement": statsJSON(baseline)],
        ["candidate": "capture_plus_leaf_hash_scalar", "measurement": statsJSON(hashOnly)],
        ["candidate": "capture_hash_plus_room_wing_estate_rollup_scalar", "measurement": statsJSON(rollup)],
    ]
    if PlatformCryptoCandidate.isAvailable {
        precondition(
            platformRootForLeafPayload(payloads[0]) == MerkleCommitment.rootForLeafPayload(payloads[0]),
            "platform leaf hash must byte-equal scalar leaf hash")
        let platformLeaf = measure(opsPerSample: 120) {
            let payload = payloads[idx % payloads.count]
            idx &+= 1
            return digestWord(platformRootForLeafPayload(payload).wireBytes)
        }
        idx = 0
        let platformRollup = measure(opsPerSample: 80) {
            let payload = payloads[idx % payloads.count]
            idx &+= 1
            let leaf = platformRootForLeafPayload(payload)
            let room = platformRootForChildren(children: children(count: 16, base: 0x10, replacingFirstWith: leaf))
            let wing = platformRootForChildren(children: children(count: 8, base: 0x40, replacingFirstWith: room))
            let estate = platformRootForChildren(children: children(count: 4, base: 0x80, replacingFirstWith: wing))
            return digestWord(estate.wireBytes)
        }
        rows.append([
            "candidate": "capture_plus_leaf_hash_platform",
            "measurement": statsJSON(platformLeaf),
            "conformance": "pass",
            "platform_crypto_implementation": PlatformCryptoCandidate.implementationName,
        ])
        rows.append([
            "candidate": "capture_hash_plus_room_wing_estate_rollup_platform",
            "measurement": statsJSON(platformRollup),
            "conformance": "pass",
            "platform_crypto_implementation": PlatformCryptoCandidate.implementationName,
        ])
    }
    return rows
}

func rootForChildren(_ roots: [MerkleRoot], base: UInt8) -> MerkleRoot {
    let kids = roots.enumerated().map { idx, root in
        MerkleChild(childID: UUID(uuid: (
            UInt8((Int(base) + idx) & 0xFF), 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, UInt8((idx >> 8) & 0xFF), UInt8(idx & 0xFF)
        )), root: root)
    }
    return MerkleCommitment.interiorRoot(children: kids)
}

func platformRootForLeafPayload(_ payload: [UInt8]) -> MerkleRoot {
    precondition(payload.first == MerkleCommitment.DomainTag.leaf,
                 "leaf payload must start with the leaf domain tag")
    return MerkleRoot(unchecked: PlatformCryptoCandidate.sha256(payload))
}

func platformRootForChildren(children: [MerkleChild]) -> MerkleRoot {
    let payload = MerkleCommitment.canonicalInteriorPayload(children: children)
    return MerkleRoot(unchecked: PlatformCryptoCandidate.sha256(payload))
}

func platformRootForChildren(_ roots: [MerkleRoot], base: UInt8) -> MerkleRoot {
    let kids = roots.enumerated().map { idx, root in
        MerkleChild(childID: UUID(uuid: (
            UInt8((Int(base) + idx) & 0xFF), 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, UInt8((idx >> 8) & 0xFF), UInt8(idx & 0xFF)
        )), root: root)
    }
    return platformRootForChildren(children: kids)
}

func initialRoots(_ count: Int) -> [MerkleRoot] {
    (0..<count).map { i in
        MerkleRoot(unchecked: SHA256.hash(bytes(count: 32, seed: UInt64(i + 1000))))
    }
}

func roomRoots(from leaves: [MerkleRoot]) -> [MerkleRoot] {
    var out = [MerkleRoot]()
    out.reserveCapacity(256)
    for room in 0..<256 {
        let start = room * 16
        let end = start + 16
        out.append(rootForChildren(Array(leaves[start..<end]), base: UInt8(room & 0xFF)))
    }
    return out
}

func wingRoots(from rooms: [MerkleRoot]) -> [MerkleRoot] {
    var out = [MerkleRoot]()
    out.reserveCapacity(16)
    for wing in 0..<16 {
        let start = wing * 16
        let end = start + 16
        out.append(rootForChildren(Array(rooms[start..<end]), base: UInt8(wing & 0xFF)))
    }
    return out
}

let baseLeaves4096: [MerkleRoot] = initialRoots(4_096)
let baseRooms4096: [MerkleRoot] = roomRoots(from: baseLeaves4096)
let baseWings4096: [MerkleRoot] = wingRoots(from: baseRooms4096)
let baseShallow1024 = initialRoots(1_024)

func realisticFull(batch: Int) -> UInt64 {
    var leaves = baseLeaves4096
    for i in 0..<batch {
        let leafIndex = (i * 997) % leaves.count
        leaves[leafIndex] = fixedRoot(UInt8(i & 0xFF))
    }
    var rooms = [MerkleRoot]()
    for room in 0..<256 {
        rooms.append(rootForChildren(Array(leaves[(room * 16)..<((room + 1) * 16)]), base: UInt8(room & 0xFF)))
    }
    var wings = [MerkleRoot]()
    for wing in 0..<16 {
        wings.append(rootForChildren(Array(rooms[(wing * 16)..<((wing + 1) * 16)]), base: UInt8(wing & 0xFF)))
    }
    return digestWord(rootForChildren(wings, base: 0xEE).wireBytes)
}

func realisticDirty(batch: Int) -> UInt64 {
    var leaves = baseLeaves4096
    var rooms = baseRooms4096
    var wings = baseWings4096
    var dirtyRooms = Set<Int>()
    var dirtyWings = Set<Int>()
    for i in 0..<batch {
        let leafIndex = (i * 997) % leaves.count
        leaves[leafIndex] = fixedRoot(UInt8(i & 0xFF))
        dirtyRooms.insert(leafIndex / 16)
        dirtyWings.insert(leafIndex / 256)
    }
    for room in dirtyRooms {
        rooms[room] = rootForChildren(Array(leaves[(room * 16)..<((room + 1) * 16)]), base: UInt8(room & 0xFF))
    }
    for wing in dirtyWings {
        wings[wing] = rootForChildren(Array(rooms[(wing * 16)..<((wing + 1) * 16)]), base: UInt8(wing & 0xFF))
    }
    return digestWord(rootForChildren(wings, base: 0xEE).wireBytes)
}

func shallowWide(batch: Int) -> UInt64 {
    var roots = baseShallow1024
    for i in 0..<batch {
        roots[(i * 389) % roots.count] = fixedRoot(UInt8(i & 0xFF))
    }
    return digestWord(rootForChildren(roots, base: 0xAA).wireBytes)
}

func realisticFullPlatform(batch: Int) -> UInt64 {
    var leaves = baseLeaves4096
    for i in 0..<batch {
        let leafIndex = (i * 997) % leaves.count
        leaves[leafIndex] = fixedRoot(UInt8(i & 0xFF))
    }
    var rooms = [MerkleRoot]()
    for room in 0..<256 {
        rooms.append(platformRootForChildren(Array(leaves[(room * 16)..<((room + 1) * 16)]), base: UInt8(room & 0xFF)))
    }
    var wings = [MerkleRoot]()
    for wing in 0..<16 {
        wings.append(platformRootForChildren(Array(rooms[(wing * 16)..<((wing + 1) * 16)]), base: UInt8(wing & 0xFF)))
    }
    return digestWord(platformRootForChildren(wings, base: 0xEE).wireBytes)
}

func realisticDirtyPlatform(batch: Int) -> UInt64 {
    var leaves = baseLeaves4096
    var rooms = baseRooms4096
    var wings = baseWings4096
    var dirtyRooms = Set<Int>()
    var dirtyWings = Set<Int>()
    for i in 0..<batch {
        let leafIndex = (i * 997) % leaves.count
        leaves[leafIndex] = fixedRoot(UInt8(i & 0xFF))
        dirtyRooms.insert(leafIndex / 16)
        dirtyWings.insert(leafIndex / 256)
    }
    for room in dirtyRooms {
        rooms[room] = platformRootForChildren(Array(leaves[(room * 16)..<((room + 1) * 16)]), base: UInt8(room & 0xFF))
    }
    for wing in dirtyWings {
        wings[wing] = platformRootForChildren(Array(rooms[(wing * 16)..<((wing + 1) * 16)]), base: UInt8(wing & 0xFF))
    }
    return digestWord(platformRootForChildren(wings, base: 0xEE).wireBytes)
}

func shallowWidePlatform(batch: Int) -> UInt64 {
    var roots = baseShallow1024
    for i in 0..<batch {
        roots[(i * 389) % roots.count] = fixedRoot(UInt8(i & 0xFF))
    }
    return digestWord(platformRootForChildren(roots, base: 0xAA).wireBytes)
}

func b3Reroot() -> [[String: Any]] {
    var rows = [[String: Any]]()
    for batch in [1, 8, 64, 256] {
        let shallow = measure(samples: 21, opsPerSample: 5) { shallowWide(batch: batch) }
        let full = measure(samples: 21, opsPerSample: 2) { realisticFull(batch: batch) }
        let dirty = measure(samples: 21, opsPerSample: 5) { realisticDirty(batch: batch) }
        rows.append([
            "tree_shape": "shallow_wide_1024",
            "hash_backend": "scalar",
            "batch_size": batch,
            "full_recompute": statsJSON(shallow),
            "dirty_chain_incremental": statsJSON(shallow),
            "note": "single-level root forces the same root recompute for both strategies",
        ])
        rows.append([
            "tree_shape": "realistic_4096_fanout16_room_wing_estate",
            "hash_backend": "scalar",
            "batch_size": batch,
            "full_recompute": statsJSON(full),
            "dirty_chain_incremental": statsJSON(dirty),
        ])
        if PlatformCryptoCandidate.isAvailable {
            precondition(shallowWidePlatform(batch: batch) == shallowWide(batch: batch),
                         "platform shallow reroot must byte-equal scalar reroot")
            precondition(realisticFullPlatform(batch: batch) == realisticFull(batch: batch),
                         "platform full reroot must byte-equal scalar full reroot")
            precondition(realisticDirtyPlatform(batch: batch) == realisticDirty(batch: batch),
                         "platform dirty reroot must byte-equal scalar dirty reroot")
            let shallowPlatform = measure(samples: 21, opsPerSample: 5) { shallowWidePlatform(batch: batch) }
            let fullPlatform = measure(samples: 21, opsPerSample: 5) { realisticFullPlatform(batch: batch) }
            let dirtyPlatform = measure(samples: 21, opsPerSample: 10) { realisticDirtyPlatform(batch: batch) }
            rows.append([
                "tree_shape": "shallow_wide_1024",
                "hash_backend": "platform",
                "platform_crypto_implementation": PlatformCryptoCandidate.implementationName,
                "conformance": "pass",
                "batch_size": batch,
                "full_recompute": statsJSON(shallowPlatform),
                "dirty_chain_incremental": statsJSON(shallowPlatform),
                "note": "single-level root forces the same root recompute for both strategies",
            ])
            rows.append([
                "tree_shape": "realistic_4096_fanout16_room_wing_estate",
                "hash_backend": "platform",
                "platform_crypto_implementation": PlatformCryptoCandidate.implementationName,
                "conformance": "pass",
                "batch_size": batch,
                "full_recompute": statsJSON(fullPlatform),
                "dirty_chain_incremental": statsJSON(dirtyPlatform),
            ])
        }
    }
    return rows
}

func hardwareTag() -> String {
    #if arch(arm64)
    let arch = "arm64"
    #elseif arch(x86_64)
    let arch = "x86_64"
    #else
    let arch = "other"
    #endif
    return "\(ProcessInfo.processInfo.operatingSystemVersionString) \(arch)"
}

func parseOutPath() -> String? {
    let args = CommandLine.arguments
    for i in 1..<args.count where args[i] == "--out" && i + 1 < args.count {
        return args[i + 1]
    }
    return nil
}

let b1Results = b1Throughput()
let b2Results = b2WritePath()
let b3Results = b3Reroot()

let result: [String: Any] = [
    "mission": "NT-P0",
    "generated_at": ISO8601DateFormatter().string(from: Date()),
    "hardware": hardwareTag(),
    "method": [
        "samples": "cold one-shot plus warmed p50/p95/p99 over repeated per-op timings",
        "implementation": "SubstrateKernel SHA256, GrantHKDF HMAC, CryptoKit SHA/HMAC candidate when available, MerkleCommitment roots",
        "build": "swift run -c release nt-p0-bakeoff",
        "sink": String(sink),
    ],
    "b1_sha_hmac_throughput": b1Results,
    "b2_hash_on_write": b2Results,
    "b3_merkle_reroot": b3Results,
]

let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
if let out = parseOutPath() {
    try data.write(to: URL(fileURLWithPath: out), options: .atomic)
    print("wrote \(out)")
} else {
    FileHandle.standardOutput.write(data)
    print("")
}
print("sink \(sink)")
