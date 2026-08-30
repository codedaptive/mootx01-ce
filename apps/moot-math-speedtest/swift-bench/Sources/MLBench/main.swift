// MLBench/main.swift
//
// SubstrateML algorithm benchmark sweep. Measures per-(algorithm,
// size, params) latency for the 15 SubstrateML algorithms plus the
// GLK matrix_decayed_projection maintenance pass and the §8.3
// qid_adjacency BFS distance (17 total) — the
// cold-path / dreaming-daemon math — and emits structured JSON.
//
// Swift mirror of rust/src/bin/ml_bench.rs.
//
// Schema: ml-1. See apps/moot-math-speedtest/SCHEMA.md.

import Foundation
import Harness
import SubstrateTypes
import SubstrateML
import GeniusLocusKit

let DEFAULT_SEED: UInt64 = 0xCAFEBABEDEADBEEF
let WARMUP_FULL_NS: UInt64 = 50_000_000   // 50 ms
let MEASURE_FULL_NS: UInt64 = 200_000_000  // 200 ms
let WARMUP_QUICK_NS: UInt64 = 5_000_000    // 5 ms
let MEASURE_QUICK_NS: UInt64 = 20_000_000  // 20 ms

struct Measurement {
    let algorithm: String
    let params: String
    let iterations: Int
    let nsPerCallMin: UInt64
    let nsPerCallMean: UInt64
    let nsPerCallStddev: UInt64
}

func timeLoop(warmupNs: UInt64, measureNs: UInt64, _ body: () -> Void) -> (Int, UInt64, UInt64, UInt64) {
    let clock = ContinuousClock()
    let warmupEnd = DispatchTime.now().uptimeNanoseconds + warmupNs
    while DispatchTime.now().uptimeNanoseconds < warmupEnd { body() }
    // DispatchTime can return the same tick around sub-50 ns operations. Choose
    // a per-sample batch large enough to cross a 10 µs timing floor, then divide
    // back to ns/call. This removes invalid zero-duration cells without changing
    // the operation grid.
    var callsPerSample = 1
    while callsPerSample < 1_048_576 {
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<callsPerSample { body() }
        if DispatchTime.now().uptimeNanoseconds - t0 >= 10_000 { break }
        callsPerSample *= 2
    }
    let measureEnd = DispatchTime.now().uptimeNanoseconds + measureNs
    var samples: [UInt64] = []
    samples.reserveCapacity(1024)
    while DispatchTime.now().uptimeNanoseconds < measureEnd {
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<callsPerSample { body() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - t0
        let divisor = UInt64(callsPerSample)
        samples.append((elapsed + divisor - 1) / divisor)
    }
    let n = samples.count
    if n == 0 { return (0, 0, 0, 0) }
    let mn = samples.min()!
    let sum = samples.reduce(UInt64(0), +)
    let mean = sum / UInt64(n)
    var sq: UInt64 = 0
    for s in samples {
        let d = s > mean ? s - mean : mean - s
        sq &+= d &* d
    }
    let stddev = UInt64(Double(sq / UInt64(n)).squareRoot())
    _ = clock
    return (n * callsPerSample, mn, mean, stddev)
}

func make(_ algo: String, _ params: String, _ t: (Int, UInt64, UInt64, UInt64)) -> Measurement {
    return Measurement(algorithm: algo, params: params, iterations: t.0,
                       nsPerCallMin: t.1, nsPerCallMean: t.2, nsPerCallStddev: t.3)
}

/// Prevent optimized builds from deleting pure benchmark work whose return
/// value is otherwise unused. `_ = operation()` produced invalid 0 ns cells.
nonisolated(unsafe) var blackHoleSink: UInt8 = 0

@inline(never)
@_optimize(none)
func blackHole<T>(_ value: T) {
    withUnsafeBytes(of: value) { bytes in
        if let first = bytes.first { blackHoleSink ^= first }
    }
    _fixLifetime(value)
}

// SplitMix64 — match the Rust port's PRNG so seeds reproduce
struct SplitMix64SW {
    var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextF32() -> Float32 { Float32(next() >> 32) / Float32(UInt32.max) }
    mutating func nextF64() -> Double  { Double(next()) / Double(UInt64.max) }
}

// ---------- per-algorithm measure functions ----------

func measureAnomaly(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for n in [100, 1_000, 10_000, 100_000] {
        var window: [Float32] = []
        window.reserveCapacity(n)
        for _ in 0..<n { window.append(rng.nextF32()) }
        let current = rng.nextF32()
        var t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(AnomalyDetection.rollingZScore(window: window, current: current)) }
        out.append(make("anomaly_z_score", "n=\(n)", t))
        t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(AnomalyDetection.rollingModifiedZScore(window: window, current: current)) }
        out.append(make("anomaly_modified_z_score", "n=\(n)", t))
    }
    return out
}

