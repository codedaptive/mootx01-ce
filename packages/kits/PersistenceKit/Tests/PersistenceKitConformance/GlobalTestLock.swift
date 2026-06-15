// GlobalTestLock.swift
//
// Process-wide serialisation lock for tests that touch the Intellectus
// global singleton (enabled flag + installed sink).
//
// Background:
//   Swift Testing parallelises @Test functions across suites by default.
//   swift-testing with swift package manager compiles ALL test targets into
//   a SINGLE test binary (PersistenceKitPackageTests.xctest) sharing one
//   process. The Intellectus singleton is process-wide. Tests from
//   PersistenceKitInMemoryTests and PersistenceKitSQLiteTests therefore
//   run concurrently in the same process and race on the same Intellectus
//   singleton.
//
//   Placing GlobalTestLock in PersistenceKitConformance (a shared .target
//   that both InMemory and SQLite test targets import) ensures BOTH targets
//   use THE SAME `GlobalTestLock.shared` instance, achieving correct
//   cross-target serialisation.
//
//   An actor's withLock pattern would NOT work here because Swift actors
//   use cooperative multitasking — a suspension point inside the actor
//   releases its isolation, allowing re-entry. This class uses a FIFO
//   continuation-queue mutex: the lock is encoded in `isHeld`/`waiters`
//   state, not in actor isolation.
//
// Usage:
//   try await GlobalTestLock.shared.withLock {
//       // body that exclusively owns the Intellectus singleton
//   }
//
// ALL tests that call Intellectus.setEnabled, Intellectus.install(sink:),
// or any function that emits via Intellectus.report — MUST hold this lock.

import Foundation

/// Process-wide async mutex for Intellectus singleton isolation in tests.
///
/// Placed in PersistenceKitConformance so both PersistenceKitInMemoryTests
/// and PersistenceKitSQLiteTests share the SAME `shared` instance across
/// the combined test binary.
///
/// Uses a continuation-queue pattern: fully async-safe, no thread blocking,
/// no DispatchSemaphore, compatible with Swift's cooperative thread pool.
public actor GlobalTestLock {
    /// Shared instance — all tests in the process acquire this same lock.
    public static let shared = GlobalTestLock()
    private init() {}

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Acquire the lock. Suspends the caller until the lock is available.
    /// Waiters are resumed FIFO to avoid starvation.
    public func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        // Lock is held: enqueue this caller and suspend.
        // withCheckedContinuation suspends the CALLER'S task outside the actor.
        // The actor is free to serve other callers (e.g. release()) without
        // reentrancy. The `isHeld = true` state persists until release() is called.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Release the lock. If there are waiters, the oldest is resumed.
    public func release() {
        if waiters.isEmpty {
            isHeld = false
        } else {
            let next = waiters.removeFirst()
            next.resume()   // isHeld stays true — passed directly to the next waiter
        }
    }

    /// Convenience: acquire the lock, run `body`, then release.
    /// The lock is released even if `body` throws.
    public func withLock(_ body: () async throws -> Void) async rethrows {
        await acquire()
        do {
            try await body()
        } catch {
            release()
            throw error
        }
        release()
    }
}
