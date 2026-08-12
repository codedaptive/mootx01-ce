// ProxyAdmissionTests.swift
//
// Unit tests for the proxy frame-admission primitives: frame-size cap and
// concurrency gate. These tests exercise MootInstallerCore types directly
// so no live daemon or executable import is required.

import Foundation
import Testing
@testable import MootInstallerCore

// MARK: — Frame-size cap

@Suite("Proxy frame-size cap")
struct ProxyFrameSizeCapTests {

    /// The constant must match Rust MAX_LINE_BYTES byte-for-byte (#36 parity).
    @Test func frameSizeCapMatchesRustConstant() {
        #expect(proxyMaxFrameBytes == 4 * 1024 * 1024)
    }

    /// A frame at exactly the cap is admitted (boundary: inclusive).
    @Test func frameSizeAtCapIsAdmitted() {
        let atCap = Data(repeating: 0x20, count: proxyMaxFrameBytes)
        #expect(atCap.count <= proxyMaxFrameBytes)
    }

    /// A frame one byte over the cap is rejected (boundary: exclusive).
    @Test func frameSizeOneOverCapIsRejected() {
        let overCap = Data(repeating: 0x20, count: proxyMaxFrameBytes + 1)
        #expect(overCap.count > proxyMaxFrameBytes)
    }
}

// MARK: — Concurrency gate

@Suite("ProxyConcurrencyGate")
struct ProxyConcurrencyGateTests {

    /// Slots increment from 0 up to the cap, then return to 0 on release.
    @Test func acquireAndReleaseTrackCount() async {
        let gate = ProxyConcurrencyGate(maxConcurrent: 4)
        #expect(await gate.currentInFlight == 0)
        await gate.acquire()
        await gate.acquire()
        await gate.acquire()
        #expect(await gate.currentInFlight == 3)
        await gate.acquire()
        #expect(await gate.currentInFlight == 4)
        await gate.release()
        await gate.release()
        #expect(await gate.currentInFlight == 2)
        await gate.release()
        await gate.release()
        #expect(await gate.currentInFlight == 0)
    }

    /// A 17th acquire (with maxConcurrent == 16) suspends until a release
    /// frees a slot. After the release the suspended acquire completes and
    /// the in-flight count is back to 16.
    @Test func gateBlocksAtCapacity() async {
        let gate = ProxyConcurrencyGate(maxConcurrent: 16)
        // Fill all 16 slots.
        for _ in 0..<16 {
            await gate.acquire()
        }
        #expect(await gate.currentInFlight == 16)

        // Attempt a 17th acquire in a child task; it must suspend.
        let seventeenth = Task {
            await gate.acquire()
        }
        // Yield so the child task runs and blocks on the full gate.
        await Task.yield()
        await Task.yield()

        // The gate is still at 16; the child is waiting.
        #expect(await gate.currentInFlight == 16)

        // Release one slot — the child should now proceed.
        await gate.release()
        await seventeenth.value

        // The child acquired, bringing us back to 16.
        #expect(await gate.currentInFlight == 16)

        // Clean up.
        for _ in 0..<16 {
            await gate.release()
        }
        #expect(await gate.currentInFlight == 0)
    }

    /// Released slots restore full throughput: after filling and emptying the
    /// gate, all subsequent acquires complete without blocking.
    @Test func releasedSlotsRestoreThroughput() async {
        let gate = ProxyConcurrencyGate(maxConcurrent: 3)
        await gate.acquire()
        await gate.acquire()
        await gate.acquire()
        await gate.release()
        await gate.release()
        await gate.release()
        // All slots free — three more acquires must succeed immediately.
        await gate.acquire()
        await gate.acquire()
        await gate.acquire()
        #expect(await gate.currentInFlight == 3)
        // Clean up.
        await gate.release()
        await gate.release()
        await gate.release()
    }
}
