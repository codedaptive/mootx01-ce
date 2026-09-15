// FactExtractionLiveProofTests.swift
//
// Live end-to-end proof for the Swift fact-extraction activation path.
//
// Creates an in-memory estate, files one drawer with a plainly factual
// sentence, activates the real CoreAI NuExtract extractor (pointing at
// the production model assets on this machine), calls one extraction
// batch via the resolveFactExtractionCycle path, and asserts that at
// least one KG fact was filed.
//
// This test is gated on the actual model assets being present at their
// known machine paths. It is tagged @Test(.disabled) by default so the
// standard suite does not run it on machines without the assets; the
// live proof invokes it with SWIFT_TEST_ARGS="--filter FactExtractionLiveProof".
//
// Command to run (from the worktree root):
//   make test-one DIR=packages/kits/AriaMcpKit \
//        SWIFT_TEST_ARGS="--filter FactExtractionLiveProof"
//
// Assets required (verified on this machine):
//   /Volumes/llm_models/coreai/nuextract-tiny-v1.5-v11s-8k-b1-q8.aimodel
//   /Volumes/llm_models/gguf/nuextract-tiny-v1.5/tokenizer.json
//   apps/mootx01/.build/out/Products/Debug/mootx01 (hosts the CoreAI worker)
//
// FACT_EXTRACTION_WIRE §2b — Swift port live proof.

import Testing
import Foundation
@testable import GeniusLocusKit     // grants access to internal capture verb
import GeniusLocusKitMigrations
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import FactExtractionKit
import FactExtractionKitProviders
@testable import AriaResident

// MARK: - Helpers

/// Open a minimal in-memory GLK estate for the live proof.
/// In-memory storage is fine here — the live assertion is that the
/// AI model extracts ≥1 fact and the result is reflected in the returned
/// count; persistence to disk is not part of this proof.
private func openLiveProofEstate() async throws -> (GeniusLocusKit, EstateHandle) {
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "fact-extraction-live-proof")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    let params = EstateProvisionParams(
        estateName: "FactExtraction Live Proof Estate",
        kind: .glk,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none)
    let handle = try await kit.provision(
        storage: storage, owner: owner, params: params,
        embeddingModels: [.deterministic])
    return (kit, handle)
}

// MARK: - Live proof test

@Suite("AriaResident — resolveFactExtractionCycle live proof")
struct FactExtractionLiveProofTests {

    /// Canonical asset paths on this development machine.
    /// The CoreAI `.aimodel` bundle and the HuggingFace tokenizer
    /// are stored on the external llm_models volume.
    static let assetURL = URL(
        fileURLWithPath: "/Volumes/llm_models/coreai/nuextract-tiny-v1.5-v11s-8k-b1-q8.aimodel")
    static let tokenizerURL = URL(
        fileURLWithPath: "/Volumes/llm_models/gguf/nuextract-tiny-v1.5/tokenizer.json")

    /// The mootx01 debug binary hosts the CoreAI worker subprocess.
    /// The worker is invoked as a child process with "coreai-nuextract-worker"
    /// as its first argument; the mootx01 binary handles that subcommand.
    static let workerExecutableURL = URL(
        fileURLWithPath:
            "/Users/bob/devlop/mootx01-ee-kgfact-swift-audit/apps/mootx01/.build/out/Products/Debug/mootx01")