func measureBradleyTerry(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for nItems in [10, 100, 1_000] {
        var ids: [UUID] = []
        for _ in 0..<nItems {
            var bytes: [UInt8] = []
            for _ in 0..<2 {
                let v = rng.next()
                withUnsafeBytes(of: v) { bytes.append(contentsOf: $0) }
            }
            let uuid = UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                                   bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
            ids.append(uuid)
        }
        let batchSize = min(nItems, 50)
        var obs: [PreferenceObservation] = []
        for i in 0..<batchSize {
            obs.append(PreferenceObservation(winnerID: ids[i % nItems],
                                              losers: [ids[(i + 1) % nItems], ids[(i + 2) % nItems]]))
        }
        var est = BradleyTerryEstimator(learningRate: 0.1, l2: 0.001)
        let single = obs[0]
        let t1 = timeLoop(warmupNs: wu, measureNs: me) { est.observe(single) }
        out.append(make("bradley_terry_observe", "items=\(nItems)", t1))
        var est2 = BradleyTerryEstimator(learningRate: 0.1, l2: 0.001)
        let t2 = timeLoop(warmupNs: wu, measureNs: me) { est2.observeBatch(obs) }
        out.append(make("bradley_terry_observe_batch", "items=\(nItems),batch=\(obs.count)", t2))
    }
    return out
}

func buildAdjacency(_ rng: inout SplitMix64SW, n: Int) -> [[(neighbor: Int, weight: Double)]] {
    var adj: [[(neighbor: Int, weight: Double)]] = []
    for i in 0..<n {
        let ec = 3 + Int(rng.next() % 4)
        var edges: [(neighbor: Int, weight: Double)] = []
        for _ in 0..<ec {
            let dst = (Int(truncatingIfNeeded: rng.next() % UInt64(n)))
            let w = 0.1 + rng.nextF64() * 5.0
            if dst != i { edges.append((neighbor: dst, weight: w)) }
        }
        adj.append(edges)
    }
    return adj
}

func measureCommunityDetection(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for n in [50, 200, 1_000] {
        let adj = buildAdjacency(&rng, n: n)
        let t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(CommunityDetection.detect(adjacency: adj, maxPasses: 10, estate: "bench", ts: 0)) }
        out.append(make("community_detection", "n=\(n)", t))
    }
    return out
}

func measureCompositeDistance(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    let t = timeLoop(warmupNs: wu, measureNs: me) {
        blackHole(CompositeDistance.distance(latticeDistance: 0.42, fingerprintHammingDistance: 73,
                                             alphaLattice: 0.6, alphaFingerprint: 0.4, compatibleSeedScope: true))
    }
    return [make("composite_distance", "single_call", t)]
}

func measureEigenvalueCentrality(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for n in [50, 200, 1_000] {
        let adj = buildAdjacency(&rng, n: n)
        let t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(EigenvalueCentrality.compute(adjacency: adj, maxIterations: 100, tolerance: 1e-6, estate: "bench", ts: 0)) }
        out.append(make("eigenvalue_centrality", "n=\(n)", t))
    }
    return out
}

