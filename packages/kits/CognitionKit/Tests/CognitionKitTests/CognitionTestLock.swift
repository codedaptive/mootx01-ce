// CognitionTestLock.swift
//
// Process-wide mutex serialising every CognitionKit test that either:
//   (a) touches the Intellectus global singleton (install/setEnabled), or
//   (b) calls a recipe-run function that may emit telemetry
//       (GroundedSynthesis.run, MigrationBenchmark.run).
//
// WHY THIS IS NECESSARY
// Swift Testing runs test functions from different suites concurrently.
// The `.serialized` trait on a suite serialises tests WITHIN that suite
// but does not prevent tests from OTHER suites running in parallel.
// The Intellectus singleton (enabled flag + installed sink) is
// process-wide state. A telemetry test that installs a capturing sink
// and enables monitoring, running concurrently with a GroundedSynthesis
// or MigrationBenchmark test that emits into that same sink, corrupts
// the telemetry test's exact-count assertions — producing intermittent
// failures under the default parallel runner.
//
// SOLUTION (mirrors NeuronKit IntellectusTestLock, VectorKit GlobalTestLock)
// This is the Swift equivalent of the `GLOBAL_LOCK: Mutex<()>` held by
// every test in cognitionkit_telemetry_tests.rs. A disabled-path test
// that runs lock-free can interleave with a lock-held enabled-path test
// and corrupt it — so the lock is unconditional on all callers of
// recipe-run functions, including disabled-path tests.
//
// IMPLEMENTATION (Swift 6 strict concurrency)
// All affected test functions are declared `async` (Swift Testing
// supports both sync and async test functions). This allows a single
// async mutex to be used uniformly, with no sync/async bridge.
//
// `withCognitionLock` suspends the calling task cooperatively (no
// thread is blocked) and ensures mutual exclusion across all test
// functions that touch the singleton or call emitting functions.
//
// The underlying actor uses a FIFO continuation queue — no task starves.

import Foundation

// MARK: - Actor-based mutex

/// Serialises all CognitionKit tests that share the Intellectus singleton.
/// Fair FIFO queue of waiting continuations — no task starves.
/// Mirrors IntellectusTestMutex in NeuronKitTests.
final actor CognitionTestMutex {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire the mutex. Suspends the calling task until available.
    func acquire() async {
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Release the mutex and resume the oldest waiter, if any.
    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            held = false
        }
    }
}

/// Singleton — one instance per process, shared across all test suites.
let cognitionTestMutex = CognitionTestMutex()

// MARK: - Lock helper

/// Acquire the mutex, run `body`, release on return or throw.
///
/// ALL affected test functions are declared `async` to use this helper
/// uniformly. Swift Testing supports async test functions; the runner
/// handles them correctly and no behaviour changes are visible to tests.
///
/// Using a cooperative async mutex (not DispatchSemaphore) ensures
/// correctness under Swift 6 strict concurrency and avoids blocking
/// any thread in the cooperative thread pool.
func withCognitionLock<R>(
    _ body: () async throws -> R
) async throws -> R {
    await cognitionTestMutex.acquire()
    do {
        let result = try await body()
        await cognitionTestMutex.release()
        return result
    } catch {
        await cognitionTestMutex.release()
        throw error
    }
}
