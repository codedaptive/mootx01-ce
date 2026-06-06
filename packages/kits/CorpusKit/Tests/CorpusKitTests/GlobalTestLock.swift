// GlobalTestLock.swift
//
// Process-wide serialisation lock for tests that touch the Intellectus
// global singleton (enabled flag + installed sink).
//
// Background:
//   Swift Testing parallelises @Test functions across suites by default.
//   Any test that (a) calls Intellectus.setEnabled(true) / install(sink:),
//   or (b) calls a CorpusKit method that emits (BundleStore.insert,
//   HybridRecall.recall), must hold GlobalTestLock while monitoring is on.
//   Otherwise a concurrent test's CorpusKit call will emit into the
//   capturing sink and corrupt exact-count assertions.
//
//   An actor's run(body:) method does NOT work for this purpose because
//   Swift actors use cooperative multitasking — a suspension point inside
//   the actor method (e.g. `try await body()`) releases the actor's
//   isolation and allows re-entry by another caller before body() finishes.
//   This is actor reentrancy, and it defeats the serialisation intent.
//
//   This class implements a proper async mutex using a checked-continuation
//   waiter queue. acquire() queues the caller if the lock is already held;
//   release() resumes the oldest waiter (FIFO). No suspension point exists
//   *inside* the actor that would allow re-entry while the lock is held.
//
//   Mirrors VectorKit's GlobalTestLock.swift and NeuronKit's
//   IntellectusTestLock.swift. Pattern is fleet-standard for kits that
//   adopt IntellectusLib self-report telemetry.
//
// Usage:
//   let lock = await GlobalTestLock.shared.acquire()
//   defer { Task { await GlobalTestLock.shared.release() } }
//   // ... body that requires exclusive access to Intellectus state ...
//
// Alternatively, use the convenience method:
//   await GlobalTestLock.shared.withLock {
//       // test body
//   }
//
// ALL tests in CorpusKitTests that call BundleStore.insert or
// HybridRecall.recall — or that toggle Intellectus.setEnabled — MUST use
// this lock. That includes both the telemetry test suite and the
// functional BundleStoreTests and HybridRecallTests.

import Foundation

/// Process-wide async mutex for Intellectus singleton isolation in tests.
///
/// Uses a continuation-queue pattern so the mutex is fully async-safe:
/// no thread blocking, no DispatchSemaphore, compatible with Swift's
/// cooperative thread pool.
actor GlobalTestLock {
    /// Shared instance — all tests in the process acquire this same lock.
    static let shared = GlobalTestLock()
    private init() {}

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire the lock. Suspends the caller until the lock is available.
    /// Waiters are resumed FIFO to avoid starvation.
    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        // Lock is held: enqueue this caller and suspend.
        // The actor does NOT suspend here within its own isolation context —
        // withCheckedContinuation suspends the CALLER's task outside the
        // actor. The actor is free to serve other callers (e.g. release())
        // without reentrancy.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Release the lock. If there are waiters, the oldest is resumed.
    func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            let next = waiters.removeFirst()
            next.resume()   // isHeld stays true — passed to the next waiter
        }
    }

    /// Convenience: acquire the lock, run `body`, then release.
    /// The lock is released even if `body` throws.
    func withLock(_ body: () async throws -> Void) async rethrows {
        await acquire()
        do {
            try await body()
        } catch {
            await release()
            throw error
        }
        await release()
    }
}
