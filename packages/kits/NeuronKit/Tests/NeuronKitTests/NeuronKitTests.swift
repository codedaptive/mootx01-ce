// NeuronKitTests.swift
//
// Module-level smoke tests, peer to `Sources/NeuronKit/NeuronKit.swift`.
// As reasoning and autonomic functions land, each gets its own test file.

import Testing
@testable import NeuronKit

@Suite("NeuronKit module")
struct NeuronKitTests {

    @Test("module version")
    func moduleVersion() {
        #expect(NeuronKit.version == "0.1.0")
    }

    @Test("linguistic pipeline mode matches build configuration")
    func linguisticPipelineModeBuildConfiguration() {
        let mode = NeuronKit.linguisticPipelineMode
        #if APPLE_NLP_ACCEL
        #expect(mode == .appleNLAccel)
        #expect(mode.rawValue == "apple-nl-accel")
        #else
        #expect(mode == .deterministicReference)
        #expect(mode.rawValue == "deterministic-reference")
        #endif
    }
}
