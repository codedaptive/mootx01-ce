// EncoderActivation.swift
//
// The `"encoder"` value of the `embedding_provider` manifest key: how the
// estate lifecycle turns the active `encoder_models` row into a
// `SpanEncoder`, where the recall rerank stage and the `spanEncode` duty
// fetch it, and the two companion manifest keys (`encoder_head`,
// `encoder_batch`).
//
// The encoder is a rerank stage over the lexical head, not an ensemble
// member: provisioning `"encoder"` leaves the Corpus ensemble exactly as
// configured and registers the encoder beside the VectorStore instead.
//
// Seeding: when the manifest names the encoder and the registry holds no
// active row, `activateSpanEncoder` seeds the bundled arctic-embed-s-w60
// row before loading it (ruling 2026-09-04: upgrade never creates content;
// seeding belongs to provision and serve). The upgrade backfill also seeds
// through `seedDefaultEncoderModel(in:)`, keeping one construction site for
// the seed row in this file. Consumers: the GLK activation path (at open)
// and the `mootx01 upgrade` backfill (also behind `--backfill-only`).
//
// Failure contract: a missing model directory, a vocabulary hash mismatch
// or a load failure leaves the estate with NO encoder for the session,
// writes ONE OSLog line on the `GeniusLocusKit` category, and raises
// nothing to the caller. Recall then runs lexical-only. A seed failure is
// also logged once; activation reads the registry as it stands.
//
// Mirror: rust/src/coordinator.rs `activate_span_encoder` and
// rust/src/encoder_activation.rs.

import Foundation
import OSLog
import CorpusKit
import LocusKit
import CorpusKitProviders

/// Resolves the on-disk directory holding a model's assets (`vocab.txt`
/// plus the compiled model). The bundling unit supplies the production
/// conformer; the default resolver returns `nil` for every id, which the
/// lifecycle treats as "model unavailable".
public protocol ModelDirectoryResolving: Sendable {
    /// Directory for `modelID`, or `nil` when this device has no copy.
    func encoderModelDirectory(for modelID: String) -> URL?
}

/// The default resolver: no model directories on this device.
public struct NilModelDirectoryResolver: ModelDirectoryResolving {
    /// Create the resolver.
    public init() {}
    public func encoderModelDirectory(for modelID: String) -> URL? { nil }
}

/// The production resolver: `CorpusKitProviders.ModelDirectoryResolver`
/// searched from the mootx01 data directory (the 1.2 download slot) and the
/// process bundle (the bundled model). Serve entry points install it with
/// `setModelDirectoryResolver(_:)` BEFORE the estate is opened and wired, so
/// `applyProvisionedEmbeddingProvider` can activate the encoder; without it
/// the kit keeps `NilModelDirectoryResolver` and every estate runs
/// lexical-only. Twin of Rust `BundledModelDirectoryResolver`.
public struct BundledModelDirectoryResolver: ModelDirectoryResolving {
    /// The mootx01 data directory root (search slot 1, the 1.2 download
    /// location; empty in 1.1).
    public let dataDirectory: URL

    /// Create the resolver over `dataDirectory`.
    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public func encoderModelDirectory(for modelID: String) -> URL? {
        ModelDirectoryResolver.encoderModelDirectory(for: modelID, dataDirectory: dataDirectory)
    }
}

public extension GeniusLocusKit {

    /// `embedding_provider` value that activates the span encoder.
    static var encoderProviderID: String { "encoder" }

    /// Manifest key: BM25 head size the rerank stage encodes (Int).
    static var encoderHeadMetaKey: String { "encoder_head" }

    /// Manifest key: spans per inference batch in the duty (Int).
    static var encoderBatchMetaKey: String { "encoder_batch" }

    /// Default `encoder_head` when the manifest carries none.
    static var defaultEncoderHead: Int { 30 }

    /// Default `encoder_batch` when the manifest carries none: 16 on iOS
    /// (memory-constrained), 64 elsewhere.
    static var defaultEncoderBatch: Int {
#if os(iOS)
        16
#else
        64
#endif
    }

    private static var encoderLog: Logger {
        Logger(subsystem: "com.mootx01.kit", category: "GeniusLocusKit")
    }

    // MARK: - Registry

    /// Register a `SpanEncoder` for `handle` so the recall rerank stage and
    /// the `spanEncode` duty read the same instance. Re-registering replaces
    /// the entry; `close(_:)` drops it.
    func registerSpanEncoder(_ encoder: any SpanEncoder, for handle: EstateHandle) {
        spanEncoders[handle] = encoder
    }

    /// The `SpanEncoder` registered for `handle`, or `nil` when the estate
    /// was not provisioned with `"encoder"` or activation failed (see the
    /// failure contract in this file's header).
    func registeredSpanEncoder(for handle: EstateHandle) -> (any SpanEncoder)? {
        spanEncoders[handle]
    }