func measureFeatureExtractors(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    let seedBytes = [UInt8](repeating: 0, count: 32)
    let f0 = HyperplaneFamily.generate(seed: seedBytes, blockIndex: 0, inputBitLength: 64, density: 0.5)
    let f1 = HyperplaneFamily.generate(seed: seedBytes, blockIndex: 1, inputBitLength: 64, density: 0.5)
    let f2 = HyperplaneFamily.generate(seed: seedBytes, blockIndex: 2, inputBitLength: 64, density: 0.5)
    let f3 = HyperplaneFamily.generate(seed: seedBytes, blockIndex: 3, inputBitLength: 64, density: 0.5)
    let hyperplanes: [HyperplaneFamily] = [f0, f1, f2, f3]
    let hlc = HLC(physicalTime: 1_700_000_000_000, logicalCount: 0, nodeID: 1)
    let hkExt = HealthKitExtractor(hyperplanes: hyperplanes)
    let hkSample = HealthKitSample(quantityType: "stepCount", value: 8500.0, unit: "count",
                                    startDate: 1_700_000_000.0,
                                    endDate: 1_700_003_600.0,
                                    sourceDevice: "iPhone")
    let rowID = UUID()
    let t1 = timeLoop(warmupNs: wu, measureNs: me) { blackHole(hkExt.extract(hkSample, hlc: hlc, rowId: rowID)) }
    out.append(make("feature_extractor_healthkit", "single_sample", t1))
    let clExt = CoreLocationExtractor(hyperplanes: hyperplanes)
    let clSample = CoreLocationSample(latitude: 37.7749, longitude: -122.4194, altitude: 16.0,
                                       speed: 0.0, course: 0.0,
                                       timestamp: 1_700_000_000.0,
                                       horizontalAccuracy: 5.0)
    let t2 = timeLoop(warmupNs: wu, measureNs: me) { blackHole(clExt.extract(clSample, hlc: hlc, rowId: rowID)) }
    out.append(make("feature_extractor_corelocation", "single_sample", t2))
    return out
}

func measureFFT(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for n in [64, 256, 1024, 4096, 16384] {
        var input: [Double] = []
        input.reserveCapacity(n)
        for i in 0..<n { input.append(sin(Double(i) * 0.1)) }
        let t1 = timeLoop(warmupNs: wu, measureNs: me) { blackHole(FFT.forward(real: input)) }
        out.append(make("fft_forward", "n=\(n)", t1))
        let t2 = timeLoop(warmupNs: wu, measureNs: me) { blackHole(FFT.magnitudeSpectrum(real: input)) }
        out.append(make("fft_magnitude_spectrum", "n=\(n)", t2))
    }
    return out
}

func measureFloatSimHash(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for dim in [128, 384, 768, 1536] {
        var vec: [Float] = []
        vec.reserveCapacity(dim)
        for _ in 0..<dim { vec.append(rng.nextF32() * 2.0 - 1.0) }
        let t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(FloatSimHash.project(vector: vec, seed: DEFAULT_SEED)) }
        out.append(make("float_simhash_project", "dim=\(dim)", t))
    }
    return out
}

func measureInfoTheory(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for k in [64, 256, 1024] {
        func makeDist() -> [Float32] {
            var raw: [Float32] = []
            for _ in 0..<k { raw.append(rng.nextF32()) }
            let s = raw.reduce(Float32(0), +)
            return raw.map { $0 / s }
        }
        let p = makeDist()
        let q = makeDist()
        var t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(InformationTheory.entropy(p)) }
        out.append(make("info_theory_entropy", "k=\(k)", t))
        t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(InformationTheory.klDivergence(p, q)) }
        out.append(make("info_theory_kl", "k=\(k)", t))
        t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(InformationTheory.crossEntropy(p, q)) }
        out.append(make("info_theory_cross_entropy", "k=\(k)", t))
        let side = Int(Double(k).squareRoot())
        var joint: [[Float32]] = []
        for _ in 0..<side {
            var row: [Float32] = []
            for _ in 0..<side { row.append(rng.nextF32()) }
            joint.append(row)
        }
        let total = joint.flatMap{$0}.reduce(Float32(0), +)
        joint = joint.map { $0.map { $0 / total } }
        t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(InformationTheory.mutualInformation(joint: joint)) }
        out.append(make("info_theory_mi", "k=\(k)", t))
    }
    return out
}

