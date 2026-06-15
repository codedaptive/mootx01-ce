import Dispatch

// Cross-suite mutual exclusion for tests that mutate the GLOBAL Intellectus
// facade (install/setEnabled/report). `.serialized` only serializes tests
// WITHIN one suite; Swift Testing still runs suites concurrently, so two
// suites installing global sinks race each other and samples land in the
// wrong sink. Every test that touches the global facade wraps its body in
// `await intellectusGlobalGate.withLock { ... }`.
final class IntellectusGlobalGate: @unchecked Sendable {
    static let shared = IntellectusGlobalGate()
    private let semaphore = DispatchSemaphore(value: 1)

    func withLock<T>(_ body: () async throws -> T) async rethrows -> T {
        // Acquire off the cooperative pool so a waiting test never blocks a
        // Swift Concurrency worker thread.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.semaphore.wait()
                cont.resume()
            }
        }
        defer { semaphore.signal() }
        return try await body()
    }
}

let intellectusGlobalGate = IntellectusGlobalGate.shared
