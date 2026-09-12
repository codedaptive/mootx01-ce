// DreamAssociatesDispatchTests.swift
//
// ARIA dispatch tests for the `associates` argument on `moot_dream` (step 3.5).
//
// Tests drive the real dispatcher with a GLK estate wired identically to
// ContradictionHunterEndToEndTests: one storage, a token-bag embedding provider,
// and GLK migration + wireGLKSubstores so the VectorStore is live.
//
// Coverage:
//   1. associates=all on an estate with similar planted rows → structured data
//      field `associationsWritten: N` appears in structuredContent.data with N>0.
//   2. associates=off → the step is entirely skipped; `associationsWritten`
//      is absent from structuredContent.data.
//   3. associates=all with 2 items → `associationsNonUniqueProbes` is present
//      (count of (probe, lane) scans whose whole ladder pool was one tie group;
//      incremented once per lane, so it can exceed `probed` and is not bounded
//      by allModeMaxProbe, which caps the probe set only).
//   4. allModeMaxProbe constant is 10_000 (compile-time pin).
//   5. associates=all probes more items than the default 50-probe cadence when
//      the estate has older items beyond the default probe window.
//   6. associates=<unknown> is refused with JSON-RPC -32602; no write runs.
//   7. associates=OFF (uppercase) is accepted and behaves as "off".

import Testing
import Foundation
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import CorpusKit
import SynapseKit
import PersistenceKit
import PersistenceKitInMemory
@testable import AriaMCP

@Suite("Dream associates dispatch — step 3.5 ARIA surface", .serialized)
struct DreamAssociatesDispatchTests {

    // MARK: - Wiring helper

