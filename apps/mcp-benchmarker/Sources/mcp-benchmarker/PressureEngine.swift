import Foundation

// PressureEngine.swift — the `pressure` mode: a synthetic 4-way load driver.
//
// The 4-way measurement is {read, write} × {mootx01, MemPalace} — two
// directions (read / write) across two products. The proxy surfaces these four
// paths from real traffic over time; this driver surfaces the SAME four paths
// synthetically, exercising each under configurable concurrency for a fixed
// duration and reporting throughput (ops/sec) plus latency (mean / p95) per
// path.
//
// The four paths map onto the two configured endpoints' verbMaps:
//   - source endpoint  → MemPalace: read = source.query, write = source.write
//   - target endpoint  → mootx01:   read = target.query, write = target.write
//
// so a single config (the same one transfer/serve use) declares all four. Each
// path's write uses that endpoint's `constantArgs` (mootx01 needs `location`;
// MemPalace needs `wing` + `room`), so a WRITE path must point at a SCRATCH
// backend — never a real DB. The driver does not gate this itself (the config
// author owns the command); CONFIG.md states the scratch requirement plainly.
//
// Each worker loops issuing one op until the deadline, timing every op into its
// path's series; throughput is ops completed / wall-clock seconds elapsed.

/// One of the four pressure paths.
enum PressurePath: String, Sendable, CaseIterable {
    case mootRead = "mootx01.read"
    case mootWrite = "mootx01.write"
    case memoryRead = "mempalace.read"
    case memoryWrite = "mempalace.write"
}

/// Per-path result of a pressure run.
struct PressurePathResult: Sendable {
    let path: String
    let opsCompleted: Int
    let opsFailed: Int
    let wallSeconds: Double
    let meanLatency: Double
    let p95Latency: Double

    /// Completed ops per wall-clock second.
    var throughputPerSecond: Double {
        wallSeconds > 0 ? Double(opsCompleted) / wallSeconds : 0
    }
}

/// The full pressure report across all four paths.
struct PressureReport: Sendable {
    let results: [PressurePathResult]
    let concurrencyPerPath: Int
    let durationSeconds: Double

    /// Human-readable rendering for stdout.
    func rendered() -> String {
        var out = String(format:
            "pressure report — 4-way (concurrency %d/path, %.1fs target)\n",
            concurrencyPerPath, durationSeconds)
        for r in results {
            let label = r.path.padding(toLength: 16, withPad: " ", startingAt: 0)
            out += String(format:
                "  %@ %8.1f ops/s   mean %7.2f ms   p95 %7.2f ms   ok=%d fail=%d\n",
                label as NSString, r.throughputPerSecond,
                r.meanLatency * 1000, r.p95Latency * 1000,
                r.opsCompleted, r.opsFailed)
        }
        return out
    }
}

/// Drives synthetic load across all four read/write × product paths.
struct PressureEngine {
    /// MemPalace-side client + verbs (the config `source` endpoint).
    let memory: MCPClient
    let memoryVerbs: EndpointConfig.VerbMap
    /// mootx01-side client + verbs (the config `target` endpoint).
    let moot: MCPClient
    let mootVerbs: EndpointConfig.VerbMap

    /// Concurrent workers per path. Total in-flight workers = 4 × this.
    let concurrencyPerPath: Int
    /// Target run duration in seconds. Workers stop at the deadline.
    let durationSeconds: Double
    /// The probe text used for read ops and the body of write ops. A fixed
    /// probe keeps the load deterministic and avoids unbounded scratch growth
    /// in content variety (the scratch DB still grows by op count on writes).
    let probeText: String

    /// Optional rolling-stats sink so a pressure run can also feed the standing
    /// stats store (parity with `serve`). Nil for a stdout-only run.
    let stats: RollingStats?

    init(memory: MCPClient,
         memoryVerbs: EndpointConfig.VerbMap,
         moot: MCPClient,
         mootVerbs: EndpointConfig.VerbMap,
         concurrencyPerPath: Int,
         durationSeconds: Double,
         probeText: String = "benchmarker pressure probe",
         stats: RollingStats? = nil) {
        self.memory = memory
        self.memoryVerbs = memoryVerbs
        self.moot = moot
        self.mootVerbs = mootVerbs
        self.concurrencyPerPath = concurrencyPerPath
        self.durationSeconds = durationSeconds
        self.probeText = probeText
        self.stats = stats
    }

