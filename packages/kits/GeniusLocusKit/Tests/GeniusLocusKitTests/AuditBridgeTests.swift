// AuditBridgeTests.swift
//
// AuditBridge.bridge → [UnifiedAuditEntry]. Focused coverage for the
// lattice-anchor bridging added for node motion modeling (Option 3a): the FDC
// zone time-series the diffusion zone / topic-trajectory motion model folds
// over. The bitmap columns are exercised elsewhere; these tests pin the anchor.

import Testing
import Foundation
import SubstrateTypes
@testable import GeniusLocusKit

@Suite("AuditBridge — lattice anchor bridging (diffusion zone series)")
struct AuditBridgeTests {

    private func event(
        verb: String,
        beforeAnchor: SubstrateTypes.LatticeAnchor?,
        afterAnchor: SubstrateTypes.LatticeAnchor
    ) -> AuditEvent {
        AuditEvent(
            estateUuid: UUID(),
            rowId: UUID(),
            hlc: HLC(physicalTime: 100, logicalCount: 0, nodeID: 1),
            verb: verb,
            beforeBitmaps: verb == "capture" ? nil : (adjective: 0, operational: 0, provenance: 0),
            afterBitmaps: (adjective: 0, operational: 0, provenance: 0),
            beforeLatticeAnchor: beforeAnchor,
            afterLatticeAnchor: afterAnchor,
            actor: "capture"
        )
    }

    private func anchor(_ s: String) -> SubstrateTypes.LatticeAnchor {
        SubstrateTypes.LatticeAnchor.udc(s)
    }

    private func code(_ s: String) -> Int64 {
        Int64(bitPattern: anchor(s).udcCode)
    }

    @Test("capture emits one latticeAnchor entry: afterValue = code, beforeValue = null")
    func captureEmitsAnchor() {
        let entries = AuditBridge.bridge(
            event(verb: "capture", beforeAnchor: nil, afterAnchor: anchor("530")))
        let anchors = entries.filter { $0.fieldPath == "latticeAnchor" }
        #expect(anchors.count == 1)
        #expect(anchors[0].beforeValue == UnifiedAuditValue.null)
        #expect(anchors[0].afterValue == UnifiedAuditValue.integer(code("530")))
    }

    @Test("a reanchor that changes the anchor emits before→after")
    func reanchorEmitsBeforeAfter() {
        let entries = AuditBridge.bridge(
            event(verb: "reanchor", beforeAnchor: anchor("530"), afterAnchor: anchor("004")))
        let anchors = entries.filter { $0.fieldPath == "latticeAnchor" }
        #expect(anchors.count == 1)
        #expect(anchors[0].beforeValue == UnifiedAuditValue.integer(code("530")))
        #expect(anchors[0].afterValue == UnifiedAuditValue.integer(code("004")))
    }

    @Test("a mutate that leaves the anchor unchanged emits no anchor entry")
    func unchangedAnchorEmitsNothing() {
        let entries = AuditBridge.bridge(
            event(verb: "mutate", beforeAnchor: anchor("530"), afterAnchor: anchor("530")))
        #expect(entries.allSatisfy { $0.fieldPath != "latticeAnchor" })
    }
}