func measureLatticeDistance(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    let pairs: [(String, String)] = [
        ("003", "004"),
        ("003.13", "003.14"),
        ("003.13.5.2", "003.13.5.7"),
        ("003.13.5.2.1.4.7.9", "003.13.5.2.1.4.7.8"),
    ]
    for (a, b) in pairs {
        let t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(UDCTreeDistance.distance(a, b)) }
        out.append(make("lattice_distance_udc", "len=\(a.count)", t))
    }
    return out
}

func measureLLMCalibration(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for nObs in [100, 1_000, 10_000] {
        var curve = LLMCalibrationCurve()
        var local = SplitMix64SW(seed: DEFAULT_SEED)
        for _ in 0..<nObs {
            curve.observe(claimedConfidence: local.nextF32(), actualOutcome: local.next() & 1 == 0)
        }
        var t = timeLoop(warmupNs: wu, measureNs: me) { curve.observe(claimedConfidence: 0.75, actualOutcome: true) }
        out.append(make("llm_calibration_observe", "warm_obs=\(nObs)", t))
        t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(curve.expectedCalibrationError()) }
        out.append(make("llm_calibration_ece", "warm_obs=\(nObs)", t))
        t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(curve.brierScore()) }
        out.append(make("llm_calibration_brier", "warm_obs=\(nObs)", t))
    }
    return out
}

func measureMomentSummary(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for nRows in [100, 1_000, 10_000, 100_000] {
        // Build [RowLite] — same shape as Rust port for fair
        // cross-leg comparison. The full [Row] overload still
        // exists for production callsites; this bench measures
        // the lightweight path used by the dreaming daemon.
        var rows: [RowLite] = []
        rows.reserveCapacity(nRows)
        for i in 0..<nRows {
            let fp = Fingerprint256(block0: rng.next(), block1: rng.next(), block2: rng.next(), block3: rng.next())
            let hlc = HLC(physicalTime: 1_700_000_000_000 + Int64(i), logicalCount: 0, nodeID: 1)
            rows.append(RowLite(fingerprint: fp, captureHLC: hlc))
        }
        let window = TimeRange(start: HLC(physicalTime: 1_700_000_000_000, logicalCount: 0, nodeID: 1),
                                end:   HLC(physicalTime: 1_700_000_000_000 + Int64(nRows), logicalCount: 0, nodeID: 1))
        let t = timeLoop(warmupNs: wu, measureNs: me) {
            blackHole(MomentSummary.summarize(rows: rows, window: window, activeDuring: MomentSummary.capturedDuring))
        }
        out.append(make("moment_summary", "rows=\(nRows)", t))
    }
    return out
}

func measureNMF(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    let shapes: [(Int, Int)] = [(16, 16), (32, 32), (64, 64), (128, 128)]
    for (m, n) in shapes {
        for rank in [4, 8, 16] {
            if rank >= min(m, n) { continue }
            var localRng = SplitMix64SW(seed: DEFAULT_SEED ^ UInt64(m * 1000 + n * 10 + rank))
            var V: [[Float32]] = []
            for _ in 0..<m {
                var row: [Float32] = []
                for _ in 0..<n { row.append(localRng.nextF32()) }
                V.append(row)
            }
            let t = timeLoop(warmupNs: wu, measureNs: me) {
                blackHole(NMFAlternatingLeastSquares.factorize(V: V, rank: rank, maxIterations: 25, tolerance: 1e-4, seed: DEFAULT_SEED))
            }
            out.append(make("nmf_factorize", "m=\(m),n=\(n),rank=\(rank)", t))
        }
    }
    return out
}