    /// Whether the span rerank stage is registered for `handle`: the encoder
    /// loaded and the estate's VectorStore was registered, so unionBest
    /// recall reranks the lexical head. False on an estate with no encoder,
    /// on a CorpusOnly estate (duty-side encoder only) and for a stale handle.
    /// The ARIA discrimination line reads it to decide whether a dark dense
    /// lane leaves the ranking lexical-only. Twin of Rust `is_span_rerank_registered`.
    func isSpanRerankRegistered(for handle: EstateHandle) -> Bool {
        spanRerankSources[handle] != nil
    }

    /// Install the model-directory resolver used by every later activation.
    /// The bundling unit calls this once at daemon start; tests inject a
    /// scratch-directory resolver.
    func setModelDirectoryResolver(_ resolver: any ModelDirectoryResolving) {
        modelDirectoryResolver = resolver
    }

    // MARK: - Manifest keys

    /// Store `encoder_head` on the estate manifest.
    func provisionEncoderHead(_ head: Int, for handle: EstateHandle) async throws {
        let estate = try estate(for: handle)
        do {
            try await estate.setMeta(key: Self.encoderHeadMetaKey, value: String(head))
        } catch {
            throw remap(verb: "provisionEncoderHead", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    /// `encoder_head` from the manifest, or `defaultEncoderHead` when the
    /// key is absent or does not parse as a positive integer.
    func provisionedEncoderHead(for handle: EstateHandle) async -> Int {
        await positiveIntMeta(key: Self.encoderHeadMetaKey, for: handle) ?? Self.defaultEncoderHead
    }

    /// Store `encoder_batch` on the estate manifest.
    func provisionEncoderBatch(_ batch: Int, for handle: EstateHandle) async throws {
        let estate = try estate(for: handle)
        do {
            try await estate.setMeta(key: Self.encoderBatchMetaKey, value: String(batch))
        } catch {
            throw remap(verb: "provisionEncoderBatch", estateID: handle.estateUUID.uuidString, error: error)
        }
    }

    /// `encoder_batch` from the manifest, or `defaultEncoderBatch` when the
    /// key is absent or does not parse as a positive integer.
    func provisionedEncoderBatch(for handle: EstateHandle) async -> Int {
        await positiveIntMeta(key: Self.encoderBatchMetaKey, for: handle) ?? Self.defaultEncoderBatch
    }

    /// Fail-quiet positive-Int manifest read: a stale handle, an absent key
    /// or a malformed value all yield `nil` so a bad provision never breaks
    /// an open.
    private func positiveIntMeta(key: String, for handle: EstateHandle) async -> Int? {
        guard let estate = try? estate(for: handle),
              let raw = try? await estate.meta(key: key),
              let value = Int(raw.trimmingCharacters(in: .whitespaces)),
              value > 0 else {
            return nil
        }
        return value
    }

    // MARK: - Default provisioning

    /// Provision the span encoder as the estate's default recall stage: writes
    /// `embedding_provider = "encoder"` when the manifest carries no
    /// `embedding_provider` key (or an empty one) and returns `true`; an
    /// estate that already names a provider — the encoder or any other id —
    /// is left untouched and `false` is returned.
    ///
    /// Who calls it (Bob's ruling, 2026-09-06): the two paths that bring an
    /// estate to the current format. `provision` and every product create
    /// path call it right after the estate opens and before `wireSubstores`,
    /// so a fresh estate activates the encoder on its first open; the
    /// `mootx01 upgrade` span-encode step calls it so a migrated CE 1.0.x
    /// estate activates on its next open. Serve-time opens never write it:
    /// an operator who cleared the key keeps a lexical-only estate.
    ///
    /// Idempotent and cheap (one manifest read, at most one write). Twin of
    /// Rust `EstateCoordinator::provision_default_encoder_if_absent`.
    @discardableResult
    func provisionDefaultEncoderIfAbsent(for handle: EstateHandle) async throws -> Bool {
        if let existing = try await provisionedEmbeddingProvider(for: handle),
           !existing.isEmpty {
            return false
        }
        try await provisionEmbeddingProvider(Self.encoderProviderID, for: handle)
        return true
    }

    // MARK: - Default encoder row

    /// The bundled encoder (`EncoderModelSeed`, arctic-embed-s-w60) as an
    /// `encoder_models` row. The one construction site for the seed row in
    /// the Swift port: activation seeds it at open and the upgrade backfill
    /// seeds it over a closed estate's storage. Twin of Rust
    /// `EstateCoordinator::default_encoder_model_row`.
    static func defaultEncoderModelRow(isActive: Bool) -> EncoderModelRow {
        EncoderModelRow(
            modelID: EncoderModelSeed.modelID,
            modelVersion: EncoderModelSeed.modelVersion,
            dim: EncoderModelSeed.dim,
            queryPrefix: EncoderModelSeed.queryPrefix,
            docPrefix: EncoderModelSeed.docPrefix,
            pooling: EncoderModelSeed.pooling == "cls" ? .cls : .mean,
            tokenizerHash: EncoderModelSeed.tokenizerHash,
            windowWords: EncoderModelSeed.windowWords,
            overlapDivisor: EncoderModelSeed.overlapDivisor,
            maxSpans: EncoderModelSeed.maxSpans,
            maxSequence: EncoderModelSeed.maxSequence,
            isActive: isActive)
    }

    /// Seed the bundled encoder as the active row when `registry` holds no
    /// active row; `true` when a row was written. An estate that already
    /// carries an active row keeps it: a later audition winner is a row swap
    /// through `EncoderModelStore.activate(modelID:)`, never a reseed. Twin of
    /// Rust `EstateCoordinator::seed_default_encoder_model_in`.
    static func seedDefaultEncoderModel(in registry: EncoderModelStore) async throws -> Bool {
        guard try await registry.active() == nil else { return false }
        try await registry.upsert(defaultEncoderModelRow(isActive: true))
        return true
    }

    /// `seedDefaultEncoderModel(in:)` over the estate's own storage
    /// (`storages[handle]`). Throws `GeniusLocusKitError.estateNotOpen` for a
    /// stale handle. Twin of Rust `seed_default_encoder_model_if_absent`.
    @discardableResult
    func seedDefaultEncoderModelIfAbsent(for handle: EstateHandle) async throws -> Bool {
        guard let storage = storages[handle] else {
            throw GeniusLocusKitError.estateNotOpen(estateUUID: handle.estateUUID)
        }
        return try await Self.seedDefaultEncoderModel(in: EncoderModelStore(storage: storage))
    }

    // MARK: - Activation

    /// The active `encoder_models` row for `handle` as a CorpusKit spec; the
    /// floor model when the registry holds no active row or the estate's
    /// storage is not open (a stale handle never breaks an open).
    func activeEncoderModelSpec(for handle: EstateHandle) async -> EncoderModelSpec {
        guard let storage = storages[handle],
              let row = try? await EncoderModelStore(storage: storage).active() else {
            return EncoderModelSpec.floor
        }
        return EncoderModelSpec(row: row)
    }

    /// Build and register the span encoder for `handle` from the active
    /// registry row, applying the failure contract: nil encoder + one log
    /// line on any failure, no throw.
    func activateSpanEncoder(for handle: EstateHandle) async {
        // Seed before reading: an estate whose manifest names the encoder is
        // encoder-active from its first open (ruling 2026-09-04: upgrade never
        // creates content; seeding belongs to provision and serve). The span
        // rows are the span-encode standing signal's work and drain in the
        // background, so the open stays fast. A seed failure is logged once and
        // activation reads the registry as it stands.
        do {
            if try await seedDefaultEncoderModelIfAbsent(for: handle) {
                Self.encoderLog.info(
                    "encoder: seeded \(EncoderModelSeed.modelID, privacy: .public) as the active encoder_models row (estate: \(handle.estateUUID, privacy: .public))"
                )
            }
        } catch {
            Self.encoderLog.warning(
                "encoder: could not seed the default encoder_models row (\(String(describing: error), privacy: .public)); activation reads the registry as it stands (estate: \(handle.estateUUID, privacy: .public))"
            )
        }
        let spec = await activeEncoderModelSpec(for: handle)
        guard let directory = modelDirectoryResolver.encoderModelDirectory(for: spec.modelID) else {
            Self.encoderLog.warning(
                "encoder: no model directory for \(spec.modelID, privacy: .public); recall runs lexical-only (estate: \(handle.estateUUID, privacy: .public))"
            )
            return
        }
        let batch = await provisionedEncoderBatch(for: handle)
        do {
            let encoder = try SpanEncoderFactory.make(spec: spec, modelDirectory: directory, batchSize: batch)
            registerSpanEncoder(encoder, for: handle)
            // The recall stage reads spans from the estate's VectorStore under
            // the encoder's model id; without a registered store there is
            // nothing to rerank against, so only the duty-side encoder stays.
            if let store = vectorStores[handle] {
                let head = await provisionedEncoderHead(for: handle)
                registerSpanRerank(SpanEncoderQuerySeam(encoder: encoder),
                                   spanVectors: SynapseSpanVectorReader(store: store),
                                   head: head, for: handle)
            } else {
                Self.encoderLog.warning(
                    "encoder: no vector store registered; span rerank stage not registered (estate: \(handle.estateUUID, privacy: .public))"
                )
            }
            Self.encoderLog.info(
                "encoder: activated \(spec.modelID, privacy: .public) from \(directory.path, privacy: .public) (estate: \(handle.estateUUID, privacy: .public))"
            )
        } catch {
            Self.encoderLog.warning(
                "encoder: \(spec.modelID, privacy: .public) unavailable (\(String(describing: error), privacy: .public)); recall runs lexical-only (estate: \(handle.estateUUID, privacy: .public))"
            )
        }
    }
}