    /// Open an estate wired for full GLK substrate use: migration + shared
    /// VectorStore registered via wireGLKSubstores with a token-bag embedding
    /// provider. Mirrors ContradictionHunterEndToEndTests.makeDispatcher() exactly.
    ///
    /// Token-bag model: sums per-token FNV-hashed float projections across a
    /// 32-dimensional space. Sentences that share most tokens have close float
    /// embeddings; FloatSimHashEmbeddingProvider projects these to 256-bit
    /// fingerprints with small Hamming distance — below the
    /// `defaultProximityThreshold` of 64 for high-overlap pairs.
    private func makeDispatcher() async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dream-associates-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())

        // Token-bag embedding: per-token FNV hash → 32-dim float projection.
        // Sentences sharing the majority of their tokens produce close float
        // vectors and thus small Hamming distances after SimHash projection.
        let tokenBag: @Sendable (String) async throws -> [Float] = { text in
            var acc = [Float](repeating: 0, count: 32)
            let tokens = text.lowercased().split(
                whereSeparator: { !$0.isLetter && !$0.isNumber })
            for token in tokens {
                var h: UInt64 = 14_695_981_039_346_656_037
                for byte in token.utf8 {
                    h = (h ^ UInt64(byte)) &* 1_099_511_628_211
                }
                for i in 0..<32 {
                    h = h &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    acc[i] += (Float(h >> 40) / Float(1 << 24)) * 2 - 1
                }
            }
            return acc
        }
        let provider = FloatSimHashEmbeddingProvider(
            modelID: "assoc-token-bag-v1", modelVersion: "1.0",
            projectionSeed: 0xC0FF_EE00, inference: tokenBag)

        // Stamp the GLK 1.1 estate format (mirrors ServeCommand's GLKMigrationCatalog.prepare
        // call between kit.open and kit.wireGLKSubstores in production).
        _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle)
        // Shared-content 1.1 seam: token-bag provider is the embedding model;
        // its rows land in the shared VectorStore keyed by Drawer ID.
        try await kit.wireGLKSubstores(
            for: handle, backingStorage: storage,
            embeddingModels: [.randomIndexing(provider: provider)])

        return (ToolDispatcher(kit: kit, handle: handle), kit, handle)
    }

    /// File a memory through the tool surface with inline encode (`impatient: true`),
    /// so the VectorStore row lands before this call returns.
    @discardableResult
    private func file(
        _ content: String, via dispatcher: ToolDispatcher
    ) async throws -> String {
        let result = try await dispatcher.dispatch(
            name: "moot_file_memory",
            arguments: .object([
                "content": .string(content),
                "subject": .string(String(content.prefix(120))),
                "location": .string("test/notes"),
                "impatient": .bool(true),
            ]))
        guard case let .object(obj) = result,
              case let .array(content)? = obj["content"],
              case let .object(first)? = content.first,
              case let .string(body)? = first["text"],
              body.contains("filed memory")
        else { return "" }
        let firstLine = body.split(separator: "\n").first.map(String.init) ?? ""
        return firstLine.split(separator: " ").last.map(String.init) ?? ""
    }

    // MARK: - Test 1 — associates=all writes associations for similar rows

    /// When `associates=all` is passed, `moot_dream` runs step 3.5 over all items
    /// in the VectorStore. Planting highly similar sentences produces proximity
    /// pairs with small Hamming distance; at least one pair is written.
    ///
    /// The response must contain the `associationsWritten:` line with N>0.
    @Test
    func dreamAssociatesAllWritesOnSimilarPair() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Plant three sentences sharing most tokens — high token-bag overlap
        // guarantees small SimHash Hamming distance.
        try await file("the api timeout is thirty seconds on all endpoints", via: dispatcher)
        try await file("the api timeout is ninety seconds on all endpoints", via: dispatcher)
        try await file("the api timeout is sixty seconds on all endpoints", via: dispatcher)

        // Run moot_dream with associates=all (full-estate coverage).
        let result = try await dispatcher.dispatch(
            name: "moot_dream",
            arguments: .object([
                "now": .string("2026-06-11T00:00:00Z"),
                "associates": .string("all"),
            ]))

        guard case let .object(obj) = result,
              let isErrorVal = obj["isError"],
              case let .bool(isError) = isErrorVal, !isError
        else {
            Issue.record("Unexpected result shape or error: \(result)")
            return
        }

        // v2 puts structured fields in structuredContent.data, not the text body.
        let data = try #require(
            obj["structuredContent"]?.objectValue?["data"]?.objectValue,
            "structuredContent.data must be present in a successful v2 response")

        // associationsWritten must be present and > 0 — at least one proximity
        // pair was found among the planted similar sentences.
        let written = try #require(data["associationsWritten"]?.integerValue,
                                   "associates=all must produce associationsWritten in data")
        #expect(written > 0,
                "associationsWritten must be > 0 for high-overlap pairs; got \(written)")
    }

    // MARK: - Test 2 — associates=off skips the step entirely

    /// When `associates=off` is passed, step 3.5 is entirely bypassed — the
    /// `assocLine` variable is never set so `associationsWritten:` does NOT appear
    /// in the response body regardless of estate content.
    @Test
    func dreamAssociatesOffSkipsStep() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dream-assoc-off-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)

        // Run moot_dream with associates=off on a bare estate.
        let result = try await dispatcher.dispatch(
            name: "moot_dream",
            arguments: .object([
                "now": .string("2026-06-11T00:00:00Z"),
                "associates": .string("off"),
            ]))

        guard case let .object(obj) = result,
              let isErrorVal = obj["isError"],
              case let .bool(isError) = isErrorVal, !isError
        else {
            Issue.record("Unexpected result shape or error: \(result)")
            return
        }

        // v2 puts structured fields in structuredContent.data; associates=off
        // means the sweep was skipped so associationsWritten must be absent.
        let data = try #require(
            obj["structuredContent"]?.objectValue?["data"]?.objectValue,
            "structuredContent.data must be present in a successful v2 response")
        #expect(
            data["associationsWritten"] == nil,
            "associates=off must not produce associationsWritten in data")
    }

    // MARK: - Test 3 — associates=all reaches the sweep

    /// What this test proves: `associates: "all"` reaches step 3.5 and the
    /// sweep reports back.  The discriminating assertion is the `#require` on
    /// `associationsNonUniqueProbes` being PRESENT — absence means the sweep
    /// was skipped or the mode never reached the lower.
    ///
    /// What it does NOT prove: the probe cap.  With two planted items the
    /// `<= allModeMaxProbe` comparison holds for every possible limit,
    /// including an unbounded one, so it cannot discriminate.  The cap is
    /// gated by `dreamAssociatesAllSelectsMoreAssociationsThanDefault` below,
    /// which needs an estate larger than the default probe window.
    ///
    /// `associationsNonUniqueProbes` is NOT a probe count and NOT a dedup
    /// count.  Per `AssociateSweepReport.nonUniqueProbes` it counts
    /// (probe, lane) scans whose entire ladder pool was one distance tie
    /// group, so no clean cut existed and the lane contributed zero pairs.
    /// It is incremented once per probe PER LANE, so it can exceed `probed`.
    /// Pairs skipped for an existing association are the separate
    /// `deduplicated` field.
    ///
    /// Parity: `dream_all_mode_uses_bounded_probe_limit_not_unlimited` in Rust
    /// `dispatch_tests.rs`.
    @Test
    func dreamAssociatesAllUsesBoundedProbeNotUnlimited() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }

        // Plant two items with similar content — guarantees the VectorStore
        // has at least two indexed rows so step 3.5 runs.
        try await file("boundary test: probe limit constant is ten thousand", via: dispatcher)
        try await file("boundary check: probe limit constant is ten thousand items", via: dispatcher)

        let result = try await dispatcher.dispatch(
            name: "moot_dream",
            arguments: .object([
                "now": .string("2026-07-01T00:00:00Z"),
                "associates": .string("all"),
            ]))

        guard case let .object(obj) = result,
              let isErrorVal = obj["isError"],
              case let .bool(isError) = isErrorVal, !isError
        else {
            Issue.record("Unexpected result shape: \(result)")
            return
        }

        // v2 puts structured fields in structuredContent.data.
        // associationsNonUniqueProbes is present whenever the sweep ran — its
        // absence means the sweep was skipped or the "all" mode didn't reach
        // the lower.
        let data = try #require(
            obj["structuredContent"]?.objectValue?["data"]?.objectValue,
            "structuredContent.data must be present in a successful v2 response")
        let nonUniqueProbes = try #require(
            data["associationsNonUniqueProbes"]?.integerValue,
            "associates=all must produce associationsNonUniqueProbes in data")
        // Constant pin: the bound is 10_000.  With 2 items every probe is
        // trivially within the cap, but the assertion is unconditional so the
        // test fails if the field is absent (mode was wrong or step was skipped).
        #expect(nonUniqueProbes <= AriaV2Dream.GeniusLocusLower.allModeMaxProbe,
                "associates=all non-unique-probes must be <= allModeMaxProbe (\(AriaV2Dream.GeniusLocusLower.allModeMaxProbe)); got \(nonUniqueProbes)")
        // Compile-time constant pin.
        #expect(AriaV2Dream.GeniusLocusLower.allModeMaxProbe == 10_000,
                "allModeMaxProbe must be 10_000")
    }

    // MARK: - Test 4 — allModeMaxProbe constant value is 10_000

    /// Documents that `AriaV2Dream.GeniusLocusLower.allModeMaxProbe` is 10_000.
    /// The behavioral enforcement is that `assocProbeLimit` in `GeniusLocusLower.run`
    /// is always an `Int` (never `nil`), preventing the nil path that allowed
    /// unbounded probing.  The constant is public so the pin is made directly
    /// in Test 3 above; this test confirms no-crash on an estate without a
    /// VectorStore (the sweep is a no-op, not an error).
    @Test
    func dreamAllModeMaxProbeConstantIsDocumented() async throws {
        // Smoke: the "all" path must not crash when the estate has no VectorStore.
        // The constant-value pin (#expect == 10_000) lives in Test 3 alongside
        // the bounded-probe assertion.  Placing it there keeps the pin
        // unconditionally verified whenever the sweep runs.
        //
        // Run the tool on a bare estate to confirm the "all" path compiles and
        // executes without crashing even on an estate with no VectorStore.
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dream-all-cap-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        defer { Task { try? await kit.close(handle) } }

        let result = try await dispatcher.dispatch(
            name: "moot_dream",
            arguments: .object([
                "now": .string("2026-07-01T00:00:00Z"),
                "associates": .string("all"),
            ]))

        guard case let .object(obj) = result,
              let isErrorVal = obj["isError"],
              case let .bool(isError) = isErrorVal
        else {
            Issue.record("Unexpected result shape: \(result)")
            return
        }
        #expect(!isError, "moot_dream associates=all on empty estate must not error")
    }

    // MARK: - Test 5 — associates=all reaches older items that default mode skips

    /// When the estate has more items than the default 50-probe cadence, the
    /// `associates="all"` mode must write more associations than the default mode
    /// because it probes items that are older than the default's recency window.
    ///
    /// Setup: two clusters, both planted via the wired VectorStore so proximity
    /// pairs are detectable:
    ///   - Cluster B (8 items, planted first / oldest): "quantum error qubit N"
    ///     variations — all similar to each other, dissimilar to cluster A.
    ///   - Cluster A (52 items, planted second / newest): "api timeout endpoint N"
    ///     variations — all similar to each other, dissimilar to cluster B.
    ///
    /// Default mode (50 probes): takes the 50 most recent items — all from
    /// cluster A.  kNN finds cluster-A pairs only.  Cluster B is beyond the
    /// probe window and generates zero associations in this mode.
    ///
    /// All mode (10_000 probes): probes all 60 items.  kNN finds cluster-A
    /// pairs AND cluster-B pairs → `associationsWritten` is strictly larger.
    ///
    /// Mutation gate: if `associates="all"` mode is made to use the same 50-probe
    /// limit as default, both modes probe only the 50 most recent items → same
    /// result → assertion fails ✗.
    @Test
    func dreamAssociatesAllSelectsMoreAssociationsThanDefault() async throws {
        // --- Estate 1: default-mode run ---
        let (defaultDispatcher, defaultKit, defaultHandle) = try await makeDispatcher()
        defer { Task { try? await defaultKit.close(defaultHandle) } }

        // Plant cluster B first (will be older / beyond default probe window).
        for i in 1...8 {
            try await file("quantum error qubit alignment \(i) correction", via: defaultDispatcher)
        }
        // Plant cluster A second (will be newest / within default probe window).
        for i in 1...52 {
            try await file("api timeout endpoint \(i) seconds response time", via: defaultDispatcher)
        }

        let defaultResult = try await defaultDispatcher.dispatch(
            name: "moot_dream",
            arguments: .object([
                "now": .string("2026-08-01T00:00:00Z"),
                // No `associates` arg → default 50-probe cadence.
            ]))

        guard case let .object(defaultObj) = defaultResult,
              case .bool(false)? = defaultObj["isError"]
        else {
            Issue.record("Default-mode dream failed: \(defaultResult)")
            return
        }
        let defaultData = try #require(
            defaultObj["structuredContent"]?.objectValue?["data"]?.objectValue,
            "default-mode structuredContent.data must be present")
        // #require, not `?? 0`: a missing key would silently degrade the
        // comparison below to `allWritten > 0`, which passes for reasons that
        // have nothing to do with the probe window.
        let defaultWritten = try #require(
            defaultData["associationsWritten"]?.integerValue,
            "default-mode dream must report associationsWritten")

        // --- Estate 2: all-mode run (same content, fresh estate) ---
        let (allDispatcher, allKit, allHandle) = try await makeDispatcher()
        defer { Task { try? await allKit.close(allHandle) } }

        for i in 1...8 {
            try await file("quantum error qubit alignment \(i) correction", via: allDispatcher)
        }
        for i in 1...52 {
            try await file("api timeout endpoint \(i) seconds response time", via: allDispatcher)
        }

        let allResult = try await allDispatcher.dispatch(
            name: "moot_dream",
            arguments: .object([
                "now": .string("2026-08-01T00:00:00Z"),
                "associates": .string("all"),
            ]))

        guard case let .object(allObj) = allResult,
              case .bool(false)? = allObj["isError"]
        else {
            Issue.record("All-mode dream failed: \(allResult)")
            return
        }
        let allData = try #require(
            allObj["structuredContent"]?.objectValue?["data"]?.objectValue,
            "all-mode structuredContent.data must be present")
        let allWritten = try #require(
            allData["associationsWritten"]?.integerValue,
            "associates=all must produce associationsWritten in data")

        // All mode must have probed cluster B (8 older items beyond default's
        // recency window) and written their associations too.
        #expect(allWritten > defaultWritten,
                "associates=all must write more associations than default cadence; all=\(allWritten) default=\(defaultWritten)")
    }

    // MARK: - Test 6 — associates unknown value is refused before any sweep runs

    /// When an unknown value (e.g. "banana") is passed for `associates`, the
    /// operation is refused with a -32602 invalid-argument error thrown from
    /// argument decoding — the lower engine is never reached and no association
    /// sweep runs.
    ///
    /// The topology-change signature (audit,tunnel,kgfact) must be identical
    /// before and after the refused call, proving no tunnel writes occurred.
    ///
    /// Mutation gate: removing the enum guard in AriaV2Dream.Request.init lets
    /// "banana" reach the execution branch, where it falls through to the
    /// default 50-probe cadence and runs an association sweep — the tunnel
    /// count advances and the signature changes, failing the assertion.
    @Test
    func dreamAssociatesRejectsUnknownValue() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "dream-assoc-banana-test")
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage, owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let dispatcher = ToolDispatcher(kit: kit, handle: handle)
        defer { Task { try? await kit.close(handle) } }

        // Capture topology signature (audit,tunnel,kgfact) before the refused call.
        let signatureBefore = try await kit.topologyChangeSignature(for: handle)

        // "banana" is not a valid associates value — must throw a JSON-RPC
        // invalid-argument error before the lower engine is reached.
        await #expect(throws: JSONRPCError.self, "associates='banana' must throw JSONRPCError") {
            try await dispatcher.dispatch(
                name: "moot_dream",
                arguments: .object([
                    "now": .string("2026-06-11T00:00:00Z"),
                    "associates": .string("banana"),
                ]))
        }

        // Topology signature must be unchanged — no sweep ran.
        let signatureAfter = try await kit.topologyChangeSignature(for: handle)
        #expect(signatureBefore == signatureAfter,
                "topology must not change when associates is refused; before=\(signatureBefore) after=\(signatureAfter)")
    }

    // MARK: - Test 7 — uppercase OFF is accepted and normalised

    /// Uppercase "OFF" is accepted for `associates` and behaves identically to
    /// lowercase "off" — the association sweep step is skipped.
    ///
    /// The `.lowercased()` normalisation in AriaV2Dream.Request.init runs before
    /// the enum check, so "OFF" becomes "off" before validation.
    ///
    /// Mutation gate: moving the `.lowercased()` call to after the enum check
    /// (or removing it) makes "OFF" fail validation with a -32602 throw.
    @Test
    func dreamAssociatesUppercaseOffIsAccepted() async throws {
        let (dispatcher, kit, handle) = try await makeDispatcher()
        defer { Task { try? await kit.close(handle) } }
        // "OFF" must not throw and must behave as "off" — no associationsWritten
        // appears in the compact text.
        let result = try await dispatcher.dispatch(
            name: "moot_dream",
            arguments: .object([
                "now": .string("2026-06-11T00:00:00Z"),
                "associates": .string("OFF"),
            ]))
        let obj = result.objectValue ?? [:]
        let isError = obj["isError"] == .bool(true)
        #expect(!isError, "associates='OFF' must be accepted (not refused); result: \(result)")
        // "off" skips the association sweep; associationsWritten must be absent
        // from structuredContent.data, matching the behaviour of lowercase "off".
        let data = obj["structuredContent"]?.objectValue?["data"]?.objectValue ?? [:]
        #expect(data["associationsWritten"] == nil,
                "associates='OFF' must skip the sweep (no associationsWritten); data: \(data)")
    }
}
