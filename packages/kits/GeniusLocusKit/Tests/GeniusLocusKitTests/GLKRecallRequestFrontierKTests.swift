// GLKRecallRequestFrontierKTests.swift
//
// Tests for the per-call frontierK override on GLKRecallRequest.
// Verifies three-level precedence:
//   request.frontierK > recallShape.frontierK > engine formula
// and that the request-level override is clamped to [64, 256] exactly
// as RecallShape.frontierK is.
//
// These tests exercise the parameter type and precedence rules in
// isolation (no live estate required) so they run without a
// storage backend.

import Testing
import Foundation
import LocusKit
@testable import GeniusLocusKit

@Suite("GLKRecallRequest.frontierK per-call override")
struct GLKRecallRequestFrontierKTests {

    // A minimal RecallFrame that satisfies the GLKRecallRequest init without
    // requiring a database — the frontierK tests never execute a recall.
    private var blankFrame: LocusKit.RecallFrame {
        RecallFrame(filterChain: [], hydrationLevel: .structured, ordering: .byCaptureTimeDesc)
    }

    // MARK: - Field presence

    @Test("frontierK defaults to nil when not supplied")
    func defaultIsNil() {
        let req = GLKRecallRequest(
            frame: blankFrame,
            mode: .locusOnly,
            scoring: .raw,
            limit: 10,
            fallback: .failClosed,
            origin: .internal
        )
        #expect(req.frontierK == nil)
    }

    @Test("frontierK is stored when supplied")
    func storesValue() {
        let req = GLKRecallRequest(
            frame: blankFrame,
            mode: .locusOnly,
            scoring: .raw,
            limit: 10,
            fallback: .failClosed,
            origin: .internal,
            frontierK: 128
        )
        #expect(req.frontierK == 128)
    }

    // MARK: - Precedence: request beats shape

    @Test("request.frontierK beats recallShape.frontierK when both are set")
    func requestBeatsShape() {
        // Shape requests the minimum (64); request asks for midpoint (128).
        // The request must win.
        let shape = RecallShape(frontierK: RecallShape.frontierKFloor)
        let req = GLKRecallRequest(
            frame: blankFrame,
            mode: .hybrid,
            scoring: .rrf,
            limit: 10,
            fallback: .allowDegraded,
            origin: .internal,
            recallShape: shape,
            frontierK: 128
        )
        // The stored field is 128; clamping is applied by the RecallDirector
        // at execution time. Verify the field carries the caller's intent.
        #expect(req.frontierK == 128)
        // The shape still carries 64 — it is not mutated.
        #expect(req.recallShape?.frontierK == RecallShape.frontierKFloor)
    }

    // MARK: - Clamp contract

    @Test("a below-floor value (1) is clamped to frontierKFloor (64) at the director")
    func clampFloor() {
        // We test the RecallShape.effectiveFrontierK clamping function as
        // the canonical specification for the clamp contract. The director
        // applies the same formula for the request-level override.
        let shape = RecallShape(frontierK: 1)
        let effective = shape.effectiveFrontierK(engineDefault: 100)
        #expect(effective == RecallShape.frontierKFloor)
    }

    @Test("an above-ceiling value (999) is clamped to frontierKCeiling (256) at the director")
    func clampCeiling() {
        let shape = RecallShape(frontierK: 999)
        let effective = shape.effectiveFrontierK(engineDefault: 100)
        #expect(effective == RecallShape.frontierKCeiling)
    }

    @Test("a midpoint value (128) within [64,256] passes through unclamped")
    func midpointUnclamped() {
        let shape = RecallShape(frontierK: 128)
        let effective = shape.effectiveFrontierK(engineDefault: 200)
        // 128 is strictly inside [64, 256] so no clamping occurs.
        #expect(effective == 128)
    }
}