func measureRandomWalks(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for n in [100, 1_000, 10_000] {
        let adj = buildAdjacency(&rng, n: n)
        for length in [50, 200] {
            let t = timeLoop(warmupNs: wu, measureNs: me) {
                blackHole(RandomWalks.walk(adjacency: adj, start: 0, length: length, restartProb: 0.15, seed: DEFAULT_SEED))
            }
            out.append(make("random_walks_walk", "n=\(n),length=\(length)", t))
        }
    }
    return out
}

func measureTemporalCompression(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    var out: [Measurement] = []
    for nRows in [100, 1_000, 10_000] {
        var rows: [Fingerprint256] = []
        for _ in 0..<nRows {
            rows.append(Fingerprint256(block0: rng.next(), block1: rng.next(), block2: rng.next(), block3: rng.next()))
        }
        let start = HLC(physicalTime: 1_700_000_000_000, logicalCount: 0, nodeID: 1)
        let end = HLC(physicalTime: 1_700_000_000_000 + 3600, logicalCount: 0, nodeID: 1)
        let t = timeLoop(warmupNs: wu, measureNs: me) { blackHole(TemporalCompression.compress(rows: rows, startHLC: start, endHLC: end, level: .hour)) }
        out.append(make("temporal_compression_compress", "rows=\(nRows)", t))
    }
    return out
}

func measureQIDAdjacency(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    // §8.3 Q-ID adjacency (Wikidata graph) distance — depth-4 BFS over
    // an adjacency provider (canonical primitive qid_adjacency, S8
    // wave). Synthetic connected graph (spanning tree + n extra edges,
    // symmetrized — the same construction the harness vectors use);
    // one random pair per size. Cost is bounded by the depth-4
    // frontier, so this measures BFS fan-out at graded densities, not
    // whole-graph scans.
    struct MapAdjacency: WikidataAdjacencyProvider {
        let adj: [UInt64: Set<UInt64>]
        func neighbors(of qid: UInt64) -> Set<UInt64> { adj[qid] ?? [] }
    }
    var out: [Measurement] = []
    for n in [100, 1_000, 10_000] {
        var adj: [UInt64: Set<UInt64>] = [:]
        for k in 1...n { adj[UInt64(k)] = [] }
        for k in 2...n {
            let p = UInt64(1 + Int(rng.next() % UInt64(k - 1)))
            adj[UInt64(k)]!.insert(p)
            adj[p]!.insert(UInt64(k))
        }
        for _ in 0..<n {
            let u = UInt64(1 + Int(rng.next() % UInt64(n)))
            let v = UInt64(1 + Int(rng.next() % UInt64(n)))
            if u != v {
                adj[u]!.insert(v)
                adj[v]!.insert(u)
            }
        }
        let provider = MapAdjacency(adj: adj)
        let a = UInt64(1 + Int(rng.next() % UInt64(n)))
        let b = UInt64(1 + Int(rng.next() % UInt64(n)))
        let t = timeLoop(warmupNs: wu, measureNs: me) {
            blackHole(WikidataGraphDistance.distance(from: a, to: b, provider: provider))
        }
        out.append(make("qid_adjacency_distance", "n=\(n)", t))
    }
    return out
}

