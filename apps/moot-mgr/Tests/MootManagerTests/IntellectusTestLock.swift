// IntellectusTestLock.swift
//
// A process-wide cooperative mutex for tests that touch the GLOBAL `Intellectus`
// singleton (the per-process telemetry gate + installed sink).
//
// Why this exists: `Intellectus` is a process-global. Two concurrent tests that
// manipulate its enabled flag / installed sink — OR one test that enables it
// while another concurrently calls a telemetry-emitting GLK method (provision /
// quiesce / drain / destroy) — produce phantom samples in each other's sinks.
// Swift Testing runs `@Test` functions in parallel across suites by default, and
// `.serialized` only orders tests WITHIN one suite, not across suite boundaries.
//
// This mirrors the established solution in the GeniusLocusKit test target
// (GLKTelemetrySuite's `intellectusTestMutex`): every test in THIS target that
// either drives global `Intellectus` (the end-to-end integration test) or emits
// GLK telemetry (the admin-plane provisioning/lifecycle tests) acquires this one
// mutex for its full duration, so they cannot interleave on the singleton.

import Foundation
import IntellectusLib

/// Actor-based cooperative mutex. Serialises the critical section across all
/// callers without blocking a thread (uses async suspension).
actor IntellectusTestMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire the lock, suspending until it is free.
    func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    /// Release the lock, waking the next waiter (if any).
    func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            // Hand the lock directly to the next waiter (stays `locked`).
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

/// The single process-wide instance every global-`Intellectus`-touching test
/// in this target shares.
let intellectusTestMutex = IntellectusTestMutex()

/// Run `body` while holding the process-wide Intellectus mutex, restoring the
/// global to a disabled / NoOp state afterwards so the next holder starts clean.
/// The reset matches the GLK telemetry-test cleanup (disabled + NoOpSink), and
/// the release is awaited synchronously (after the reset) so the next holder
/// never observes a non-default singleton.
func withIntellectusLock<T>(_ body: () async throws -> T) async rethrows -> T {
    await intellectusTestMutex.acquire()
    do {
        let value = try await body()
        Intellectus.setEnabled(false)
        Intellectus.install(sink: NoOpSink.shared)
        await intellectusTestMutex.release()
        return value
    } catch {
        Intellectus.setEnabled(false)
        Intellectus.install(sink: NoOpSink.shared)
        await intellectusTestMutex.release()
        throw error
    }
}
