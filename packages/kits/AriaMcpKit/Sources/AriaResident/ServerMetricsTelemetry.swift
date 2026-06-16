// ServerMetricsTelemetry.swift
//
// Process-level and server-level self-report metrics for the resident daemon.
// Emitted via IntellectusLib on a 30-second cadence from runResidentDaemon.
//
// Off-path gate: single Intellectus.isEnabled read at entry. When monitoring
// is OFF the function returns immediately — no Darwin API is called, no clock
// is read. Caller supplies `now` (epoch seconds); never reads a clock internally.
//
// Metric namespace: server.*
//   server.rss_mb              — resident set size in megabytes
//   server.cpu_user_ms         — user-mode CPU time (ms) since process start
//   server.rpc_count           — cumulative RPC calls since process start
//   server.connections         — active in-flight HTTP connections (live count)
//   server.connections_hwm     — all-time high-water mark of simultaneous in-flight
//   server.4xx_count           — cumulative 4xx responses (client errors)
//   server.5xx_count           — cumulative 5xx responses (server errors)
//   server.shed_count          — cumulative requests shed due to queue full (→ 503)
//   server.latency_ns_total    — cumulative service time in nanoseconds
//   server.latency_fast_count  — requests completing in <1 ms
//   server.latency_mid_count   — requests completing in 1–50 ms
//   server.latency_slow_count  — requests completing in >50 ms
//   server.proto_version       — presence metric (1.0), tag: version="2025-11-25"
//   substrate.kernel.backend_selected — recurring emit to prevent the one-shot
//                                startup event from ageing out of the retention
//                                window, tag: backend=<kind>

import Foundation
import IntellectusLib
import AriaMCP

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - Server metrics emission

/// Emit one snapshot of process-level and server-level metrics.
///
/// Gated on `Intellectus.isEnabled` — returns immediately when monitoring is
/// off (one lock-free atomic read). All Darwin calls live inside the guard so
/// the off-path cost is a single branch.
///
/// Counter values are read from the module-level atomics in `AriaMCP` (HTTPServer.swift)
/// so this layer reads the live state without any lock or copy.
///
/// - Parameters:
///   - rpcCount: Total RPC calls since process start (read from globalRPCCounter).
///   - activeConnections: Current in-flight connection count (globalInflightCounter).
///   - connectionsHWM: All-time peak simultaneous connections (globalInflightHighWater).
///   - count4xx: Cumulative 4xx responses (global4xxCounter).
///   - count5xx: Cumulative 5xx responses (global5xxCounter).
///   - shedCount: Cumulative shed-503 requests (globalShedCounter).
///   - latencyNsTotal: Cumulative service time in nanoseconds (globalLatencyNsTotal).
///   - latencyFast: Requests completing in <1 ms (globalLatencyBucketFast).
///   - latencyMid: Requests completing in 1–50 ms (globalLatencyBucketMid).
///   - latencySlow: Requests completing in >50 ms (globalLatencyBucketSlow).
///   - protoVersion: MCP protocol version string, e.g. "2025-11-25".
///   - kernelKind: Kernel backend raw string ("simd", "scalar", etc.).
///   - now: Current time as Unix epoch seconds (caller supplies; never read internally).
public func reportServerMetrics(
    rpcCount: Int,
    activeConnections: Int,
    connectionsHWM: Int,
    count4xx: Int,
    count5xx: Int,
    shedCount: Int,
    latencyNsTotal: Int,
    latencyFast: Int,
    latencyMid: Int,
    latencySlow: Int,
    protoVersion: String,
    kernelKind: String,
    now: Double
) {
    guard Intellectus.isEnabled else { return }

    #if os(macOS) || os(iOS)
    // RSS and CPU time via MACH_TASK_BASIC_INFO. Both fields come from the
    // same task_info call so one kernel round-trip covers both.
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
    )
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    if kr == KERN_SUCCESS {
        let rssMB = Double(info.resident_size) / (1024.0 * 1024.0)
        Intellectus.report(.metric(
            name: "server.rss_mb",
            value: rssMB,
            tags: ["kit": "AriaResident"],
            ts: now
        ))

        // user_time is a time_value_t: seconds + microseconds since process start.
        let cpuMs = Double(info.user_time.seconds) * 1000.0
                  + Double(info.user_time.microseconds) / 1000.0
        Intellectus.report(.metric(
            name: "server.cpu_user_ms",
            value: cpuMs,
            tags: ["kit": "AriaResident"],
            ts: now
        ))
    }
    #endif

    Intellectus.report(.metric(
        name: "server.rpc_count",
        value: Double(rpcCount),
        tags: ["kit": "AriaResident"],
        ts: now
    ))

    Intellectus.report(.metric(
        name: "server.connections",
        value: Double(activeConnections),
        tags: ["kit": "AriaResident"],
        ts: now
    ))

    Intellectus.report(.metric(
        name: "server.connections_hwm",
        value: Double(connectionsHWM),
        tags: ["kit": "AriaResident"],
        ts: now
    ))

    Intellectus.report(.metric(
        name: "server.4xx_count",
        value: Double(count4xx),
        tags: ["kit": "AriaResident"],
        ts: now
    ))

    Intellectus.report(.metric(
        name: "server.5xx_count",
        value: Double(count5xx),
        tags: ["kit": "AriaResident"],
        ts: now
    ))

    Intellectus.report(.metric(
        name: "server.shed_count",
        value: Double(shedCount),
        tags: ["kit": "AriaResident"],
        ts: now
    ))

    Intellectus.report(.metric(
        name: "server.latency_ns_total",
        value: Double(latencyNsTotal),
        tags: ["kit": "AriaResident"],
        ts: now
    ))

    // Latency bucket counters provide a coarse p50/p95 proxy without a
    // full histogram: if fast+mid >> slow, p95 is in the mid bucket;
    // if slow > 5% of total, the tail is visible.
    Intellectus.report(.metric(
        name: "server.latency_fast_count",
        value: Double(latencyFast),
        tags: ["kit": "AriaResident"],
        ts: now
    ))
    Intellectus.report(.metric(
        name: "server.latency_mid_count",
        value: Double(latencyMid),
        tags: ["kit": "AriaResident"],
        ts: now
    ))
    Intellectus.report(.metric(
        name: "server.latency_slow_count",
        value: Double(latencySlow),
        tags: ["kit": "AriaResident"],
        ts: now
    ))

    // Protocol version emitted as a presence metric (value=1.0) so the dashboard
    // can show the version string from the tag without a numeric y-axis.
    Intellectus.report(.metric(
        name: "server.proto_version",
        value: 1.0,
        tags: ["kit": "AriaResident", "version": protoVersion],
        ts: now
    ))

    // Recurring emit of substrate.kernel.backend_selected prevents the one-shot
    // startup event from ageing out of the retention window. The backend tag
    // carries the kernel kind string (matches PortableKernel.KernelKind.rawValue).
    Intellectus.report(.metric(
        name: "substrate.kernel.backend_selected",
        value: 1.0,
        tags: ["kit": "AriaResident", "backend": kernelKind],
        ts: now
    ))
}
