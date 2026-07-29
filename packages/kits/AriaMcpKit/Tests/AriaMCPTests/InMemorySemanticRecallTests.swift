// InMemorySemanticRecallTests.swift
//
// Proves that the in-memory backend wires semantic recall (Corpus + VectorStore)
// and that the default beta embedding model (`.deterministic`) has a live Lane D
// (dense float lane).
//
// Before the fix in AriaMCPMain.swift, the in-memory backend was deliberately
// left row-only: `wireSemanticRecall = false` was the only path that set the
// flag to true (SQLite only). After the fix, ALL three backends set
// `wireSemanticRecall = true`, so the BM25 + vector lanes are live on every
// backend from the first capture.
//
// # What these tests prove
//
//   A. IN-MEMORY IMPATIENT — impatient capture into an in-memory estate wired
//      the same way as AriaMCPMain's in-memory branch makes content immediately
//      searchable via the CorpusBm25/vector lane. A bare `open` (no Corpus
//      registered) would return zero hits.
//
//   B. IN-MEMORY REGULAR + DRAIN — regular (non-impatient) capture, drain, then
//      search returns the content. Proves the full encode-queue path on in-memory.
//
//   C. LANE D LIVE — the default embedding model (`.deterministic`, the permanent
//      federation-grade vector implemented by `FloatSimHashEmbeddingProvider` via
//      FNV-1a + FloatSimHash projection) implements `embedFloat` and returns a non-empty float vector.
//      `floatNearest` on a corpus wired with `.deterministic` returns `.hits`,
//      not `.unavailableProviderOptOut`. Dark-by-default is forbidden.
//
//   D. POSTGRESQL SHAPE-SHARED — a PostgreSQL-shaped test is env-gated (skipped
//      when ARIA_MCP_POSTGRES_URL is absent) but shares the same wiring shape as
//      the in-memory tests, proving wiring logic is portable. When the env var is
//      set, the full e2e capture → search path runs against a live PG server.
//
// Tests A–C run unconditionally and are the primary gate for CI.

import Testing
import Foundation
import GeniusLocusKit
import GeniusLocusKitMigrations
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
import PersistenceKitPostgreSQL
@testable import AriaMCP

// MARK: - Helpers

/// Extract the text payload from a `textResult` JSONValue.
private func text(of result: JSONValue) -> String {
    guard case let .object(obj) = result,
          case let .array(content)? = obj["content"],
          case let .object(first)? = content.first,
          case let .string(s)? = first["text"]
    else { return "" }
    return s
}

/// Replicate AriaMCPMain's in-memory estate wiring: Estate.create + kit.open,
/// then Corpus + VectorStore registered on the same InMemoryStorage handle.
/// This is the exact production code path (AriaMCPMain.swift in-memory branch
/// with wireSemanticRecall = true).
private func openInMemoryEstateWithSemanticRecall()
    async throws -> (ToolDispatcher, GeniusLocusKit, EstateHandle)
{
    let kit = GeniusLocusKit()
    let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))

    // Idempotent estate create + open — mirrors AriaMCPMain's create/open pattern.
    _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
    let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())

    // Stamp the GLK 1.1 estate format, mirroring ServeCommand's GLKMigrationCatalog.prepare
    // call that sits between kit.open and kit.wireGLKSubstores in production. On a fresh
    // estate this is a fast path: no legacy chunks table detected, .current stamped
    // immediately. Without this call, wireGLKSubstores throws "estate migration required
    // before GLK 1.1 can open semantic substores".
    _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle)

    // Shared-content 1.1: the canonical wiring seam constructs the
    // ATTACHED-mode CorpusContentEngine over the LocusKit-backed adapter on
    // the same storage instance (the production path for in-memory —
    // InMemoryStorage holds all table namespaces in one instance) and
    // registers engine + shared VectorStore.
    try await kit.wireGLKSubstores(for: handle, backingStorage: storage)

    let dispatcher = ToolDispatcher(kit: kit, handle: handle)
    return (dispatcher, kit, handle)
}

// MARK: - Test suite

@Suite("In-memory estate — semantic recall wiring + Lane D proof", .serialized)
struct InMemorySemanticRecallTests {

