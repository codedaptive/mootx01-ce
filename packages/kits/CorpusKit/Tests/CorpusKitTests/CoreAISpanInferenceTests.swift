// CoreAISpanInferenceTests.swift
//
// The batched seam's input planning (ADR-028 E3, E4): every row of a chunk
// padded to the chunk's longest token list, attention 1 on real tokens and 0
// on the pad, an empty token list given one masked pad position. The asset
// itself is not bundled with the kit; the model path is exercised by the
// Arctic factory proof against a real model directory.

import Foundation
import Testing
import CorpusKit
@testable import CorpusKitProviders

@Suite("CoreAISpanInference input planning")
struct CoreAISpanInferenceTests {

    @Test("rows pad to the chunk's longest list, not the model maximum")
    func rowsPadToLongest() throws {
        let batch = CoreAISpanInference.batchInputs(
            tokenLists: [[101, 7592, 102], [101, 102], [101, 2088, 2003, 3835, 102]], padTokenID: 0)
        #expect(batch.rows == 3)
        #expect(batch.length == 5, "the longest list sets the row length")
        #expect(batch.ids == [101, 7592, 102, 0, 0,
                              101, 102, 0, 0, 0,
                              101, 2088, 2003, 3835, 102])
        #expect(batch.mask == [1, 1, 1, 0, 0,
                               1, 1, 0, 0, 0,
                               1, 1, 1, 1, 1])
    }

    @Test("an empty token list becomes one masked pad position")
    func emptyListGetsOnePadPosition() throws {
        let batch = CoreAISpanInference.batchInputs(tokenLists: [[]], padTokenID: 7)
        #expect(batch == CoreAISpanInference.BatchInputs(rows: 1, length: 1, ids: [7], mask: [0]))
    }

    @Test("a directory without an .aimodel is modelUnavailable, named by the seam")
    func noAssetIsModelUnavailable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("coreai-seam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: EncoderError.self) { try CoreAISpanInference.locateAsset(in: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("ArcticEmbedS.aimodel"), withIntermediateDirectories: true)
        #expect(try CoreAISpanInference.locateAsset(in: dir).lastPathComponent == "ArcticEmbedS.aimodel")
    }
}