    /// Runs the load and returns the per-path report.
    func run(now: @Sendable () -> Date = { Date() }) async throws -> PressureReport {
        let deadline = DispatchTime.now() + durationSeconds

        // Run all four paths concurrently; each returns its own result.
        async let mootR = drivePath(.mootRead, deadline: deadline)
        async let mootW = drivePath(.mootWrite, deadline: deadline)
        async let memR = drivePath(.memoryRead, deadline: deadline)
        async let memW = drivePath(.memoryWrite, deadline: deadline)

        let results = try await [mootR, mootW, memR, memW]
        return PressureReport(results: results,
                              concurrencyPerPath: concurrencyPerPath,
                              durationSeconds: durationSeconds)
    }

    /// Drives one path with `concurrencyPerPath` workers until the deadline,
    /// aggregating latency samples and ok/fail counts across workers.
    private func drivePath(_ path: PressurePath, deadline: DispatchTime) async throws -> PressurePathResult {
        let wallStart = DispatchTime.now()
        // Each worker returns (samples, failures). Collected via a task group so
        // the workers run truly concurrently against the backend.
        let perWorker = try await withThrowingTaskGroup(
            of: (samples: [Double], failures: Int).self
        ) { group in
            for _ in 0..<concurrencyPerPath {
                group.addTask { await self.worker(path, deadline: deadline) }
            }
            var all: [(samples: [Double], failures: Int)] = []
            for try await r in group { all.append(r) }
            return all
        }

        var samples: [Double] = []
        var failures = 0
        for w in perWorker { samples.append(contentsOf: w.samples); failures += w.failures }
        let wallSeconds = Self.elapsedSeconds(since: wallStart)

        return PressurePathResult(
            path: path.rawValue,
            opsCompleted: samples.count,
            opsFailed: failures,
            wallSeconds: wallSeconds,
            meanLatency: samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count),
            p95Latency: Self.p95(of: samples)
        )
    }

    /// One worker: issue ops on `path` until the deadline. Never throws — a
    /// failed op increments the failure count and the worker keeps going, so a
    /// transient backend error does not abort the whole path.
    private func worker(_ path: PressurePath, deadline: DispatchTime) async -> (samples: [Double], failures: Int) {
        var samples: [Double] = []
        var failures = 0
        while DispatchTime.now() < deadline {
            let start = DispatchTime.now()
            do {
                try await issue(path)
                let elapsed = Self.elapsedSeconds(since: start)
                samples.append(elapsed)
                if let stats { await stats.recordLatency(elapsed, label: path.rawValue) }
            } catch {
                failures += 1
            }
        }
        return (samples, failures)
    }

    /// Issues exactly one op on the given path against the right client + verbs.
    private func issue(_ path: PressurePath) async throws {
        switch path {
        case .mootRead:
            _ = try await moot.callTool(mootVerbs.query,
                                        arguments: [mootVerbs.queryArg: .string(probeText)],
                                        format: mootVerbs.resultFormat)
        case .mootWrite:
            _ = try await moot.callTool(mootVerbs.write,
                                        arguments: writeArgs(mootVerbs),
                                        format: mootVerbs.resultFormat)
        case .memoryRead:
            _ = try await memory.callTool(memoryVerbs.query,
                                          arguments: [memoryVerbs.queryArg: .string(probeText)],
                                          format: memoryVerbs.resultFormat)
        case .memoryWrite:
            _ = try await memory.callTool(memoryVerbs.write,
                                          arguments: writeArgs(memoryVerbs),
                                          format: memoryVerbs.resultFormat)
        }
    }

    /// Builds write arguments from a verbMap: the probe content under the
    /// content key plus the endpoint's required constant args (location for
    /// mootx01; wing + room for MemPalace).
    private func writeArgs(_ verbs: EndpointConfig.VerbMap) -> [String: JSONValue] {
        var args: [String: JSONValue] = [verbs.contentArg: .string(probeText)]
        for (k, v) in verbs.constantArgs { args[k] = .string(v) }
        return args
    }

    /// Nearest-rank p95 over a sample set, matching TimingSeries.p95.
    private static func p95(of samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        let index = min(max(rank, 1) - 1, sorted.count - 1)
        return sorted[index]
    }

    private static func elapsedSeconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