    // MARK: - A. Impatient capture → search (in-memory)

    /// Prove the in-memory backend wires semantic recall by doing an impatient
    /// capture followed immediately by a search. Impatient mode inlines directly
    /// into the Corpus (no drain wait). On a bare `open` (no Corpus registered)
    /// this search would return 0 hits.
    @Test func inMemoryImpatientCaptureIsImmediatelySearchable() async throws {
        let (dispatcher, kit, handle) = try await openInMemoryEstateWithSemanticRecall()
        defer { Task { try? await kit.close(handle) } }

        let content = "swallow migration flyway altitude thermocline spring departure"
        _ = try await dispatcher.runFileMemory([
            "content": .string(content),
            "location": .string("birds/swallows"),
            "impatient": .bool(true),
        ])

        // Impatient ingest is inline — BM25 + vector lane must surface it immediately.
        // Without Corpus registered this returns 0 hits.
        let result = try await dispatcher.runMemorySearch([
            "query": .string("swallow migration spring"),
        ])
        let body = text(of: result)
        #expect(body.contains("swallow"),
            "in-memory estate with semantic recall wired must surface impatient capture; got: \(body)")
        #expect(!body.starts(with: "found 0"),
            "at least 1 hit expected; got: \(body)")
    }

    // MARK: - B. Regular capture → drain → search (in-memory)

    /// Prove the regular write path (encode-queue drain) on in-memory. Regular
    /// capture enqueues a job; drain processes it into the Corpus; search finds it.
    @Test func inMemoryRegularCaptureDrainThenSearchable() async throws {
        let (dispatcher, kit, handle) = try await openInMemoryEstateWithSemanticRecall()
        defer { Task { try? await kit.close(handle) } }

        let content = "arctic tern pole-to-pole record endurance longest migration circumnavigation"
        _ = try await dispatcher.runFileMemory([
            "content": .string(content),
            "location": .string("birds/terns"),
            // Non-impatient: enqueues to the encode queue.
        ])

        // Drain the encode queue before searching. awaitEncodeDrain(for:) pumps
        // the encode queue synchronously so the BM25 index is populated before recall.
        try await kit.awaitEncodeDrain(for: handle)

        let result = try await dispatcher.runMemorySearch([
            "query": .string("arctic tern migration endurance"),
        ])
        let body = text(of: result)
        #expect(body.contains("arctic tern"),
            "in-memory estate must surface regular+drained capture via BM25; got: \(body)")
        #expect(!body.starts(with: "found 0"),
            "at least 1 hit expected after drain; got: \(body)")
    }

    // MARK: - C. Lane D live under the beta default (deterministic provider)

    /// Prove that the production default embedding model (`.deterministic`) has a
    /// live dense float lane (Lane D). The deterministic provider is
    /// `FloatSimHashEmbeddingProvider` — FNV-1a tokenization + FloatSimHash
    /// projection, the permanent federation-grade vector lane. `embedFloat`
    /// returns the float vector directly (retain-not-recompute pattern), so the
    /// float lane IS populated during `ingest`. `floatNearest` therefore returns
    /// `.hits`, not `.unavailableProviderOptOut`.
    ///
    /// Dark-by-default (the float lane silently absent under the production default)
    /// is forbidden per the no-deferrals mandate.
    @Test func laneDLiveUnderBetaDefaultDeterministicProvider() async throws {
        // Build a Corpus directly against InMemoryStorage — bypasses the
        // ToolDispatcher layer to assert on floatNearest directly.
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))

        // .deterministic is the production default (AriaMCPMain.swift, kit.provision).
        let corpus = try await Corpus(storage: storage, model: .deterministic)

        // Ingest a document. The deterministic provider's embedFloat returns a
        // 32-element float vector (FNV-1a + FloatSimHash), which ingest stores as
        // vector_index=1 in the VectorStore (the Lane D row). Without embedFloat
        // support the float row would not be written and floatNearest would
        // return .unavailableNoFloatRows.
        let content = "golden eagle alpine thermal soaring wingspan territory claim"
        try await corpus.ingest(content, sourceID: "eagles/golden-eagle", now: Date())

        // floatNearest must return .hits — proving Lane D is live.
        // .unavailableProviderOptOut would mean embedFloat threw (structural opt-out, no float lane).
        // .unavailableNoFloatRows would mean embedFloat returned [] or ingest skipped float.
        // .unavailableNoVocabHit would mean the provider has a trained basis but the query
        //   tokens are all OOV — unexpected here since the deterministic provider is not vocabulary-based.
        let outcome = await corpus.floatNearest(query: "golden eagle thermal", limit: 5)
        switch outcome {
        case .hits(let results):
            #expect(!results.isEmpty,
                "floatNearest must return ≥1 hit for the ingested document; got empty")
        case .unavailableProviderOptOut:
            Issue.record("Lane D DARK — deterministic provider threw embedFloat (opt-out). The beta default must have a live float lane (no deferrals).")
        case .unavailableNoFloatRows:
            Issue.record("Lane D DARK — no float rows stored after ingest. The deterministic provider must write Lane D rows during ingest.")
        case .unavailableNoVocabHit:
            Issue.record("Lane D DARK — vocabMiss on a deterministic provider is unexpected; the deterministic provider does not use a vocabulary.")
        case .emptyQuery:
            Issue.record("floatNearest returned .emptyQuery — query was non-empty, this is a bug.")
        case .storeError(let e):
            Issue.record("Lane D store error (unexpected): \(e)")
        }
    }

    // MARK: - D. PostgreSQL shape-shared (env-gated)

    /// Prove the PostgreSQL wiring shape shares the same code path as in-memory.
    /// This test is skipped when ARIA_MCP_POSTGRES_URL is absent; it runs the
    /// full capture → search e2e when the env var is set.
    ///
    /// Even when skipped, the proof is: the PG and in-memory wiring call
    /// the same `kit.wireGLKSubstores(for:backingStorage:)` seam
    /// + `kit.registerVectorStore` — the same API surface, the same code shape.
    /// The in-memory tests (A, B, C) above cover the shared logic.
    @Test func postgresCaptureThenSearchWhenEnvSet() async throws {
        // Skip when no live PG server is available — this test requires
        // ARIA_MCP_POSTGRES_URL to be set to a connectable PostgreSQL server.
        let pgURL = ProcessInfo.processInfo.environment["ARIA_MCP_POSTGRES_URL"] ?? ""
        guard !pgURL.isEmpty else {
            // PG integration test skipped — not a failure.
            return
        }

        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "aria-mcp-owner")
        let configuration = EstateConfiguration(
            estateID: UUID(),
            backend: .postgresql(connectionString: pgURL)
        )
        // PostgreSQLStorage.init is non-throwing (lazy pool).
        let storage = PostgreSQLStorage(configuration: configuration)

        do {
            _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
            let handle = try await kit.open(storage: storage, owner: owner, identityKeyStore: InMemoryEstateIdentityKeyStore())
            defer { Task { try? await kit.close(handle) } }

            // Stamp the GLK 1.1 estate format before wiring. Fresh-estate fast path.
            _ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle)
            // Shared-content 1.1: canonical wiring seam on the same PG
            // storage handle — storage-agnostic, same as in-memory and SQLite.
            try await kit.wireGLKSubstores(for: handle, backingStorage: storage)

            let dispatcher = ToolDispatcher(kit: kit, handle: handle)

            let content = "red kite reintroduction success recovery conservation Chilterns"
            _ = try await dispatcher.runFileMemory([
                "content": .string(content),
                "location": .string("birds/kites"),
                "impatient": .bool(true),
            ])

            let result = try await dispatcher.runMemorySearch([
                "query": .string("red kite reintroduction conservation"),
            ])
            let body = text(of: result)
            #expect(body.contains("red kite"),
                "PostgreSQL estate with semantic recall wired must surface impatient capture; got: \(body)")
        } catch {
            // If PG connectivity fails (server unreachable, bad credentials),
            // fail with a clear message rather than a cryptic assertion error.
            Issue.record("PostgreSQL estate wiring failed (check ARIA_MCP_POSTGRES_URL): \(error)")
        }
    }
}