func measureMatrixDecayedProjection(_ rng: inout SplitMix64SW, _ wu: UInt64, _ me: UInt64) -> [Measurement] {
    // S4-C decayed matrix projections (W2.5): the per-entry
    // exp(−age·ln2/τ) FULL-recompute pass that runs in every matrix-tier
    // maintenance cycle — O(audit log) by design (fp non-associativity
    // forbids incremental decay). Graded log sizes characterize the
    // maintenance cost as estates grow. Synthetic log: one capture
    // bundle every 15 minutes, 4 bitmap-field entries per bundle, ages
    // spread so decay weights vary; nowMs is one day past the last
    // bundle. The 15-minute spacing keeps a CONSTANT ~17 bundles inside
    // the 256-minute temporal-causality fold window, so cells scale
    // linearly with log size (the production question). Denser spacing
    // multiplies window pairing, not log-size scaling — a 1-minute
    // spacing made the 100k cell run for minutes per call.
    var out: [Measurement] = []
    for nEntries in [1_000, 10_000, 100_000] {
        let bundles = nEntries / 4
        var entries: [UnifiedAuditEntry] = []
        entries.reserveCapacity(nEntries)
        let baseMs: Int64 = 1_700_000_000_000
        let fields = ["bitmap.adjective", "bitmap.operational", "bitmap.temporal", "bitmap.provenance"]
        for b in 0..<bundles {
            let w0 = rng.next(), w1 = rng.next()
            var bytes = [UInt8](repeating: 0, count: 16)
            for j in 0..<8 {
                bytes[j] = UInt8((w0 >> (UInt64(j) * 8)) & 0xFF)
                bytes[8 + j] = UInt8((w1 >> (UInt64(j) * 8)) & 0xFF)
            }
            let row = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                                  bytes[4], bytes[5], bytes[6], bytes[7],
                                  bytes[8], bytes[9], bytes[10], bytes[11],
                                  bytes[12], bytes[13], bytes[14], bytes[15]))
            let at = HLC(physicalTime: baseMs + Int64(b) * 900_000, logicalCount: 0, nodeID: 1)
            for field in fields {
                // |1 keeps every bitmap non-zero so each entry yields a coordinate.
                entries.append(UnifiedAuditEntry(
                    tier: .locus, hlc: at, verb: .capture, rowID: row,
                    fieldPath: field, beforeValue: .null,
                    afterValue: .bitmap(rng.next() | 1)))
            }
        }
        let log = UnifiedAuditLog(entries: entries)
        let nowMs = baseMs + Int64(bundles) * 900_000 + 86_400_000
        var t = timeLoop(warmupNs: wu, measureNs: me) {
            blackHole(MatrixTier.decayedCoOccurrence(from: log, nowMs: nowMs))
        }
        out.append(make("matrix_decayed_co_occurrence", "entries=\(nEntries)", t))
        t = timeLoop(warmupNs: wu, measureNs: me) {
            blackHole(MatrixTier.rebuildTemporal(from: log, decayNowMs: nowMs))
        }
        out.append(make("matrix_rebuild_temporal_decayed", "entries=\(nEntries)", t))
    }
    return out
}

// ---------- JSON output ----------

func writeReport(out: URL, seed: UInt64, quick: Bool, measurements: [Measurement]) throws {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.timeZone = TimeZone(identifier: "UTC")
    let date = df.string(from: Date())
    let hw = Hardware.tag()
    let (warmupMs, measureMs) = quick ? (5, 20) : (50, 200)
    var s = ""
    s += "{\n"
    s += "  \"schema_version\": \"ml-1\",\n"
    s += "  \"language\": \"swift\",\n"
    s += "  \"op\": \"substrate_ml\",\n"
    s += "  \"date\": \"\(date)\",\n"
    s += "  \"hardware_tag\": \"\(hw)\",\n"
    s += "  \"seed\": \"0x\(String(seed, radix: 16, uppercase: false).padded(to: 16))\",\n"
    s += "  \"timing\": {\n"
    s += "    \"warmup_ms\": \(warmupMs),\n"
    s += "    \"measure_ms\": \(measureMs),\n"
    s += "    \"quick_mode\": \(quick ? "true" : "false")\n"
    s += "  },\n"
    s += "  \"measurements\": [\n"
    for (i, m) in measurements.enumerated() {
        let comma = i + 1 < measurements.count ? "," : ""
        s += "    { \"algorithm\": \"\(m.algorithm)\", \"params\": \"\(m.params)\", \"iterations\": \(m.iterations), \"ns_per_call_min\": \(m.nsPerCallMin), \"ns_per_call_mean\": \(m.nsPerCallMean), \"ns_per_call_stddev\": \(m.nsPerCallStddev) }\(comma)\n"
    }
    s += "  ]\n"
    s += "}\n"
    try s.write(to: out, atomically: true, encoding: .utf8)
}

