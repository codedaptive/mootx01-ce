// ProxyAdmissionGate.swift
//
// Frame-admission primitives for the stdio→HTTP proxy bridge.
// Lives in MootInstallerCore so MootInstallerCoreTests can exercise them
// without importing the executable target (matching the pattern established
// by ProxyDispositionLogic).

import Foundation

/// Maximum bytes per frame forwarded by the proxy.
///
/// Matches Rust `MAX_LINE_BYTES` exactly (#36: a normal JSON-RPC frame is a
/// few KB; 4 MB is generous for any legitimate MCP tool call while preventing
/// a multi-GB stdin attack from exhausting the proxy's address space).
public let proxyMaxFrameBytes: Int = 4 * 1024 * 1024

/// Actor-based counting gate for proxy frame admission.
///
/// Limits the number of concurrently in-flight forwarding tasks to
/// `maxConcurrent`. Callers call `acquire()` before spawning a forwarding
/// task and `release()` when the task completes. Frame 17 (when `maxConcurrent`
/// is 16) suspends in `acquire()` until a running frame releases its slot.
///
/// Matches Rust `MAX_CONCURRENT` semantics (#12: prevents unbounded task
/// creation from a fast stdin producer).
///
/// The implementation uses a waiter queue so suspended callers are resumed in
/// FIFO order. Each `release()` either hands its slot directly to the next
/// waiter (slot count unchanged) or decrements the count if no waiters remain.
public actor ProxyConcurrencyGate {
    /// Maximum number of frames that may be forwarded simultaneously.
    public let maxConcurrent: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter maxConcurrent: Slot count. Pass `16` to match Rust
    ///   `MAX_CONCURRENT`.
    public init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    /// Acquire a forwarding slot. Returns immediately when a slot is
    /// available; suspends until `release()` is called when all slots are
    /// occupied.
    public func acquire() async {
        guard inFlight >= maxConcurrent else {
            inFlight += 1
            return
        }
        // All slots taken. Queue and suspend until a slot is handed to us by
        // release(). The slot is NOT pre-incremented here — release() keeps
        // inFlight unchanged when handing a slot to a waiter, so the first
        // statement after resuming from withCheckedContinuation correctly
        // finds the slot already counted.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// Release a previously acquired slot. If callers are waiting in
    /// `acquire()`, the first waiter is resumed (slot transfers, count
    /// unchanged); otherwise the slot count decrements.
    public func release() {
        // Underflow guard: every release must pair with a prior acquire.
        precondition(inFlight > 0 || !waiters.isEmpty, "ProxyConcurrencyGate.release() called without a matching acquire()")
        if let next = waiters.first {
            waiters.removeFirst()
            // Transfer the slot directly: inFlight stays the same so the
            // resumed acquire() returns without double-counting.
            next.resume()
        } else {
            inFlight -= 1
        }
    }

    /// Current number of acquired (in-flight) slots. Used in tests and
    /// diagnostics.
    public var currentInFlight: Int { inFlight }
}
