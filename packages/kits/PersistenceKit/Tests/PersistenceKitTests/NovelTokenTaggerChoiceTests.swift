// NovelTokenTaggerChoiceTests.swift
//
// Tests for the NovelTokenTaggerChoice field on EstateConfiguration (Layer-2a).
// Verifies:
//   (a) default creation gets .hmm
//   (b) explicit .nlTagger opt-in is stored
//   (c) explicit .hmm is stored
//   (d) existing call sites (no taggerChoice arg) produce .hmm
//   (e) invalidConfiguration error case documented in Swift

import Foundation
import Testing
@testable import PersistenceKit

@Suite("NovelTokenTaggerChoice — EstateConfiguration field (Layer-2a)")
struct NovelTokenTaggerChoiceTests {

    // (a) Default creation yields .hmm — the cross-platform baseline.
    // This confirms the Apple-default flip: formerly NLTagger was the
    // implicit default on Apple via `#if canImport(NaturalLanguage)`;
    // after Layer-2a the default is explicitly .hmm everywhere.
    @Test("default EstateConfiguration uses .hmm novel-token tagger")
    func defaultIsHMM() {
        let config = EstateConfiguration(estateID: .init(), backend: .inMemory)
        #expect(config.novelTokenTagger == .hmm)
    }

    // (b) Explicit .nlTagger opt-in is preserved on Apple builds.
    // This is the opt-in path for advanced Apple-only estates.
    @Test("explicit .nlTagger is stored on EstateConfiguration")
    func explicitNLTaggerIsStored() {
        let config = EstateConfiguration(
            estateID: .init(),
            backend: .inMemory,
            novelTokenTagger: .nlTagger
        )
        #expect(config.novelTokenTagger == .nlTagger)
    }

    // (c) Explicit .hmm is preserved.
    @Test("explicit .hmm is stored on EstateConfiguration")
    func explicitHMMIsStored() {
        let config = EstateConfiguration(
            estateID: .init(),
            backend: .inMemory,
            novelTokenTagger: .hmm
        )
        #expect(config.novelTokenTagger == .hmm)
    }

    // (d) Existing call sites that do not specify novelTokenTagger get .hmm
    // (tests the defaulted parameter pattern — same as (a) but with all
    // four-parameter form used in the codebase).
    @Test("four-param init without novelTokenTagger gets .hmm default")
    func fourParamDefaultIsHMM() {
        let config = EstateConfiguration(
            estateID: .init(),
            backend: .sqlite(url: URL(fileURLWithPath: "/tmp/test.db")),
            encryptionConfig: .plaintext,
            cacheConfig: .disabled
        )
        #expect(config.novelTokenTagger == .hmm)
    }

    // (e) NovelTokenTaggerChoice enum cases exist and are distinct.
    @Test("NovelTokenTaggerChoice cases are distinct")
    func casesAreDistinct() {
        #expect(NovelTokenTaggerChoice.hmm != NovelTokenTaggerChoice.nlTagger)
    }

    // (f) Default static accessor agrees with default init.
    @Test("NovelTokenTaggerChoice.default is .hmm")
    func defaultStaticIsHMM() {
        #expect(NovelTokenTaggerChoice.default == .hmm)
    }

    // (g) The invalidConfiguration error case is present in StorageError.
    // This validates that the cross-port error parity is shipped in Swift.
    @Test("StorageError.invalidConfiguration carries reason string")
    func invalidConfigurationError() {
        let err = StorageError.invalidConfiguration(reason: "test reason")
        if case .invalidConfiguration(let reason) = err {
            #expect(reason == "test reason")
        } else {
            Issue.record("Expected .invalidConfiguration case")
        }
    }
}