    // -----------------------------------------------------------------------
    // Live proof: file a drawer, activate the real CoreAI extractor, run one
    // batch via resolveFactExtractionCycle, assert ≥1 fact filed.
    //
    // Conditionally enabled: runs only when assets are present on this machine.
    // Skips automatically on machines without the model files.
    // Run explicitly with:
    //   make test-one DIR=packages/kits/AriaMcpKit \
    //        SWIFT_TEST_ARGS="--filter FactExtractionLiveProof"
    // -----------------------------------------------------------------------
    @Test(
        .enabled(
            if: FileManager.default.fileExists(
                    atPath: "/Volumes/llm_models/coreai/nuextract-tiny-v1.5-v11s-8k-b1-q8.aimodel")
                && FileManager.default.fileExists(
                    atPath: "/Volumes/llm_models/gguf/nuextract-tiny-v1.5/tokenizer.json")
                && FileManager.default.isExecutableFile(
                    atPath: "/Users/bob/devlop/mootx01-ee-kgfact-swift-audit/apps/mootx01/.build/out/Products/Debug/mootx01"),
            "requires CoreAI assets on /Volumes/llm_models and the built mootx01 binary")
    )
    func liveProof_fileDrawer_runCycle_atLeastOneFact() async throws {
        // ----------------------------------------------------------------
        // 1. Build the real CoreAI NuExtract extractor.
        //    (Asset existence already verified by @Test .enabled(if:) above.)
        //    init throws FactExtractionError.unavailable when the CoreAI
        //    runtime or the model bundle is absent.
        // ----------------------------------------------------------------
        let extractor = try CoreAINuExtractFactExtractor(
            workerExecutableURL: Self.workerExecutableURL,
            workerArgumentsPrefix: ["coreai-nuextract-worker"],
            assetURL: Self.assetURL,
            tokenizerURL: Self.tokenizerURL,
            modelVersion: "1.0")
        print("live proof: extractor constructed spec=\(extractor.spec.providerID):\(extractor.spec.modelID):\(extractor.spec.modelVersion)")

        // ----------------------------------------------------------------
        // 2. Open an in-memory GLK estate.
        // ----------------------------------------------------------------
        let (kit, handle) = try await openLiveProofEstate()
        defer { Task { try? await kit.close(handle) } }

        // ----------------------------------------------------------------
        // 3. File one drawer with cue-word content.
        //    NuExtract's extraction schema uses `Evidence:` / `Asserted:` cue
        //    words to ground the assertion. Without them the model returns an
        //    empty `assertionKind` field and the grounding validator rejects the
        //    candidate before it reaches the store, resulting in factsFiled=0.
        //    These cue words are what the model needs, not what a typical user
        //    writes — they are here to make the live proof deterministic and
        //    verifiable, not as a template for real capture content.
        // ----------------------------------------------------------------
        let content = """
            Evidence: The Eiffel Tower is located in Paris, France, \
            and stands 330 metres tall. It was built by Gustave Eiffel \
            and completed in 1889.
            Asserted: The Eiffel Tower stands in Paris, France.
            """
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "live-proof/eiffel",
            latticeAnchor: .udc("004"),
            addedBy: "fact-extraction-live-proof",
            embeddingModelID: "test-model-v1",
            subject: String(content.prefix(120)))
        let drawer = try await kit.capture(handle, frame)
        print("live proof: filed drawer id=\(drawer.id)")

        // ----------------------------------------------------------------
        // 4. Activate via the decision function to obtain the live cycle.
        //    resolveFactExtractionCycle encodes the three-case contract:
        //    setting=.on + extractor present → live closure.
        // ----------------------------------------------------------------
        let cycle = await AriaResident.resolveFactExtractionCycle(
            setting: .on,
            extractor: extractor,
            kit: kit,
            handle: handle)
        let nonNilCycle = try #require(
            cycle,
            "resolveFactExtractionCycle must return a live closure when setting=.on and extractor is available")
        print("live proof: cycle obtained recipe=\(extractor.spec.providerID):\(extractor.spec.modelID):\(extractor.spec.modelVersion)")

        // ----------------------------------------------------------------
        // 5. Run one extraction batch.
        //    The drawer content carries `Evidence:` / `Asserted:` cue words
        //    so NuExtract produces a non-empty `assertionKind` field and the
        //    grounding validator accepts at least one candidate. Without the
        //    cue words the q8 quantized model (nuextract-tiny-v1.5-v11s-8k-b1-q8)
        //    returns empty assertionKind on every candidate and the grounding
        //    validator correctly rejects them all, yielding factsFiled=0.
        //
        //    The Rust live proof confirmed that cued content consistently yields
        //    factsFiled >= 1 with the same CoreAI model family.
        // ----------------------------------------------------------------
        let filed = try await nonNilCycle(Date())
        print("live proof: batch complete factsFiled=\(filed)")
        // factsFiled must be >= 1: the cued content is specifically chosen so
        // NuExtract produces a groundable assertion. An implementation that
        // silently drops all candidates or never reaches the store would fail here.
        #expect(filed >= 1, "factsFiled must be >= 1 with cued content; check grounding validator and assertionKind extraction")

        print("live proof PASS: activation and batch cycle executed end-to-end; " +
              "factsFiled=\(filed) for drawer \(drawer.id)")
    }
}
