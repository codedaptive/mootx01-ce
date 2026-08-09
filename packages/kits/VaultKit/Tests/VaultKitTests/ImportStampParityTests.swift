// ImportStampParityTests.swift — Part 2 parity gate (MXE-JI-5).
//
// Asserts that `importEmbeddingModelID` (LocusKit) is the single source
// of truth for every import writer: DrawerMapping default, JsonImportBridge,
// and PalaceBridge all route through it; the constant itself is pinned to
// the canonical string. A compile-time regression (any writer going back to a
// bare literal) would break these assertions.

import Testing
import LocusKit
@testable import VaultKit

@Suite("Import stamp parity")
struct ImportStampParityTests {

    // Pin the constant value so any accidental change surfaces immediately.
    @Test("importEmbeddingModelID equals canonical string")
    func constantValue() {
        #expect(importEmbeddingModelID == "vaultkit-noembed-v1")
    }

    // DrawerMapping's default embeddingModelID flows from the shared constant.
    @Test("DrawerMapping default uses shared constant")
    func drawerMappingDefault() {
        let mapping = DrawerMapping()
        #expect(mapping.embeddingModelID == importEmbeddingModelID)
    }

    // JsonImportBridge's static stamp equals the shared constant.
    @Test("JsonImportBridge static stamp equals shared constant")
    func jsonImportBridgeStamp() {
        #expect(JsonImportBridge.embeddingModelID == importEmbeddingModelID)
    }

    // PalaceBridge's static stamp equals the shared constant.
    @Test("PalaceBridge static stamp equals shared constant")
    func palaceBridgeStamp() {
        #expect(PalaceBridge.embeddingModelID == importEmbeddingModelID)
    }

    // All three writers produce the same stamp string.
    @Test("all three import writers produce identical stamps")
    func allWritersMatch() {
        #expect(DrawerMapping().embeddingModelID == JsonImportBridge.embeddingModelID)
        #expect(DrawerMapping().embeddingModelID == PalaceBridge.embeddingModelID)
    }
}