extension String {
    func padded(to len: Int) -> String {
        if self.count >= len { return self }
        return String(repeating: "0", count: len - self.count) + self
    }
}

// ---------- CLI ----------

func usage() -> Never {
    FileHandle.standardError.write("usage: ml-bench [--seed <0xhex>] [--algorithm <name>] [--out <path>] [--quick]\n".data(using: .utf8)!)
    exit(2)
}

func parseSeed(_ s: String) -> UInt64 {
    let stripped = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
    guard let v = UInt64(stripped, radix: 16) else { FileHandle.standardError.write("bad seed: \(s)\n".data(using: .utf8)!); exit(2) }
    return v
}

let args = Array(CommandLine.arguments.dropFirst())
var seed = DEFAULT_SEED
var algorithm: String? = nil
var outArg: String? = nil
var quick = false
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--seed":     i += 1; seed = parseSeed(args[i])
    case "--algorithm": i += 1; algorithm = args[i]
    case "--out":       i += 1; outArg = args[i]
    case "--quick":     quick = true
    case "--help", "-h": usage()
    default: FileHandle.standardError.write("unknown arg: \(arg)\n".data(using: .utf8)!); usage()
    }
    i += 1
}

let want = algorithm ?? "all"
let wu = quick ? WARMUP_QUICK_NS : WARMUP_FULL_NS
let me = quick ? MEASURE_QUICK_NS : MEASURE_FULL_NS

print("ml-bench (Swift) seed=0x\(String(seed, radix: 16)) algorithm=\(want) \(quick ? "[quick]" : "")")

var rng = SplitMix64SW(seed: seed)
var all: [Measurement] = []
let wantAll = want == "all"

@MainActor func runIf(_ name: String, _ fn: (inout SplitMix64SW, UInt64, UInt64) -> [Measurement]) {
    if wantAll || want == name {
        let ms = fn(&rng, wu, me)
        for m in ms {
            print("  \(m.algorithm.padding(toLength: 32, withPad: " ", startingAt: 0)) \(m.params.padding(toLength: 40, withPad: " ", startingAt: 0)) min=\(String(format: "%10llu", m.nsPerCallMin))ns iters=\(m.iterations)")
        }
        all.append(contentsOf: ms)
    }
}

runIf("anomaly", measureAnomaly)
runIf("bradley_terry", measureBradleyTerry)
runIf("community_detection", measureCommunityDetection)
runIf("composite_distance", measureCompositeDistance)
runIf("eigenvalue_centrality", measureEigenvalueCentrality)
runIf("feature_extractors", measureFeatureExtractors)
runIf("fft", measureFFT)
runIf("float_simhash", measureFloatSimHash)
runIf("info_theory", measureInfoTheory)
runIf("lattice_distance", measureLatticeDistance)
runIf("llm_calibration", measureLLMCalibration)
runIf("moment_summary", measureMomentSummary)
runIf("nmf", measureNMF)
runIf("random_walks", measureRandomWalks)
runIf("temporal_compression", measureTemporalCompression)
runIf("qid_adjacency", measureQIDAdjacency)
runIf("matrix_decayed_projection", measureMatrixDecayedProjection)

let df = DateFormatter()
df.dateFormat = "yyyy-MM-dd"
df.timeZone = TimeZone(identifier: "UTC")
let date = df.string(from: Date())
let hw = Hardware.tag()

let out: URL
if let oa = outArg {
    var url = URL(fileURLWithPath: oa)
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    if (exists && isDir.boolValue) || url.pathExtension.isEmpty {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        url = url.appendingPathComponent("substrate_ml-swift.json")
    }
    out = url
} else {
    let dir = URL(fileURLWithPath: "results/\(date)-\(hw)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    out = dir.appendingPathComponent("substrate_ml-swift.json")
}

try writeReport(out: out, seed: seed, quick: quick, measurements: all)
print("")
print("  wrote \(out.path)")
